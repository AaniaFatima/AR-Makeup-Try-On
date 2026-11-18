import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// One image disk cache for every [CachedNetworkImage].
/// flutter_cache_manager is already locked via cached_network_image (3.4.1).
class AppImageCache {
  static const String cacheKey = 'arMakeupImageCache';

  static final CacheManager manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: Duration(days: 30),
      maxNrOfCacheObjects: 300,
    ),
  );
}
