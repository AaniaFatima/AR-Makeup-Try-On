/// Color utility functions for foundation shade matching by skin tone.
///
/// Provides utilities to:
/// - Convert hex color codes to RGB tuples
/// - Calculate Euclidean distance between colors
/// - Sort product shades by closest visual match to a user's skin tone

import 'dart:math' as math;

import '../cache/beauty_profile_model.dart';

/// Represents an RGB color value.
class RGB {
  final int r;
  final int g;
  final int b;

  RGB(this.r, this.g, this.b);

  @override
  String toString() => 'RGB($r, $g, $b)';
}

/// Converts a hex color string to an RGB tuple.
///
/// Accepts formats: "#RRGGBB", "0xRRGGBB", or "RRGGBB"
/// Returns RGB object with r, g, b values (0-255).
///
/// Example:
/// ```dart
/// final rgb = hexToRgb('#F5DEB3');
/// print(rgb); // RGB(245, 222, 179)
/// ```
RGB hexToRgb(String hex) {
  // Remove # or 0x prefix if present
  String cleanHex = hex.replaceAll('#', '').replaceAll('0x', '');

  // Pad with leading zero if only 3 characters (shorthand format)
  if (cleanHex.length == 3) {
    cleanHex = cleanHex.split('').map((c) => '$c$c').join();
  }

  // Ensure it's 6 characters
  if (cleanHex.length != 6) {
    throw FormatException('Invalid hex color: $hex');
  }

  // Parse hex string to integers
  final r = int.parse(cleanHex.substring(0, 2), radix: 16);
  final g = int.parse(cleanHex.substring(2, 4), radix: 16);
  final b = int.parse(cleanHex.substring(4, 6), radix: 16);

  return RGB(r, g, b);
}

/// Calculates Euclidean distance between two RGB colors.
///
/// Distance formula: sqrt((r1-r2)² + (g1-g2)² + (b1-b2)²)
/// Returns 0.0 for identical colors.
/// Maximum distance is ~441.7 (black to white).
///
/// Example:
/// ```dart
/// final color1 = RGB(255, 0, 0);
/// final color2 = RGB(0, 255, 0);
/// final distance = colorDistance(color1, color2);
/// print(distance); // ~360.6
/// ```
double colorDistance(RGB rgb1, RGB rgb2) {
  final dr = rgb1.r - rgb2.r;
  final dg = rgb1.g - rgb2.g;
  final db = rgb1.b - rgb2.b;

  return math.sqrt((dr * dr) + (dg * dg) + (db * db));
}

/// Represents a shade from the product database with a distance metric.
class ShadeWithDistance {
  final Map<String, dynamic> shade; // Original shade from DB
  final double distance; // Distance to user's skin tone

  ShadeWithDistance(this.shade, this.distance);
}

/// Sorts product shades by visual closeness to a user's skin tone hex.
///
/// Takes a list of product shades (maps with "name", "hex" keys) and sorts
/// them by Euclidean RGB distance to the user's skin_tone_hex.
///
/// Returns sorted list with closest shade first.
/// Handles invalid hex colors gracefully (treats as maximum distance).
///
/// Example:
/// ```dart
/// final shades = [
///   {'name': 'Fair', 'hex': '#F5DEB3'},
///   {'name': 'Medium', 'hex': '#D9A77B'},
///   {'name': 'Deep', 'hex': '#8B6F47'},
/// ];
/// final userHex = '#D0A080';
/// final sorted = sortShadesByClosest(shades, userHex);
/// print(sorted[0]['name']); // Likely 'Medium' (closest)
/// ```
List<Map<String, dynamic>> sortShadesByClosest(
  List<Map<String, dynamic>> shades,
  String userSkinToneHex,
) {
  try {
    // Parse user's skin tone hex
    final userRgb = hexToRgb(userSkinToneHex);

    // Calculate distance for each shade
    final shadesWithDistance = shades.map((shade) {
      try {
        final shadeHex = shade['hex']?.toString() ?? '';
        final shadeRgb = hexToRgb(shadeHex);
        final distance = colorDistance(userRgb, shadeRgb);
        return ShadeWithDistance(shade, distance);
      } catch (e) {
        // If a shade has invalid hex, assign maximum distance (won't match)
        return ShadeWithDistance(shade, 500.0); // Beyond max possible distance
      }
    }).toList();

    // Sort by distance (closest first)
    shadesWithDistance.sort((a, b) => a.distance.compareTo(b.distance));

    // Return original shade maps in sorted order
    return shadesWithDistance.map((sw) => sw.shade).toList();
  } catch (e) {
    // If user hex is invalid, return shades unchanged
    return shades;
  }
}

/// Annotates shades with distance information for debugging/display.
///
/// Useful for showing "💚 Your match" badge on closest shade.
/// Returns list of maps: [{...shade, distance: 45.3, isClosest: true}, ...]
List<Map<String, dynamic>> sortAndAnnotateShades(
  List<Map<String, dynamic>> shades,
  String userSkinToneHex,
) {
  try {
    final userRgb = hexToRgb(userSkinToneHex);

    // Calculate distances
    final shadesWithDistance = shades.map((shade) {
      try {
        final shadeHex = shade['hex']?.toString() ?? '';
        final shadeRgb = hexToRgb(shadeHex);
        final distance = colorDistance(userRgb, shadeRgb);
        return {...shade, 'distance': distance, 'isClosest': false};
      } catch (e) {
        return {...shade, 'distance': 500.0, 'isClosest': false};
      }
    }).toList();

    // Sort by distance
    shadesWithDistance.sort((a, b) =>
        (a['distance'] as double).compareTo(b['distance'] as double));

    // Mark closest shade
    if (shadesWithDistance.isNotEmpty) {
      shadesWithDistance[0]['isClosest'] = true;
    }

    return shadesWithDistance;
  } catch (e) {
    return shades;
  }
}

/// Gets the best matching depth level as a hex color when skin_tone_hex is unavailable.
///
/// Fallback utility: if user has depth_level (e.g., 'medium') but no skin_tone_hex,
/// this returns the representative hex for that depth from DepthSwatch.
/// Useful for try-on sorting when web analysis data incomplete.
String? depthLevelToHex(String? depthLevel) {
  if (depthLevel == null) return null;

  // Match against DepthSwatch predefined colors
  for (final swatch in DepthSwatch.all) {
    if (swatch.level == depthLevel) {
      return swatch.hex;
    }
  }

  return null;
}
