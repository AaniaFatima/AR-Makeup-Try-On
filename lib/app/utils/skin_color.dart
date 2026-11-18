// lib/app/utils/skin_color.dart
//
// CIELAB colour science for foundation shade matching, on device.
//
// This is a faithful port of `src/lib/foundation/color.ts` on the website. The
// duplication is deliberate and the reason matters: the *recommendation* comes
// from the API so there is one authority for it, but the try-on sheet has to sort
// shades and draw the "closest match" badge while the user is standing in front of
// the camera — offline, with no round trip, sixty times a second's worth of
// scrolling. If that sort used a different metric from the API, the badge would
// land on a different shade than the result screen recommended, for the same face.
// That contradiction is worse than the duplication.
//
// Both sides are verified against the same published test vectors
// (`npm run verify:foundation` on the web project), so "faithful" is a checkable
// claim rather than an intention.
//
// The existing `color_utils.dart` sorts by straight-line RGB distance. That is
// kept for compatibility but should not be used for skin: RGB distance is not
// perceptual, and in the yellow-red, low-chroma region skin occupies it ranks an
// obviously-too-orange foundation above a good match. Everything here works in
// CIELAB with ΔE2000 instead.

import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// CIE 1976 L*a*b*, D65 illuminant / 2° observer.
class Lab {
  const Lab(this.l, this.a, this.b);

  /// Lightness, 0 (black) – 100 (white).
  final double l;

  /// Green (−) ↔ red (+).
  final double a;

  /// Blue (−) ↔ yellow (+).
  final double b;

  /// C*ab — chroma. How saturated, independent of hue.
  double get chroma => math.sqrt(a * a + b * b);

  /// h°ab — hue angle in degrees, 0–360. The undertone axis for skin: a larger
  /// angle leans golden/warm, a smaller one leans pink/cool.
  double get hueDegrees {
    final deg = math.atan2(b, a) * 180 / math.pi;
    return deg < 0 ? deg + 360 : deg;
  }

  @override
  String toString() =>
      'Lab(${l.toStringAsFixed(1)}, ${a.toStringAsFixed(1)}, ${b.toStringAsFixed(1)})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Hex ↔ RGB
// ─────────────────────────────────────────────────────────────────────────────

/// Parses `#RRGGBB`, `RRGGBB`, `0xRRGGBB` or `#RGB` into a packed 0xRRGGBB int.
///
/// Returns null rather than throwing. A bad `shade_hex` in the catalog must drop
/// that one shade out of the ranking, not take the whole screen down with it —
/// this is called in a list builder while the camera is live.
int? parseHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim().replaceAll('#', '').replaceAll('0x', '').replaceAll('0X', '');
  if (h.length == 3) {
    h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
  }
  if (h.length != 6) return null;
  final value = int.tryParse(h, radix: 16);
  if (value == null) return null;
  return value;
}

String rgbToHex(int r, int g, int b) {
  String c(int v) =>
      v.clamp(0, 255).toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${c(r)}${c(g)}${c(b)}';
}

// ─────────────────────────────────────────────────────────────────────────────
// sRGB → CIELAB
// ─────────────────────────────────────────────────────────────────────────────

