import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_policy.dart';

class MakeupBagCache extends ChangeNotifier {
  MakeupBagCache._();
  static final MakeupBagCache instance = MakeupBagCache._();

  /// Old unscoped key. Never shown: it may belong to a previous account.
  static const String legacyPrefsKey = 'makeup_bag_items_cache';

  @visibleForTesting
  static String prefsKeyFor(String userId) {
    final safe = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'makeup_bag_items_cache_${safe.isEmpty ? 'unknown' : safe}';
  }

  @visibleForTesting
  static List<String> keysClearedOnSignOut(String? userId) {
    final keys = <String>[legacyPrefsKey];
    if (userId != null && userId.isNotEmpty) keys.add(prefsKeyFor(userId));
    return keys;
  }

  // Store format: "productKey__shadeKey"
  final Set<String> _bagKeys = {};
  List<Map<String, dynamic>> _rawItems = [];
  bool _isLoading = false;
  RealtimeChannel? _channel;
  String? _listeningUserId;
  String? _defaultBagId;
  bool _remoteItemsLoaded = false;
  Future<void>? _ensuring;
  int _generation = 0;
  String? _activeUserId;
  DateTime? _cachedAt;
  Future<void>? _inflight;

  bool _isCurrent(int generation, String userId) =>
      generation == _generation && _activeUserId == userId;

  bool _isFresh() =>
      CachePolicy.isFresh(_cachedAt, CachePolicy.userListTtl, DateTime.now());

  static const Duration _readTimeout = Duration(seconds: 10);

  bool get isLoading => _isLoading;
  bool get isEmpty => _rawItems.isEmpty;
  List<Map<String, dynamic>> get items => List.unmodifiable(_rawItems);
  String? get defaultBagId => _defaultBagId;

  bool isInBag(String productKey, String? shadeKey) {
    final key = '${productKey}__${shadeKey ?? ''}';
    return _bagKeys.contains(key);
  }

  Future<void> prefetch(String userId, {bool force = false}) {
    if (!force && _inflight != null && _activeUserId == userId) {
      return _inflight!;
    }
    final run = _prefetch(userId, force: force);
    _inflight = run;
    return run.whenComplete(() {
      if (identical(_inflight, run)) _inflight = null;
    });
  }

