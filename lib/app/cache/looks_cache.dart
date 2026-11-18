// looks_cache.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cache_policy.dart';

typedef LooksFetcher = Future<List<Map<String, dynamic>>> Function(String userId);

class LooksCache {
  LooksCache._({LooksFetcher? fetchOverride}) : _fetchOverride = fetchOverride;

  /// Test seam. Production code uses [instance].
  @visibleForTesting
  LooksCache.forTest(LooksFetcher fetch) : _fetchOverride = fetch;

  static final LooksCache instance = LooksCache._();

  final LooksFetcher? _fetchOverride;

  // ── State ──────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _looks = [];
  bool _loaded = false;
  bool _loading = false;
  Completer<void>? _prefetchCompleter;

  /// Bumped by [clear] and by a forced refresh so an in-flight prefetch cannot
  /// write the previous user's looks back after sign-out.
  int _generation = 0;
  String? _activeUserId;
  DateTime? _cachedAt;

  // Expose read-only view
  List<Map<String, dynamic>> get looks => List.unmodifiable(_looks);
  bool get isLoaded => _loaded;
  bool get isLoading => _loading;

  /// Disk name for one account. Not a shared file, so the next sign-in cannot
  /// paint the previous gallery before the network returns.
  @visibleForTesting
  static String cacheFileNameFor(String userId) {
    final safe = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) return 'saved_looks_cache_unknown.json';
    return 'saved_looks_cache_$safe.json';
  }

  static const String legacyCacheFileName = 'saved_looks_cache.json';

  bool _isCurrent(int generation, String userId) =>
      generation == _generation && _activeUserId == userId;

  // ── File helpers ───────────────────────────────────────────────────────────
  Future<File> _cacheFileFor(String userId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${cacheFileNameFor(userId)}');
  }

  Future<File> _legacyCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$legacyCacheFileName');
  }

  // ── Listeners ──────────────────────────────────────────────────────────────
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in _listeners) {
      cb();
    }
  }

  // ── Load from cache file (offline) ─────────────────────────────────────────
  Future<void> _loadFromCacheFile(int generation, String userId) async {
    if (_fetchOverride != null) return;
    try {
      final file = await _cacheFileFor(userId);
      if (!_isCurrent(generation, userId)) return;
      if (!await file.exists()) return;

      final contents = await file.readAsString();
      if (!_isCurrent(generation, userId)) return;
      if (contents.isEmpty) return;

      final envelope = CacheEnvelope.decode(jsonDecode(contents));
      if (!_isCurrent(generation, userId)) return;
      _cachedAt = envelope.cachedAt;
      _looks = envelope.items
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      debugPrint('✓ Loaded ${_looks.length} looks from offline cache');
    } catch (e) {
      debugPrint('⚠️ Offline cache load failed: $e');
      if (_isCurrent(generation, userId)) _looks = [];
    }
  }

  // ── Save to cache file ─────────────────────────────────────────────────────
  Future<void> _saveToCacheFile(int generation, String userId) async {
    if (_fetchOverride != null) return;
    try {
      if (!_isCurrent(generation, userId)) return;
      final file = await _cacheFileFor(userId);
      if (!_isCurrent(generation, userId)) return;
      final payload = jsonEncode(
        CacheEnvelope(cachedAt: _cachedAt ?? DateTime.now(), items: _looks).encode(),
      );
      if (!_isCurrent(generation, userId)) return;
      await file.writeAsString(payload, flush: true);
      if (!_isCurrent(generation, userId)) {
        try {
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('⚠️ Stale looks cache delete failed: $e');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Cache file write failed: $e');
    }
  }

  Future<void> _deleteCacheFiles(String? userId) async {
    if (_fetchOverride != null) return;
    try {
      final legacy = await _legacyCacheFile();
      if (await legacy.exists()) await legacy.delete();
    } catch (e) {
      debugPrint('⚠️ Legacy looks cache delete failed: $e');
    }
    if (userId == null || userId.isEmpty) return;
    try {
      final file = await _cacheFileFor(userId);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('⚠️ Looks cache delete failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchLooks(String userId) {
    final override = _fetchOverride;
    if (override != null) return override(userId);
    return _fetchFromNetwork(userId);
  }

  Future<List<Map<String, dynamic>>> _fetchFromNetwork(String userId) async {
    final response = await Supabase.instance.client
        .from('saved_looks')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw TimeoutException('Network timeout'),
        );
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Prefetch (from network, fallback to offline) ────────────────────────────
  bool _isFresh() =>
      CachePolicy.isFresh(_cachedAt, CachePolicy.userListTtl, DateTime.now());

  Future<void> prefetch(String userId, {bool force = false}) async {
    if (_loaded && !force && _activeUserId == userId && _isFresh()) return;

    // A forced refresh must not adopt the in-flight result it is replacing.
    if (force && _loading) {
      _generation++;
      final pending = _prefetchCompleter;
      _prefetchCompleter = null;
      _loading = false;
      if (pending != null && !pending.isCompleted) pending.complete();
    }

    if (_loading && _prefetchCompleter != null && !force && _activeUserId == userId) {
      return _prefetchCompleter!.future;
    }

    final generation = _generation;
    _activeUserId = userId;
    _loading = true;
    final completer = Completer<void>();
    _prefetchCompleter = completer;
    var failed = false;

    try {
      await _loadFromCacheFile(generation, userId);
      if (!_isCurrent(generation, userId)) return;
      if (_looks.isNotEmpty) {
        _loaded = true;
        _notify();
      }
      if (!force && _isFresh()) {
        _loaded = true;
        _notify();
        return;
      }

      try {
        final response = await _fetchLooks(userId);
        if (!_isCurrent(generation, userId)) return;
        final next = CachePolicy.afterRefresh(_looks, response);
        _looks = next ?? _looks;
        if (response != null) _cachedAt = DateTime.now();
        _loaded = true;
        await _saveToCacheFile(generation, userId);
        if (!_isCurrent(generation, userId)) {
          _looks = [];
          _loaded = false;
          return;
        }
        _notify();
      } on SocketException catch (e) {
        debugPrint('⚠️ Network error: $e. Using offline cache.');
        if (!_isCurrent(generation, userId)) return;
        _loaded = true;
        _notify();
      } on TimeoutException catch (e) {
        debugPrint('⚠️ Network timeout: $e. Using offline cache.');
        if (!_isCurrent(generation, userId)) return;
        _loaded = true;
        _notify();
      }
    } catch (e) {
      if (!_isCurrent(generation, userId)) return;
      debugPrint('❌ LooksCache prefetch error: $e');
      _loaded = true;
      _notify();
      failed = true;
      if (!completer.isCompleted) completer.completeError(e);
    } finally {
      if (_isCurrent(generation, userId)) {
        _loading = false;
        if (!failed && !completer.isCompleted) completer.complete();
        if (identical(_prefetchCompleter, completer)) {
          _prefetchCompleter = null;
        }
      }
    }
  }

  // ── Optimistic insert ──────────────────────────────────────────────────────
  void optimisticAdd(Map<String, dynamic> look) {
    _looks.insert(0, look);
    _notify();
    final userId = _activeUserId;
    if (userId != null) {
      _saveToCacheFile(_generation, userId);
    }
  }

  // ── Update a look in-place ─────────────────────────────────────────────────
  void updateLook(String lookId, Map<String, dynamic> patch) {
    final idx = _looks.indexWhere((l) => l['id'] == lookId);
    if (idx != -1) {
      _looks[idx] = {..._looks[idx], ...patch};
      _notify();
      final userId = _activeUserId;
      if (userId != null) {
        _saveToCacheFile(_generation, userId);
      }
    }
  }

  // ── Update favourite flag ──────────────────────────────────────────────────
  void setFavourite(String lookId, bool value) {
    updateLook(lookId, {'is_favourite': value});
  }

  // ── Remove ─────────────────────────────────────────────────────────────────
  void remove(String lookId) {
    _looks.removeWhere((l) => l['id'] == lookId);
    _notify();
    final userId = _activeUserId;
    if (userId != null) {
      _saveToCacheFile(_generation, userId);
    }
  }

  // ── Hard refresh ───────────────────────────────────────────────────────────
  Future<void> refresh(String userId) {
    return prefetch(userId, force: true);
  }

  // ── Clear on logout ────────────────────────────────────────────────────────
  void clear() {
    final previousUser = _activeUserId;
    _generation++;
    _looks = [];
    _loaded = false;
    _loading = false;
    _activeUserId = null;
    _cachedAt = null;
    final pending = _prefetchCompleter;
    _prefetchCompleter = null;
    _notify();
    if (pending != null && !pending.isCompleted) pending.complete();
    _deleteCacheFiles(previousUser);
  }
}
