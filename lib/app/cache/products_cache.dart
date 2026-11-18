// products_cache.dart
//
// The app's copy of the `makeup_products` catalog.
//
// ## Why the app needs this
//
// The try-on screen only ever loaded `product_shades` — colours, keyed by
// `product_key`. That is enough to paint a face, but it means the app knows a
// shade's hex and nothing else: no product name, no brand, no image, no price.
//
// Every Phase 1 feature needs exactly that missing half:
//   * Favourites      → show what was favourited (name, brand, image)
//   * Makeup Bag      → browse and pick products, not raw swatches
//   * Buy This Look   → total the look's price before opening the web checkout
//
// So one small cache unlocks all three. It follows the same shape as
// [LooksCache]: read the on-disk copy first so the UI is instant and works
// offline, then reconcile with the network in the background.
//
// The catalog is public data (no `user_id`), so it is not cleared on sign-out.
//
// ## main_category
//
// `makeup_products` holds both makeup and skincare rows (same table, shared
// with the web catalog). The app is makeup-only for now, so the network fetch
// filters to `main_category = 'makeup'` — skincare rows never even reach the
// device. If skincare is ever needed in-app, drop the `.eq(...)` filter below
// and filter per-screen instead.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cache_policy.dart';

// ── MODEL ────────────────────────────────────────────────────────────────────

class DbProduct {
  final String productKey;
  final String name;
  final String? brand;
  final String? category;
  final String? mainCategory; // 🆕 'makeup' | 'skincare'
  final String? imageUrl;
  final double? price;
  final String? finish;
  final bool isSkinFriendly;
  final bool isActive;

  const DbProduct({
    required this.productKey,
    required this.name,
    this.brand,
    this.category,
    this.mainCategory, // 🆕
    this.imageUrl,
    this.price,
    this.finish,
    this.isSkinFriendly = false,
    this.isActive = true,
  });

  factory DbProduct.fromMap(Map<String, dynamic> map) => DbProduct(
    productKey: map['product_key']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    brand: _nullIfBlank(map['brand']),
    category: _nullIfBlank(map['category']),
    mainCategory: _nullIfBlank(map['main_category']), // 🆕
    imageUrl: _nullIfBlank(map['image_url']),
    price: (map['price'] as num?)?.toDouble(),
    finish: _nullIfBlank(map['finish']),
    isSkinFriendly: map['is_skin_friendly'] == true,
    // Treat a missing flag as active — a null here should not hide a product.
    isActive: map['is_active'] != false,
  );

  Map<String, dynamic> toMap() => {
    'product_key': productKey,
    'name': name,
    'brand': brand,
    'category': category,
    'main_category': mainCategory, // 🆕
    'image_url': imageUrl,
    'price': price,
    'finish': finish,
    'is_skin_friendly': isSkinFriendly,
    'is_active': isActive,
  };

  String get displayName => name.isEmpty ? productKey : name;
  String get displayBrand => (brand == null || brand!.isEmpty) ? '—' : brand!;

  static String? _nullIfBlank(dynamic value) {
    final s = value?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

// ── CACHE ────────────────────────────────────────────────────────────────────

class ProductsCache implements Listenable {
  ProductsCache._();
  static final ProductsCache instance = ProductsCache._();

  /// Supabase caps a single `select()` at 1,000 rows. The catalog is larger
  /// than that, so it has to be paged — same as `getProducts()` on the web
  /// (`src/lib/catalog/queries.ts`).
  static const int _pageSize = 1000;

  /// Hard stop so a misbehaving server can never spin this forever.
  static const int _maxPages = 50;

  static const Duration _networkTimeout = Duration(seconds: 10);

  // ── State ──────────────────────────────────────────────────────────────────
  List<DbProduct> _products = [];
  Map<String, DbProduct> _byKey = {};
  bool _loaded = false;
  bool _loading = false;
  Completer<void>? _prefetchCompleter;
  DateTime? _cachedAt;

  List<DbProduct> get products => List.unmodifiable(_products);
  List<DbProduct> get activeProducts =>
      _products.where((p) => p.isActive).toList();
  bool get isLoaded => _loaded;
  bool get isLoading => _loading;
  bool get isEmpty => _products.isEmpty;

  // ── Lookups ────────────────────────────────────────────────────────────────

  /// The product behind a `product_key`, or null if the catalog hasn't loaded
  /// or the key no longer exists.
  DbProduct? byKey(String productKey) => _byKey[productKey];

  double? priceOf(String productKey) => _byKey[productKey]?.price;

  /// Total price of a set of `product_key`s, plus how many of them could not be
  /// priced. The caller decides how to present a partial total — a saved look
  /// can reference a product that was since deleted or de-listed.
  ({double total, int pricedCount, int missingCount}) totalFor(
    Iterable<String> productKeys,
  ) {
    double total = 0;
    int priced = 0;
    int missing = 0;
    for (final key in productKeys) {
      final price = _byKey[key]?.price;
      if (price == null) {
        missing++;
      } else {
        total += price;
        priced++;
      }
    }
    return (total: total, pricedCount: priced, missingCount: missing);
  }

  /// Distinct categories present in the catalog, alphabetically.
  List<String> get categories {
    final set = <String>{};
    for (final p in _products) {
      final c = p.category;
      if (c != null && c.isNotEmpty) set.add(c);
    }
    final list = set.toList()..sort();
    return list;
  }

  // ── Listeners ──────────────────────────────────────────────────────────────
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List<VoidCallback>.from(_listeners)) {
      cb();
    }
  }

