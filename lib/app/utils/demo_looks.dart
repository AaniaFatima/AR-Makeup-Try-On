// Colour-harmony companions and wear order for the demo.
//
// Shade choice uses the ΔE2000 sort and hue axis already in skin_color.dart.
// It does not change the foundation matcher's thresholds, and it never writes
// shade_hex or shade_key.

import 'dart:math' as math;

import 'skin_color.dart';

/// Shown next to a harmony look. Not a colourimeter claim.
const String harmonySuggestionNote =
    'A colour-harmony suggestion from the measured colour, not a colourimeter reading.';

/// Same words the look page uses when a saved product cannot be bought.
const String missingCatalogProductLabel = "Can't buy — unavailable";

const List<String> wearZoneOrder = ['foundation', 'eyes', 'cheeks', 'lips'];

class CatalogShade {
  const CatalogShade({
    required this.productKey,
    required this.shadeKey,
    required this.shadeName,
    required this.shadeHex,
  });

  final String productKey;
  final String shadeKey;
  final String shadeName;
  final String shadeHex;

  factory CatalogShade.fromMap(Map<String, dynamic> map) => CatalogShade(
        productKey: map['product_key']?.toString() ?? '',
        shadeKey: map['shade_key']?.toString() ?? '',
        shadeName: map['shade_name']?.toString() ?? '',
        shadeHex: (map['shade_hex'] ?? map['hex'])?.toString() ?? '',
      );
}

class WearOrderLine {
  const WearOrderLine({
    required this.zone,
    required this.zoneLabel,
    required this.title,
    required this.intensity,
    required this.missing,
  });

  final String zone;
  final String zoneLabel;
  final String title;
  final int intensity;
  final bool missing;
}

String? wearZoneForKey(String productKey) {
  if (productKey.startsWith('fnd_')) return 'foundation';
  if (productKey.startsWith('esh_') ||
      productKey.startsWith('eln_') ||
      productKey.startsWith('mas_') ||
      productKey.startsWith('lsh_')) {
    return 'eyes';
  }
  if (productKey.startsWith('blu_') || productKey.startsWith('hgl_')) {
    return 'cheeks';
  }
  if (productKey.startsWith('lip_') || productKey.startsWith('gloss_')) {
    return 'lips';
  }
  return null;
}

String wearZoneLabel(String zone) {
  switch (zone) {
    case 'foundation':
      return 'Foundation';
    case 'eyes':
      return 'Eyes';
    case 'cheeks':
      return 'Cheeks';
    case 'lips':
      return 'Lips';
    default:
      return 'Other';
  }
}

/// Fixed order: foundation, eyes, cheeks, lips. Unknown keys stay, after those.
///
/// [titleFor] returns the product name, or null when the catalog row is gone.
List<WearOrderLine> wearOrderForItems(
  List<Map<String, dynamic>> items, {
  String? Function(Map<String, dynamic> item)? titleFor,
}) {
  final ranked = <({int zoneIndex, int layer, int index, Map<String, dynamic> item})>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final key = item['product_key']?.toString() ?? '';
    final zone = wearZoneForKey(key);
    final zoneIndex = zone == null ? wearZoneOrder.length : wearZoneOrder.indexOf(zone);
    final layer = (item['layer_order'] as num?)?.toInt() ?? i;
    ranked.add((zoneIndex: zoneIndex, layer: layer, index: i, item: item));
  }
  ranked.sort((a, b) {
    final byZone = a.zoneIndex.compareTo(b.zoneIndex);
    if (byZone != 0) return byZone;
    final byLayer = a.layer.compareTo(b.layer);
    if (byLayer != 0) return byLayer;
    return a.index.compareTo(b.index);
  });

  return ranked.map((row) {
    final key = row.item['product_key']?.toString() ?? '';
    final zone = wearZoneForKey(key) ?? 'other';
    final resolved = titleFor?.call(row.item)?.trim();
    final missing = resolved == null || resolved.isEmpty;
    return WearOrderLine(
      zone: zone,
      zoneLabel: wearZoneLabel(zone),
      title: missing ? missingCatalogProductLabel : resolved,
      intensity: (row.item['intensity'] as num?)?.round() ?? 0,
      missing: missing,
    );
  }).toList();
}

/// A reference colour to search toward. Not a product and not a match score.
///
/// Hue follows [Lab.hueDegrees]: a larger angle leans golden, a smaller one
/// leans pink. Warm and olive shift toward gold; cool shifts toward pink.
String harmonyTargetHex({
  required String skinHex,
  required String undertone,
  required bool lip,
}) {
  final skin = hexToLab(skinHex);
  if (skin == null) {
    return lip ? '#C46A5A' : '#E3A8A1';
  }
  final tone = undertone.toLowerCase();
  final warm = tone == 'warm' || tone == 'olive';
  final cool = tone == 'cool';
  final shift = cool ? -18.0 : warm ? 10.0 : -4.0;
  final hue = (skin.hueDegrees + (lip ? shift * 1.35 : shift) + 360) % 360;
  final chroma = (skin.chroma + (lip ? 26 : 16)).clamp(8.0, 55.0);
  final lightness = (skin.l + (lip ? -14 : 2)).clamp(22.0, 88.0);
  final radians = hue * math.pi / 180;
  final rgb = labToRgb(Lab(
    lightness,
    chroma * math.cos(radians),
    chroma * math.sin(radians),
  ));
  return rgbToHex(rgb[0], rgb[1], rgb[2]);
}

/// Nearest catalog shade to the harmony target. A thin list still returns the
/// closest row it has. Returns null only when [shades] is empty.
CatalogShade? nearestHarmonyShade({
  required List<Map<String, dynamic>> shades,
  required String skinHex,
  required String undertone,
  required bool lip,
}) {
  if (shades.isEmpty) return null;
  final target = harmonyTargetHex(
    skinHex: skinHex,
    undertone: undertone,
    lip: lip,
  );
  final scored = scoreShadesBySkinTone(shades, target);
  if (scored.isEmpty || !scored.first.deltaE.isFinite) {
    return CatalogShade.fromMap(shades.first);
  }

  final tone = undertone.toLowerCase();
  final wantWarm = tone == 'warm' || tone == 'olive';
  final wantCool = tone == 'cool';
  final skin = hexToLab(skinHex);
  var pick = scored.first;
  if (skin != null && (wantWarm || wantCool)) {
    for (final candidate in scored) {
      if (candidate.deltaE > scored.first.deltaE + 1.5) break;
      final lab = hexToLab(
        (candidate.shade['shade_hex'] ?? candidate.shade['hex'])?.toString(),
      );
      if (lab == null) continue;
      final aligned = wantWarm
          ? lab.hueDegrees >= skin.hueDegrees
          : lab.hueDegrees <= skin.hueDegrees;
      if (aligned) {
        pick = candidate;
        break;
      }
    }
  }
  return CatalogShade.fromMap(pick.shade);
}

/// The shade filling more of the frame. [split] is how much of shade A shows,
/// from 0 (only B) to 1 (only A). A tie keeps A.
CatalogShade compareWinner(CatalogShade a, CatalogShade b, double split) {
  return split >= 0.5 ? a : b;
}