/// sRGB inverse companding (IEC 61966-2-1).
///
/// Camera pixels are gamma-encoded; every piece of colour arithmetic below is only
/// valid on linear light. Skipping this step is the single most common reason
/// naive skin-tone matchers are wrong at the light and dark ends of the range —
/// and it is invisible in the middle, which is why it survives testing.
double _srgbToLinear(int channel255) {
  final c = channel255 / 255.0;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _linearToSrgb(double linear) {
  final c = linear <= 0.0031308
      ? linear * 12.92
      : 1.055 * math.pow(linear, 1 / 2.4).toDouble() - 0.055;
  return (c * 255).clamp(0.0, 255.0);
}

/// D65 white point, 2° observer (CIE 15:2004).
const double _wx = 0.95047;
const double _wy = 1.0;
const double _wz = 1.08883;

/// CIE 15:2004 §8.2.1. The 6/29 branch avoids the cube root's infinite slope at 0.
double _labF(double t) {
  const delta = 6.0 / 29.0;
  const delta3 = delta * delta * delta;
  return t > delta3 ? math.pow(t, 1 / 3).toDouble() : t / (3 * delta * delta) + 4 / 29;
}

double _labFInv(double t) {
  const delta = 6.0 / 29.0;
  return t > delta ? t * t * t : 3 * delta * delta * (t - 4 / 29);
}

Lab rgbToLab(int r, int g, int b) {
  final rl = _srgbToLinear(r);
  final gl = _srgbToLinear(g);
  final bl = _srgbToLinear(b);

  // sRGB → XYZ, D65 (IEC 61966-2-1 Annex A).
  final x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375;
  final y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750;
  final z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041;

  final fx = _labF(x / _wx);
  final fy = _labF(y / _wy);
  final fz = _labF(z / _wz);

  return Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

/// Inverse of [rgbToLab]. Used to render a measured tone as a swatch.
List<int> labToRgb(Lab lab) {
  final fy = (lab.l + 16) / 116;
  final fx = fy + lab.a / 500;
  final fz = fy - lab.b / 200;

  final x = _labFInv(fx) * _wx;
  final y = _labFInv(fy) * _wy;
  final z = _labFInv(fz) * _wz;

  final r = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
  final g = x * -0.9692660 + y * 1.8760108 + z * 0.0415560;
  final b = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;

  return [
    _linearToSrgb(r).round(),
    _linearToSrgb(g).round(),
    _linearToSrgb(b).round(),
  ];
}

/// Parses a hex string straight to Lab. Null on an unparseable value.
Lab? hexToLab(String? hex) {
  final packed = parseHexColor(hex);
  if (packed == null) return null;
  return rgbToLab((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF);
}

/// L* only, which is all the per-pixel rejection pass needs.
///
/// Worth having separately: the full [rgbToLab] runs three `pow` calls plus a
/// matrix multiply, and the sampler calls this once per pixel over tens of
/// thousands of pixels. This path does the companding and one cube root.
double luminanceLStar(int r, int g, int b) {
  final y = _srgbToLinear(r) * 0.2126729 +
      _srgbToLinear(g) * 0.7151522 +
      _srgbToLinear(b) * 0.0721750;
  return 116 * _labF(y / _wy) - 16;
}

// ─────────────────────────────────────────────────────────────────────────────
// Derived quantities
// ─────────────────────────────────────────────────────────────────────────────

/// Individual Typology Angle — ITA°, the standard instrumental measure of
/// constitutive skin pigmentation.
///
///     ITA° = arctan((L* − 50) / b*) × 180 / π
///
/// Chardon A., Cretois I., Hourseau C. (1991), "Skin colour typology and
/// suntanning pathways", Int. J. Cosmet. Sci. 13(4):191–208. Class boundaries
/// follow Del Bino S. & Bernerd F. (2013), Br. J. Dermatol. 169(s3):33–40.
///
/// Preferred over raw L* because it folds in yellowness, which is what separates
/// a genuinely light complexion from an over-exposed photograph.
double itaDegrees(Lab lab) {
  // Skin is never truly achromatic, but a badly white-balanced photo can get
  // close enough that b* ≈ 0 would blow this up.
  final safeB = lab.b.abs() < 1e-6 ? (lab.b < 0 ? -1e-6 : 1e-6) : lab.b;
  return math.atan((lab.l - 50) / safeB) * 180 / math.pi;
}

/// Del Bino's six ITA° classes, named as the `depth_level` column's six values.
String depthFromIta(double ita) {
  if (ita > 55) return 'fair';
  if (ita > 41) return 'light';
  if (ita > 28) return 'medium';
  if (ita > 10) return 'tan';
  if (ita > -30) return 'deep';
  return 'rich';
}

// ─────────────────────────────────────────────────────────────────────────────
// CIEDE2000
// ─────────────────────────────────────────────────────────────────────────────

const double _deg = 180 / math.pi;
const double _rad = math.pi / 180;

/// CIEDE2000 colour difference, ΔE00.
///
/// CIE 142-2001; implemented against the worked formulation and the 34-pair test
/// set in Sharma G., Wu W., Dalal E. (2005), "The CIEDE2000 color-difference
/// formula: implementation notes, supplementary test data, and mathematical
/// observations", Color Res. Appl. 30(1):21–30.
///
/// Plain Euclidean ΔE76 is not good enough here. CIELAB is badly non-uniform in
/// exactly the region skin occupies — low-to-moderate chroma, yellow-red hues —
/// so ΔE76 over-weights chroma differences and ranks a too-orange foundation
/// above a good match. ΔE00 adds the lightness/chroma/hue weighting functions
/// (S_L, S_C, S_H) and the blue-region rotation term R_T that correct for it.
///
/// kL = kC = kH = 1 (reference conditions).
double deltaE2000(Lab lab1, Lab lab2) {
  const kL = 1.0, kC = 1.0, kH = 1.0;

  final c1 = math.sqrt(lab1.a * lab1.a + lab1.b * lab1.b);
  final c2 = math.sqrt(lab2.a * lab2.a + lab2.b * lab2.b);
  final cBar = (c1 + c2) / 2;

  // G rescales a* so near-neutral colours are compared on a hue axis that does
  // not collapse — the fix for CIELAB's poor behaviour close to grey.
  final cBar7 = math.pow(cBar, 7).toDouble();
  final g = 0.5 * (1 - math.sqrt(cBar7 / (cBar7 + math.pow(25, 7))));

  final a1p = (1 + g) * lab1.a;
  final a2p = (1 + g) * lab2.a;
  final c1p = math.sqrt(a1p * a1p + lab1.b * lab1.b);
  final c2p = math.sqrt(a2p * a2p + lab2.b * lab2.b);

  // atan2 of an achromatic colour is meaningless; the standard defines h' = 0.
  final h1p = c1p == 0 ? 0.0 : (math.atan2(lab1.b, a1p) * _deg + 360) % 360;
  final h2p = c2p == 0 ? 0.0 : (math.atan2(lab2.b, a2p) * _deg + 360) % 360;

  final dLp = lab2.l - lab1.l;
  final dCp = c2p - c1p;

  double dhp;
  if (c1p * c2p == 0) {
    dhp = 0;
  } else if ((h2p - h1p).abs() <= 180) {
    dhp = h2p - h1p;
  } else if (h2p - h1p > 180) {
    dhp = h2p - h1p - 360;
  } else {
    dhp = h2p - h1p + 360;
  }

  final dHp = 2 * math.sqrt(c1p * c2p) * math.sin(dhp * _rad / 2);

  final lBarP = (lab1.l + lab2.l) / 2;
  final cBarP = (c1p + c2p) / 2;

  double hBarP;
  if (c1p * c2p == 0) {
    hBarP = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hBarP = (h1p + h2p) / 2;
  } else if (h1p + h2p < 360) {
    hBarP = (h1p + h2p + 360) / 2;
  } else {
    hBarP = (h1p + h2p - 360) / 2;
  }

  final t = 1 -
      0.17 * math.cos((hBarP - 30) * _rad) +
      0.24 * math.cos(2 * hBarP * _rad) +
      0.32 * math.cos((3 * hBarP + 6) * _rad) -
      0.20 * math.cos((4 * hBarP - 63) * _rad);

  final dTheta = 30 * math.exp(-math.pow((hBarP - 275) / 25, 2).toDouble());
  final cBarP7 = math.pow(cBarP, 7).toDouble();
  final rc = 2 * math.sqrt(cBarP7 / (cBarP7 + math.pow(25, 7)));

  final sl = 1 +
      (0.015 * math.pow(lBarP - 50, 2)) /
          math.sqrt(20 + math.pow(lBarP - 50, 2));
  final sc = 1 + 0.045 * cBarP;
  final sh = 1 + 0.015 * cBarP * t;
  final rt = -math.sin(2 * dTheta * _rad) * rc;

  final termL = dLp / (kL * sl);
  final termC = dCp / (kC * sc);
  final termH = dHp / (kH * sh);

  return math.sqrt(
    termL * termL + termC * termC + termH * termH + rt * termC * termH,
  );
}

/// ΔE00 between two hex colours. Null if either is unparseable.
double? deltaE2000Hex(String? hexA, String? hexB) {
  final a = hexToLab(hexA);
  final b = hexToLab(hexB);
  if (a == null || b == null) return null;
  return deltaE2000(a, b);
}

/// How a ΔE00 figure should be described to a person.
///
/// Bands follow the common interpretation in which ΔE00 ≈ 1.0 is the just-
/// noticeable difference for a trained observer under controlled viewing.
/// Deliberately more forgiving than a print tolerance: foundation is judged on
/// skin at arm's length, not in a light booth.
String describeDeltaE(double dE) {
  if (dE < 1.5) return 'Practically indistinguishable';
  if (dE < 3) return 'Very close match';
  if (dE < 5) return 'Close match';
  if (dE < 8) return 'Noticeably different';
  return 'Clearly different';
}

// ─────────────────────────────────────────────────────────────────────────────
// Shade sorting for the try-on sheet
// ─────────────────────────────────────────────────────────────────────────────

/// A shade annotated with its perceptual distance from the user's skin.
class ShadeMatchScore {
  const ShadeMatchScore(this.shade, this.deltaE, this.isClosest);

  final Map<String, dynamic> shade;

  /// ΔE2000 from the user's measured skin tone. `double.infinity` when the
  /// shade's hex could not be parsed, which sorts it last without dropping it.
  final double deltaE;

  final bool isClosest;
}

/// Sorts shades by ΔE2000 from the user's skin tone, closest first.
///
/// Reads the hex from `shade_hex` or `hex`, whichever is present, because the
/// try-on sheet and the API name that field differently.
///
/// Returns the input order unchanged when [userSkinToneHex] is missing or
/// unparseable — an unsorted list is a much better failure than a list sorted by
/// a nonsense reference.
List<ShadeMatchScore> scoreShadesBySkinTone(
  List<Map<String, dynamic>> shades,
  String? userSkinToneHex,
) {
  final skin = hexToLab(userSkinToneHex);
  if (skin == null) {
    return shades.map((s) => ShadeMatchScore(s, double.infinity, false)).toList();
  }

  final scored = shades.map((shade) {
    final hex = (shade['shade_hex'] ?? shade['hex'])?.toString();
    final lab = hexToLab(hex);
    final dE = lab == null ? double.infinity : deltaE2000(skin, lab);
    return ShadeMatchScore(shade, dE, false);
  }).toList();

  scored.sort((a, b) => a.deltaE.compareTo(b.deltaE));

  if (scored.isNotEmpty && scored.first.deltaE.isFinite) {
    return [
      ShadeMatchScore(scored.first.shade, scored.first.deltaE, true),
      ...scored.skip(1),
    ];
  }
  return scored;
}
