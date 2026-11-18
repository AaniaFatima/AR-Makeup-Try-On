import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cache_policy.dart';

class FavouritesCache extends ChangeNotifier {
  FavouritesCache._();
  static final FavouritesCache instance = FavouritesCache._();

  // Store format: "productKey__shadeKey" (shadeKey can be empty)
  final Set<String> _favouriteKeys = {};
  List<Map<String, dynamic>> _rawFavourites = [];
  bool _isLoading = false;
  RealtimeChannel? _channel;
  String? _listeningUserId;
  int _generation = 0;
  String? _activeUserId;
  DateTime? _cachedAt;
  Future<void>? _inflight;

  bool _isCurrent(int generation, String userId) =>
      generation == _generation && _activeUserId == userId;

  @visibleForTesting
  static String prefsKeyFor(String userId) {
    final safe = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'user_favourites_cache_${safe.isEmpty ? 'unknown' : safe}';
  }

  bool get isLoading => _isLoading;
  bool get isEmpty => _rawFavourites.isEmpty;
  List<Map<String, dynamic>> get favourites =>
      List.unmodifiable(_rawFavourites);

  bool isFavourite(String productKey, String? shadeKey) {
    final key = '${productKey}__${shadeKey ?? ''}';
    return _favouriteKeys.contains(key);
  }

  bool _isFresh() =>
      CachePolicy.isFresh(_cachedAt, CachePolicy.userListTtl, DateTime.now());

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
    await _loadFromDisk(generation, userId);
    if (!_isCurrent(generation, userId)) return;
    if (!force && _isFresh()) {
      _isLoading = false;
      notifyListeners();
      return;
    }
    if (_rawFavourites.isEmpty) {
      _isLoading = true;
      notifyListeners();
    }
    try {
      final res = await Supabase.instance.client
          .from('user_favourites')
          .select('id, product_key, shade_key, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      if (!_isCurrent(generation, userId)) return;
      final fetched = _dedupe(List<Map<String, dynamic>>.from(res));
      final next = CachePolicy.afterRefresh(_rawFavourites, fetched);
      _rawFavourites = next ?? _rawFavourites;
      _rebuildKeys();
      _cachedAt = DateTime.now();
      await _saveToDisk(generation, userId);
    } catch (e) {
      debugPrint('❌ Favourites fetch failed: $e');
    } finally {
      if (_isCurrent(generation, userId)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void _rebuildKeys() {
    _favouriteKeys.clear();
    for (var item in _rawFavourites) {
      final pk = item['product_key'] as String;
      final sk = item['shade_key'] as String?;
      _favouriteKeys.add('${pk}__${sk ?? ''}');
    }
  }

  Future<void> _loadFromDisk(int generation, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(generation, userId)) return;
      final cached = prefs.getString(prefsKeyFor(userId));
      if (cached == null || cached.isEmpty) return;
      final envelope = CacheEnvelope.decode(jsonDecode(cached));
      if (!_isCurrent(generation, userId)) return;
      _cachedAt = envelope.cachedAt;
      _rawFavourites = _dedupe(
        envelope.items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
      );
      _rebuildKeys();
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Favourites disk load failed: $e');
    }
  }

  Future<void> _saveToDisk(int generation, String userId) async {
    try {
      if (!_isCurrent(generation, userId)) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(generation, userId)) return;
      await prefs.setString(
        prefsKeyFor(userId),
        jsonEncode(
          CacheEnvelope(cachedAt: _cachedAt ?? DateTime.now(), items: _rawFavourites).encode(),
        ),
      );
      if (!_isCurrent(generation, userId)) {
        await prefs.remove(prefsKeyFor(userId));
      }
    } catch (e) {
      debugPrint('❌ Favourites disk save failed: $e');
    }
  }

  Future<void> _deleteDisk(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKeyFor(userId));
    } catch (e) {
      debugPrint('❌ Favourites disk clear failed: $e');
    }
  }

void listenRealtime(String userId) {
  if (_listeningUserId == userId && _channel != null) return;

  if (_channel != null) {
    Supabase.instance.client.removeChannel(_channel!);
  }
  _listeningUserId = userId;

  final session = Supabase.instance.client.auth.currentSession;
  if (session != null) {
    Supabase.instance.client.realtime.setAuth(session.accessToken);
  }

  _channel = Supabase.instance.client
      .channel('favourites-$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_favourites',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) {
          debugPrint('✅ Favourites realtime event: ${payload.eventType}');

          if (payload.eventType == PostgresChangeEvent.delete) {
            final oldRow = payload.oldRecord;
            final pk = oldRow['product_key'] as String?;
            final sk = oldRow['shade_key'] as String?;
            if (pk != null) {
              final key = '${pk}__${sk ?? ''}';
              _favouriteKeys.remove(key);
              _rawFavourites.removeWhere(
                  (f) => f['product_key'] == pk && (f['shade_key'] ?? '') == (sk ?? ''));
            }
          } else {
            // INSERT ya UPDATE
            final row = payload.newRecord;
            final pk = row['product_key'] as String?;
            final sk = row['shade_key'] as String?;
            if (pk != null) {
              final key = '${pk}__${sk ?? ''}';
              if (!_favouriteKeys.contains(key)) {
                _favouriteKeys.add(key);
                _rawFavourites.insert(0, row);
              }
            }
          }
          if (_activeUserId == userId) {
            _saveToDisk(_generation, userId);
          }
          notifyListeners();
        },
      )
      .subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint('✅ Favourites realtime connected');
        } else if (error != null) {
          debugPrint('❌ Favourites realtime error: $error');
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

  Future<void> toggleFavourite(String productKey, String? shadeKey) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final generation = _generation;
    _activeUserId ??= userId;

    final normalizedShade =
        shadeKey ?? ''; // 🆕 hamesha string, kabhi null nahi
    final key = '${productKey}__$normalizedShade';
    final isCurrentlyFav = _favouriteKeys.contains(key);

    if (isCurrentlyFav) {
      _favouriteKeys.remove(key);
      _rawFavourites.removeWhere(
        (f) =>
            f['product_key'] == productKey &&
            (f['shade_key'] ?? '') == normalizedShade,
      );
    } else {
      _favouriteKeys.add(key);
      _rawFavourites.insert(0, {
        'product_key': productKey,
        'shade_key': normalizedShade,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    notifyListeners();
    await _saveToDisk(generation, userId);

    try {
      if (isCurrentlyFav) {
        await Supabase.instance.client
            .from('user_favourites')
            .delete()
            .eq('user_id', userId)
            .eq('product_key', productKey)
            .eq('shade_key', normalizedShade); // 🆕 pehle .isFilter(...) tha
      } else {
        await Supabase.instance.client
            .from('user_favourites')
            .upsert(
              {
                'user_id': userId,
                'product_key': productKey,
                'shade_key': normalizedShade,
              },
              onConflict: 'user_id,product_key,shade_key',
              ignoreDuplicates:
                  true, // 🆕 duplicate insert error ki jagah silently skip
            );
      }
    } catch (e) {
      debugPrint('❌ Favourite sync failed: $e');
      if (isCurrentlyFav) {
        _favouriteKeys.add(key);
      } else {
        _favouriteKeys.remove(key);
      }
      notifyListeners();
      await _saveToDisk(generation, userId);
    }
  }

  void clear() {
    final previousUser = _activeUserId;
    _generation++;
    _activeUserId = null;
    _cachedAt = null;
    _inflight = null;
    _favouriteKeys.clear();
    _rawFavourites.clear();
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
