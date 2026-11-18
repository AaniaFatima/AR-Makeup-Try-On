import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_policy.dart';

class ShadeDiskSnapshot {
  final DateTime? cachedAt;
  final List<Map<String, dynamic>> shades;

  const ShadeDiskSnapshot({required this.cachedAt, required this.shades});

  bool isFreshAt(DateTime now) =>
      CachePolicy.isFresh(cachedAt, CachePolicy.shadesTtl, now);
}

/// Shared shade file used by try-on and foundation match.
/// Public catalog data, so it is not keyed by user and is not cleared on sign-out.
class ShadeDiskCache {
  static const String fileName = 'product_shades_cache.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  static ShadeDiskSnapshot decodeContents(String contents) {
    if (contents.trim().isEmpty) {
      return const ShadeDiskSnapshot(cachedAt: null, shades: []);
    }
    final envelope = CacheEnvelope.decode(jsonDecode(contents), itemsKey: 'shades');
    final shades = <Map<String, dynamic>>[];
    for (final item in envelope.items) {
      if (item is Map) shades.add(Map<String, dynamic>.from(item));
    }
    return ShadeDiskSnapshot(cachedAt: envelope.cachedAt, shades: shades);
  }

  static Future<ShadeDiskSnapshot> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return const ShadeDiskSnapshot(cachedAt: null, shades: []);
      }
      return decodeContents(await file.readAsString());
    } catch (_) {
      return const ShadeDiskSnapshot(cachedAt: null, shades: []);
    }
  }

  static Future<void> write(List<Map<String, dynamic>> shades, DateTime cachedAt) async {
    final file = await _file();
    final payload = CacheEnvelope(cachedAt: cachedAt, items: shades).encode(itemsKey: 'shades');
    await file.writeAsString(jsonEncode(payload), flush: true);
  }
}