  Future<void> _prefetch(String userId, {bool force = false}) async {
    final generation = _generation;
    _activeUserId = userId;

    // Load this account's copy first. The old shared key is deleted, not shown.
    await _loadFromLocalCache(generation, userId);
    if (!_isCurrent(generation, userId)) return;
    if (!force && _isFresh()) {
      _isLoading = false;
      notifyListeners();
      return;
    }
    if (_rawItems.isEmpty) {
      _isLoading = true;
      notifyListeners();
    }

    try {
      // Startup only reads. "My Everyday Bag" is created when the user opens
      // the bag or adds an item, not on a cold start.
      final id = await _lookupDefaultBagId(userId);
      if (!_isCurrent(generation, userId)) return;
      if (id != null) await _fetchRemoteItems(generation, userId);
    } catch (e) {
      debugPrint('❌ Makeup bag fetch failed: $e');
      // If we fail (e.g. offline), we already loaded from local cache
    } finally {
      if (_isCurrent(generation, userId)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Looks up the existing everyday bag. Does not insert a row.
  Future<String?> _lookupDefaultBagId(String userId) async {
    final bagRes = await Supabase.instance.client
        .from('makeup_bags')
        .select('id')
        .eq('user_id', userId)
        .eq('name', 'My Everyday Bag')
        .limit(1)
        .maybeSingle()
        .timeout(_readTimeout);
    if (bagRes == null) return null;
    final id = bagRes['id']?.toString();
    if (id == null || id.isEmpty) return null;
    _defaultBagId = id;
    return id;
  }

  Future<void> _fetchRemoteItems(int generation, String userId) async {
    if (_defaultBagId == null) return;
    if (!_isCurrent(generation, userId)) return;
    final itemsRes = await Supabase.instance.client
        .from('makeup_bag_items')
        .select('id, product_key, shade_key, added_at')
        .eq('bag_id', _defaultBagId!)
        .order('added_at', ascending: false)
        .timeout(_readTimeout);

    if (!_isCurrent(generation, userId)) return;
    final fetched = _dedupe(List<Map<String, dynamic>>.from(itemsRes));
    final next = CachePolicy.afterRefresh(_rawItems, fetched);
    _rawItems = next ?? _rawItems;
    _bagKeys.clear();
    for (var item in _rawItems) {
      final pk = item['product_key'] as String;
      final sk = item['shade_key'] as String?;
      _bagKeys.add('${pk}__${sk ?? ''}');
    }
    _remoteItemsLoaded = true;
    _cachedAt = DateTime.now();
    await _saveToLocalCache(generation, userId);
  }

  /// Creates "My Everyday Bag" only if the signed-in user does not have one.
  /// Called when the bag screen opens or an item is added.
  Future<void> ensureDefaultBagForSignedInUser() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return Future.value();
    return ensureDefaultBag(userId);
  }

  Future<void> ensureDefaultBag(String userId) {
    final pending = _ensuring;
    if (pending != null) return pending;
    final run = _ensureDefaultBag(userId);
    _ensuring = run;
    return run.whenComplete(() {
      if (identical(_ensuring, run)) _ensuring = null;
    });
  }

  Future<void> _ensureDefaultBag(String userId) async {
    if (_defaultBagId != null) return;
    try {
      final existing = await _lookupDefaultBagId(userId);
      if (existing == null) {
        final newBag = await Supabase.instance.client
            .from('makeup_bags')
            .insert({'user_id': userId, 'name': 'My Everyday Bag'})
            .select('id')
            .single()
            .timeout(_readTimeout);
        _defaultBagId = newBag['id']?.toString();
        return;
      }
      if (!_remoteItemsLoaded) {
        await _fetchRemoteItems(_generation, userId);
      }
    } catch (e) {
      debugPrint('❌ Makeup bag ensure failed: $e');
    }
  }

  Future<void> _loadFromLocalCache(int generation, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(legacyPrefsKey)) {
        await prefs.remove(legacyPrefsKey);
      }
      if (!_isCurrent(generation, userId)) return;
      final cachedString = prefs.getString(prefsKeyFor(userId));
      if (cachedString == null || cachedString.isEmpty) return;
      final envelope = CacheEnvelope.decode(jsonDecode(cachedString));
      if (!_isCurrent(generation, userId)) return;
      _cachedAt = envelope.cachedAt;
      _rawItems = envelope.items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _bagKeys.clear();
      for (var item in _rawItems) {
        final pk = item['product_key'] as String;
        final sk = item['shade_key'] as String?;
        _bagKeys.add('${pk}__${sk ?? ''}');
      }
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Local makeup bag cache load failed: $e');
    }
  }