  // ── File helpers ───────────────────────────────────────────────────────────
  Future<File> get _cacheFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/makeup_products_cache.json');
  }

  Future<void> _loadFromCacheFile() async {
    try {
      final file = await _cacheFile;
      if (!await file.exists()) return;

      final contents = await file.readAsString();
      if (contents.isEmpty) return;

      final envelope = CacheEnvelope.decode(jsonDecode(contents), itemsKey: 'products');
      _cachedAt = envelope.cachedAt;
      final cached = envelope.items
          .whereType<Map>()
          .map((item) => DbProduct.fromMap(Map<String, dynamic>.from(item)))
          .where((p) => p.productKey.isNotEmpty)
          .toList();

      if (cached.isNotEmpty) {
        _setProducts(cached);
        debugPrint('✓ Loaded ${cached.length} products from offline cache');
      }
    } catch (e) {
      debugPrint('⚠️ Products cache load failed: $e');
    }
  }

  Future<void> _saveToCacheFile() async {
    try {
      final file = await _cacheFile;
      final payload = CacheEnvelope(
        cachedAt: _cachedAt ?? DateTime.now(),
        items: _products.map((p) => p.toMap()).toList(),
      ).encode(itemsKey: 'products');
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      debugPrint('⚠️ Products cache write failed: $e');
    }
  }

  void _setProducts(List<DbProduct> products) {
    _products = products;
    _byKey = {for (final p in products) p.productKey: p};
  }

  // ── Prefetch ───────────────────────────────────────────────────────────────

  /// Loads the catalog: disk first (instant, offline-safe), then network.
  ///
  /// Safe to call from anywhere — concurrent callers share one in-flight fetch,
  /// and it never throws: a failed refresh just leaves the cached copy in place.
  bool _isFresh() =>
      CachePolicy.isFresh(_cachedAt, CachePolicy.productsTtl, DateTime.now());

  Future<void> prefetch({bool force = false}) async {
    if (_loaded && !force && _isFresh()) return;

    if (_loading && _prefetchCompleter != null) {
      return _prefetchCompleter!.future;
    }

    _loading = true;
    _prefetchCompleter = Completer<void>();

    try {
      if (_products.isEmpty) {
        await _loadFromCacheFile();
        if (_products.isNotEmpty) _notify();
      }

      if (!force && _products.isNotEmpty && _isFresh()) {
        _loaded = true;
        _notify();
        return;
      }

      final fetched = await _fetchAllFromNetwork();
      final next = CachePolicy.afterRefresh(
        _products.isEmpty ? null : _products,
        fetched,
      );
      if (fetched != null && next != null && next.isNotEmpty) {
        _setProducts(next);
        _cachedAt = DateTime.now();
        await _saveToCacheFile();
      }

      _loaded = true;
      _notify();
    } catch (e) {
      // Deliberately swallowed: the catalog is a nicety, never a blocker.
      debugPrint('❌ ProductsCache prefetch error: $e');
      _loaded = true;
      _notify();
    } finally {
      _loading = false;
      _prefetchCompleter?.complete();
      _prefetchCompleter = null;
    }
  }

  Future<void> refresh() => prefetch(force: true);

  /// Returns null when the network could not be reached at all, so the caller
  /// can tell "offline" apart from "the catalog is genuinely empty".
  Future<List<DbProduct>?> _fetchAllFromNetwork() async {
    final all = <DbProduct>[];

    try {
      for (var page = 0; page < _maxPages; page++) {
        final from = page * _pageSize;
        final to = from + _pageSize - 1;

        final res = await Supabase.instance.client
            .from('makeup_products')
            .select(
              'product_key,name,brand,category,main_category,image_url,price,finish,'
              'is_skin_friendly,is_active',
            )
            .eq('main_category', 'makeup') // 🆕 app abhi makeup-only hai
            .range(from, to)
            .timeout(
              _networkTimeout,
              onTimeout: () => throw TimeoutException('Network timeout'),
            );

        final rows = (res as List<dynamic>)
            .map(
              (e) => DbProduct.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .where((p) => p.productKey.isNotEmpty)
            .toList();

        all.addAll(rows);

        if (rows.length < _pageSize) break;
      }
    } on SocketException catch (e) {
      debugPrint('⚠️ ProductsCache network error: $e. Using offline cache.');
      return null;
    } on TimeoutException catch (e) {
      debugPrint('⚠️ ProductsCache timeout: $e. Using offline cache.');
      return null;
    } catch (e) {
      debugPrint('❌ ProductsCache fetch failed: $e');
      return null;
    }

    // Last write wins on duplicate keys — `product_key` is unique upstream,
    // this only guards against a bad paging boundary.
    final unique = <String, DbProduct>{};
    for (final p in all) {
      unique[p.productKey] = p;
    }
    return unique.values.toList();
  }
}