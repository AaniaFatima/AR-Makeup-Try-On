/// Shared freshness rules for device-local caches.
///
/// Public catalog copies (products, shades) can sit for hours. Lists that
/// belong to one account (looks, favourites, bag) refresh much sooner.
/// A failed refresh returns null from the network helper and must keep the
/// previous copy.
class CachePolicy {
  static const Duration productsTtl = Duration(hours: 6);
  static const Duration shadesTtl = Duration(hours: 6);
  static const Duration userListTtl = Duration(minutes: 10);

  static bool isFresh(DateTime? cachedAt, Duration ttl, DateTime now) {
    if (cachedAt == null) return false;
    final age = now.difference(cachedAt);
    if (age.isNegative) return false;
    return age < ttl;
  }

  /// [fetched] is null when the refresh failed. The previous copy stays.
  static List<T>? afterRefresh<T>(List<T>? previous, List<T>? fetched) {
    if (fetched == null) return previous;
    return fetched;
  }
}

/// Disk payload. Older files were a bare list and have no [cachedAt], so they
/// are treated as stale and refreshed once.
class CacheEnvelope {
  final DateTime? cachedAt;
  final List<dynamic> items;

  const CacheEnvelope({required this.cachedAt, required this.items});

  static CacheEnvelope decode(dynamic decoded, {String itemsKey = 'items'}) {
    if (decoded is List) {
      return CacheEnvelope(cachedAt: null, items: decoded);
    }
    if (decoded is Map) {
      final rawItems = decoded[itemsKey];
      final items = rawItems is List ? rawItems : const <dynamic>[];
      final rawAt = decoded['cachedAt'];
      final cachedAt = rawAt == null ? null : DateTime.tryParse(rawAt.toString());
      return CacheEnvelope(cachedAt: cachedAt, items: items);
    }
    return const CacheEnvelope(cachedAt: null, items: <dynamic>[]);
  }

  Map<String, dynamic> encode({String itemsKey = 'items'}) {
    return {
      'cachedAt': (cachedAt ?? DateTime.now()).toUtc().toIso8601String(),
      itemsKey: items,
    };
  }
}