  Future<void> _saveToLocalCache(int generation, String userId) async {
    try {
      if (!_isCurrent(generation, userId)) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(generation, userId)) return;
      await prefs.setString(
        prefsKeyFor(userId),
        jsonEncode(
          CacheEnvelope(cachedAt: _cachedAt ?? DateTime.now(), items: _rawItems).encode(),
        ),
      );
      if (!_isCurrent(generation, userId)) {
        await prefs.remove(prefsKeyFor(userId));
      }
    } catch (e) {
      debugPrint('❌ Local makeup bag cache save failed: $e');
    }
  }

  Future<void> _deleteDisk(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in keysClearedOnSignOut(userId)) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('❌ Makeup bag disk clear failed: $e');
    }
  }

  void listenRealtime(String userId) {
    if (_listeningUserId == userId && _channel != null) return;
    if (_defaultBagId == null) return;

    if (_channel != null) {
      Supabase.instance.client.removeChannel(_channel!);
    }
    _listeningUserId = userId;

    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      Supabase.instance.client.realtime.setAuth(session.accessToken);
    }

    _channel = Supabase.instance.client
        .channel('makeup_bag-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'makeup_bag_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'bag_id',
            value: _defaultBagId!,
          ),
          callback: (payload) {
            debugPrint('✅ Makeup bag realtime event: ${payload.eventType}');

            if (payload.eventType == PostgresChangeEvent.delete) {
              final oldRow = payload.oldRecord;
              final pk = oldRow['product_key'] as String?;
              final sk = oldRow['shade_key'] as String?;
              if (pk != null) {
                final key = '${pk}__${sk ?? ''}';
                _bagKeys.remove(key);
                _rawItems.removeWhere(
                    (f) => f['product_key'] == pk && (f['shade_key'] ?? '') == (sk ?? ''));
              }
            } else {
              // INSERT or UPDATE
              final row = payload.newRecord;
              final pk = row['product_key'] as String?;
              final sk = row['shade_key'] as String?;
              if (pk != null) {
                final key = '${pk}__${sk ?? ''}';
                if (!_bagKeys.contains(key)) {
                  _bagKeys.add(key);
                  _rawItems.insert(0, row);
                }
              }
            }
            final userId = _activeUserId ?? _listeningUserId;
            if (userId != null) {
              _cachedAt = DateTime.now();
              _saveToLocalCache(_generation, userId);
            }
            notifyListeners();
          },
        )
        .subscribe((status, error) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('✅ Makeup bag realtime connected');
          } else if (error != null) {
            debugPrint('❌ Makeup bag realtime error: $error');
            _listeningUserId = null;
            Future.delayed(const Duration(seconds: 5), () {
              if (Supabase.instance.client.auth.currentUser?.id == userId) {
                listenRealtime(userId);
              }
            });
          }
        });
  }

  void stopListening() {
    if (_channel != null) {
      Supabase.instance.client.removeChannel(_channel!);
    }
    _channel = null;
    _listeningUserId = null;
    _defaultBagId = null;
    _remoteItemsLoaded = false;
  }

  List<Map<String, dynamic>> _dedupe(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final key = '${row['product_key']}__${row['shade_key'] ?? ''}';
      if (seen.add(key)) result.add(row);
    }
    return result;
  }

  Future<void> toggleInBag(String productKey, String? shadeKey) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    
    if (_defaultBagId == null) {
      final normalizedShade = shadeKey ?? '';
      final key = '${productKey}__$normalizedShade';
      final adding = !_bagKeys.contains(key);
      if (adding) {
        await ensureDefaultBag(userId);
      } else {
        try {
          await _lookupDefaultBagId(userId);
        } catch (e) {
          debugPrint('❌ Makeup bag fetch failed: $e');
        }
      }
      if (_defaultBagId == null) return;
    }

    final normalizedShade = shadeKey ?? ''; 
    final key = '${productKey}__$normalizedShade';
    final isCurrentlyInBag = _bagKeys.contains(key);

    if (isCurrentlyInBag) {
      _bagKeys.remove(key);
      _rawItems.removeWhere(
        (f) =>
            f['product_key'] == productKey &&
            (f['shade_key'] ?? '') == normalizedShade,
      );
    } else {
      _bagKeys.add(key);
      _rawItems.insert(0, {
        'product_key': productKey,
        'shade_key': normalizedShade,
        'added_at': DateTime.now().toIso8601String(),
      });
    }
    _activeUserId ??= userId;
    _cachedAt = DateTime.now();
    _saveToLocalCache(_generation, userId);
    notifyListeners();

    try {
      if (isCurrentlyInBag) {
        await Supabase.instance.client
            .from('makeup_bag_items')
            .delete()
            .eq('bag_id', _defaultBagId!)
            .eq('product_key', productKey)
            .eq('shade_key', normalizedShade);
      } else {
        await Supabase.instance.client
            .from('makeup_bag_items')
            .insert({
              'user_id': userId,
              'bag_id': _defaultBagId,
              'product_key': productKey,
              'shade_key': shadeKey, // use original nullable
            });
      }
    } on Exception catch (e) {
      if (!isCurrentlyInBag && e.toString().contains('23505')) {
        // Unique violation, ignore because it means it was already added
        return;
      }
      debugPrint('❌ Makeup bag sync failed: $e');
      if (isCurrentlyInBag) {
        _bagKeys.add(key);
      } else {
        _bagKeys.remove(key);
      }
      _cachedAt = DateTime.now();
      _saveToLocalCache(_generation, userId);
      notifyListeners();
    }
  }

  void clear() {
    final previousUser = _activeUserId;
    _generation++;
    _activeUserId = null;
    _cachedAt = null;
    _inflight = null;
    _bagKeys.clear();
    _rawItems.clear();
    stopListening();
    notifyListeners();
    _deleteDisk(previousUser);
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}

