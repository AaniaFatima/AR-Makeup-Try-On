// lib/app/services/foundation_match_service.dart
//
// Talks to `POST /api/foundation-match` on the companion website.
//
// The colour science lives on the server so there is exactly one authority for a
// recommendation: the app and the website must never suggest different shades for
// the same face. What the device contributes is the *sampling* — see
// `skin_sampler.dart` for why that half has to happen here.
//
// Everything in this file is defensive by construction. A user standing in front
// of the mirror with a half-done face is the worst possible moment to show a stack
// trace, so every failure path ends in a sentence they can act on.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../utils/skin_color.dart';
import 'skin_sampler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

/// One recommended shade, as ranked by the server.
class FoundationMatch {
  const FoundationMatch({
    required this.rank,
    required this.deltaE,
    required this.quality,
    required this.shadeHex,
    required this.shadeName,
    required this.shadeKey,
    required this.productKey,
    required this.productName,
    required this.brand,
    required this.price,
    required this.imageUrl,
    required this.finish,
    required this.coverage,
    required this.depthDirection,
    required this.deltaL,
    required this.reason,
    required this.alsoAvailableCount,
  });

  final int rank;

  /// ΔE2000 between the measured skin and this shade. Lower is closer.
  final double deltaE;

  /// Plain-English band for [deltaE], e.g. "Very close match".
  final String quality;

  final String shadeHex;
  final String shadeName;
  final String shadeKey;
  final String productKey;
  final String productName;
  final String? brand;
  final double? price;
  final String? imageUrl;
  final String? finish;
  final String? coverage;

  /// "lighter", "deeper" or "level" relative to the measured skin.
  final String depthDirection;

  /// Signed L* difference: positive means this shade is lighter than the skin.
  final double deltaL;

  /// One sentence explaining why this shade was ranked here.
  final String reason;

  /// How many other products sell this exact colour.
  final int alsoAvailableCount;

  factory FoundationMatch.fromJson(Map<String, dynamic> j) => FoundationMatch(
        rank: _asInt(j['rank']) ?? 0,
        deltaE: _asDouble(j['deltaE']) ?? 0,
        quality: j['quality']?.toString() ?? '',
        shadeHex: j['shadeHex']?.toString() ?? '#000000',
        shadeName: j['shadeName']?.toString() ?? 'Shade',
        shadeKey: j['shadeKey']?.toString() ?? '',
        productKey: j['productKey']?.toString() ?? '',
        productName: j['productName']?.toString() ?? '',
        brand: j['brand']?.toString(),
        price: _asDouble(j['price']),
        imageUrl: j['imageUrl']?.toString(),
        finish: j['finish']?.toString(),
        coverage: j['coverage']?.toString(),
        depthDirection: j['depthDirection']?.toString() ?? 'level',
        deltaL: _asDouble(j['deltaL']) ?? 0,
        reason: j['reason']?.toString() ?? '',
        alsoAvailableCount:
            (j['alsoAvailableFrom'] is List) ? (j['alsoAvailableFrom'] as List).length : 0,
      );

  /// The shade's colour, ready for a `Color(...)`. Falls back to mid-grey rather
  /// than throwing if the catalog hex is malformed.
  int get packedColour => parseHexColor(shadeHex) ?? 0x808080;
}

/// The measured skin colour and everything derived from it.
class SkinReading {
  const SkinReading({
    required this.hex,
    required this.l,
    required this.a,
    required this.b,
    required this.ita,
    required this.depthLevel,
    required this.undertone,
    required this.monkScale,
    required this.regionsUsed,
  });

  final String hex;
  final double l;
  final double a;
  final double b;

  /// Individual Typology Angle. Positive is lighter, negative deeper.
  final double ita;

  /// One of fair / light / medium / tan / deep / rich.
  final String depthLevel;

  /// One of cool / neutral / warm / olive.
  final String undertone;

  /// Monk Skin Tone Scale position, 1–10.
  final int monkScale;

  /// Which face regions contributed after outlier rejection.
  final List<String> regionsUsed;

  factory SkinReading.fromJson(Map<String, dynamic> j) {
    final lab = j['lab'] as Map<String, dynamic>? ?? const {};
    return SkinReading(
      hex: j['hex']?.toString() ?? '#000000',
      l: _asDouble(lab['L']) ?? 0,
      a: _asDouble(lab['a']) ?? 0,
      b: _asDouble(lab['b']) ?? 0,
      ita: _asDouble(j['ita']) ?? 0,
      depthLevel: j['depthLevel']?.toString() ?? '',
      undertone: j['undertone']?.toString() ?? '',
      monkScale: _asInt(j['monkScale']) ?? 0,
      regionsUsed: (j['regionsUsed'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }

  int get packedColour => parseHexColor(hex) ?? 0x808080;

  Lab get lab => Lab(l, a, b);
}

/// The whole server response.
class FoundationMatchResult {
  const FoundationMatchResult({
    required this.needsRetake,
    required this.retakeReason,
    required this.retakeHint,
    required this.warnings,
    required this.confidence,
    required this.confidenceLabel,
    required this.skin,
    required this.matches,
    required this.lighterAlternate,
    required this.deeperAlternate,
    required this.savedToProfile,
    required this.persistenceNotes,
    required this.catalogNotes,
    this.referenceHex,
    this.expectedError,
    this.calibration = 'Approximate',
    this.shadeRange = const [],
  });

  /// True when the photo could not be measured and the user must try again.
  final bool needsRetake;
  final String? retakeReason;
  final String? retakeHint;

  /// Non-fatal observations, e.g. that a warm room was corrected for.
  final List<String> warnings;

  /// 0–1.
  final double confidence;

  /// "high" / "moderate" / "low".
  final String confidenceLabel;

  final SkinReading? skin;
  final List<FoundationMatch> matches;

  /// A deliberately lighter and a deliberately deeper option, so the user can
  /// adjust when the closest shade is not what they wanted.
  final FoundationMatch? lighterAlternate;
  final FoundationMatch? deeperAlternate;

  final bool savedToProfile;

  /// Anything that failed to save. Shown rather than swallowed.
  final List<String> persistenceNotes;

  /// What the catalog can and cannot discriminate — honest about its limits.
  final List<String> catalogNotes;

  /// Catalog colour the shades were ranked against. Null on an older server.
  final String? referenceHex;

  /// Region spread, in ΔE. Not a clinical accuracy figure.
  final double? expectedError;

  /// "Calibrated" when a white sheet was used, otherwise "Approximate".
  final String calibration;

  /// Nearby shades. Shown in place of a single winner when confidence is low.
  final List<FoundationMatch> shadeRange;

  FoundationMatch? get best => matches.isEmpty ? null : matches.first;

  factory FoundationMatchResult.fromJson(Map<String, dynamic> j) {
    final quality = j['quality'] as Map<String, dynamic>? ?? const {};
    final confidence = j['confidence'] as Map<String, dynamic>? ?? const {};
    final diagnostics = j['diagnostics'] as Map<String, dynamic>? ?? const {};
    final skinJson = j['skin'];

    FoundationMatch? one(dynamic v) =>
        v is Map<String, dynamic> ? FoundationMatch.fromJson(v) : null;

    return FoundationMatchResult(
      needsRetake: quality['ok'] != true,
      retakeReason: quality['retakeReason']?.toString(),
      retakeHint: quality['retakeHint']?.toString(),
      warnings:
          (quality['warnings'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      confidence: _asDouble(confidence['score']) ?? 0,
      confidenceLabel: confidence['label']?.toString() ?? 'low',
      skin: skinJson is Map<String, dynamic> ? SkinReading.fromJson(skinJson) : null,
      matches: (j['matches'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(FoundationMatch.fromJson)
              .toList() ??
          const [],
      lighterAlternate: one(j['lighterAlternate']),
      deeperAlternate: one(j['deeperAlternate']),
      savedToProfile: j['savedToProfile'] == true,
      persistenceNotes:
          (j['persistenceNotes'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
      catalogNotes:
          (j['notes'] as List?)?.map((e) => e.toString()).toList() ??
              (diagnostics['notes'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
      referenceHex: j['referenceHex']?.toString(),
      expectedError: _asDouble(j['expectedError']),
      calibration: j['calibration']?.toString() ?? 'Approximate',
      shadeRange: (j['shadeRange'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(FoundationMatch.fromJson)
              .toList() ??
          const [],
    );
  }
}

/// A failure the user can act on, as opposed to a bug.
class FoundationMatchException implements Exception {
  const FoundationMatchException(this.message, {this.hint, this.needsSignIn = false});

  final String message;
  final String? hint;

  /// The API refused the call because there is no usable session.
  final bool needsSignIn;

  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class FoundationMatchService {
  const FoundationMatchService._();

  static SupabaseClient get _supabase => Supabase.instance.client;

  static String get _endpoint => '${AppConfig.webBaseUrl}${AppConfig.foundationMatchPath}';

  /// Generous, because this is a one-shot request the user is actively waiting on
  /// and a cold serverless function on a slow connection can take a while. Short
  /// enough that a dead tunnel does not look like a hang.
  static const Duration _timeout = Duration(seconds: 25);

  /// Last request body, debug builds only. No photo — patches and illuminant.
  static String? debugRequestJson;

  static Map<String, String> _headers() {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw const FoundationMatchException(
        'Please sign in to save your shade match.',
        needsSignIn: true,
      );
    }
    return {
      'Content-Type': 'application/json',
      // The website authenticates with SSR cookies; the app has no cookies, so it
      // presents its Supabase access token instead. The route resolves both.
      'Authorization': 'Bearer ${session.accessToken}',
    };
  }

  // ── The main call ──────────────────────────────────────────────────────────

  /// Samples [imagePath] on device and asks the server to rank the catalog.
  ///
  /// Throws [FoundationMatchException] when the request itself could not be made.
  /// A photo that was readable but unusable comes back as a normal result with
  /// [FoundationMatchResult.needsRetake] set — that is a measurement outcome, not
  /// an error, and the difference matters to how it is presented.
  static Future<FoundationMatchResult> matchFromPhoto(
    String imagePath, {
    String? finishPreference,
    int limit = 5,
    bool seekWhiteReference = false,
  }) async {
    final SkinSampleResult sampled;
    try {
      sampled = await SkinSampler.sample(
        imagePath,
        seekWhiteReference: seekWhiteReference,
      );
    } on SkinSampleException catch (e) {
      throw FoundationMatchException(e.message, hint: e.hint);
    }
    return matchSample(
      sampled,
      finishPreference: finishPreference,
      limit: limit,
    );
  }

  /// Median of several captured frames, then the same request as [matchFromPhoto].
  static Future<FoundationMatchResult> matchFromFrames(
    List<String> imagePaths, {
    String? finishPreference,
    int limit = 5,
    bool seekWhiteReference = false,
    Map<String, int>? whiteReference,
  }) async {
    final SkinSampleResult sampled;
    try {
      sampled = await SkinSampler.sampleFrames(
        imagePaths,
        seekWhiteReference: seekWhiteReference,
      );
    } on SkinSampleException catch (e) {
      throw FoundationMatchException(e.message, hint: e.hint);
    }
    return matchSample(
      sampled,
      finishPreference: finishPreference,
      limit: limit,
      whiteReference: whiteReference,
    );
  }

  /// Posts an already-sampled reading. [whiteReference] overrides a detected sheet.
  static Future<FoundationMatchResult> matchSample(
    SkinSampleResult sampled, {
    String? finishPreference,
    int limit = 5,
    Map<String, int>? whiteReference,
  }) async {
    if (sampled.patches.length < 3) {
      throw const FoundationMatchException(
        'Not enough of your skin could be measured in that photo.',
        hint: 'Move hair off your face, and avoid strong shadows on one side.',
      );
    }

    final paper = whiteReference ?? sampled.whiteReference;
    final body = <String, dynamic>{
      'patches': sampled.patches.map((p) => p.toJson()).toList(),
      'illuminant': ?sampled.illuminant,
      'whiteReference': ?paper,
      'finishPreference': ?finishPreference,
      'limit': limit,
    };
    if (kDebugMode) {
      debugRequestJson = const JsonEncoder.withIndent('  ').convert(body);
    }

    final result = await _post(body);
    await _cache(result);
    return result;
  }

  /// Re-ranks against an already known skin hex, without a photo.
  ///
  /// Used when the user's Beauty Profile already holds a measured tone and they
  /// only want to see matches again — no camera, no sampling. Confidence comes
  /// back capped and labelled, because a stored hex carries no evidence that the
  /// light was neutral when it was taken.
  static Future<FoundationMatchResult> matchFromSkinHex(
    String skinHex, {
    String? finishPreference,
    int limit = 5,
  }) async {
    final result = await _post({
      'skinHex': skinHex,
      'finishPreference': ?finishPreference,
      'limit': limit,
      // Do not overwrite a photo-derived reading with a re-run of itself.
      'save': false,
    });
    return result;
  }

  /// One automatic retry, and only for HTTP 503.
  @visibleForTesting
  static const Duration serviceUnavailableRetryDelay = Duration(seconds: 2);

  @visibleForTesting
  static bool retriesServiceUnavailable(int statusCode) => statusCode == 503;

  /// Maps a matcher status onto a user-facing error.
  ///
  /// Returns null for HTTP 200. 401 keeps the sign-in message. 429 is a
  /// friendly wait, not the server's rate-limit body.
  @visibleForTesting
  static FoundationMatchException? exceptionForHttpStatus(
    int statusCode,
    String body,
  ) {
    if (statusCode == 200) return null;
    if (statusCode == 401) {
      return const FoundationMatchException(
        'Please sign in to save your shade match.',
        needsSignIn: true,
      );
    }
    if (statusCode == 429) {
      return const FoundationMatchException(
        'Please wait a moment and try again.',
      );
    }

    String? serverMessage;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        serverMessage = decoded['error'] as String;
      }
    } catch (_) {
      // Not JSON — an HTML error page from a proxy, most likely.
    }
    return FoundationMatchException(
      serverMessage ?? "The shade matcher couldn't complete that request.",
      hint: serverMessage == null ? 'Please try again in a moment.' : null,
    );
  }

  static Future<http.Response> _send(Map<String, dynamic> body) {
    return http
        .post(Uri.parse(_endpoint), headers: _headers(), body: jsonEncode(body))
        .timeout(_timeout);
  }

  static Future<FoundationMatchResult> _post(Map<String, dynamic> body) async {
    http.Response response;
    try {
      response = await _send(body);
      if (retriesServiceUnavailable(response.statusCode)) {
        await Future.delayed(serviceUnavailableRetryDelay);
        response = await _send(body);
      }
    } on FoundationMatchException {
      rethrow;
    } catch (e) {
      debugPrint('[FoundationMatchService] network error: $e');
      throw const FoundationMatchException(
        "Couldn't reach the shade matcher.",
        hint: 'Check your connection and try again.',
      );
    }

    final failure = exceptionForHttpStatus(response.statusCode, response.body);
    if (failure != null) {
      if (response.statusCode != 401 && response.statusCode != 429) {
        debugPrint(
          '[FoundationMatchService] HTTP ${response.statusCode}: '
          '${response.body.length > 300 ? response.body.substring(0, 300) : response.body}',
        );
      }
      throw failure;
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      return FoundationMatchResult.fromJson(decoded);
    } catch (e) {
      debugPrint('[FoundationMatchService] malformed response: $e');
      throw const FoundationMatchException(
        "The shade matcher sent something this version can't read.",
        hint: 'Update the app, or try again later.',
      );
    }
  }

  // ── Last result, cached locally ────────────────────────────────────────────
  //
  // Kept so the try-on sheet can sort by skin tone and the result screen can be
  // reopened with no network and no second photo. Only the derived values are
  // stored — never the patches, never an image.

  static const String _prefsHex = 'foundation_match_skin_hex';
  static const String _prefsUndertone = 'foundation_match_undertone';
  static const String _prefsDepth = 'foundation_match_depth';
  static const String _prefsMonk = 'foundation_match_monk';
  static const String _prefsShadeName = 'foundation_match_shade_name';
  static const String _prefsShadeHex = 'foundation_match_shade_hex';
  static const String _prefsProductKey = 'foundation_match_product_key';
  static const String _prefsShadeKey = 'foundation_match_shade_key';
  static const String _prefsDeltaE = 'foundation_match_delta_e';
  static const String _prefsAt = 'foundation_match_at';
  static const String _prefsReference = 'foundation_match_reference_hex';

  /// A rejected photo must not replace a saved mapped colour with raw skin.
  static bool _canSaveTryOn(FoundationMatchResult result) {
    if (result.needsRetake || result.skin == null) return false;
    final spread = result.expectedError;
    if (spread != null && spread > 5) return false;
    final reference = result.referenceHex;
    final hasReference = reference != null && reference.isNotEmpty;
    return hasReference || result.best != null;
  }

  static Future<void> _cache(FoundationMatchResult result) async {
    if (!_canSaveTryOn(result)) return;
    final skin = result.skin;
    if (skin == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsHex, skin.hex);
      await prefs.setString(_prefsUndertone, skin.undertone);
      await prefs.setString(_prefsDepth, skin.depthLevel);
      await prefs.setInt(_prefsMonk, skin.monkScale);
      await prefs.setString(_prefsAt, DateTime.now().toIso8601String());

      final reference = result.referenceHex;
      final best = result.best;
      final tryOnHex = (reference != null && reference.isNotEmpty) ? reference : best?.shadeHex;
      if (tryOnHex != null && tryOnHex.isNotEmpty) {
        await prefs.setString(_prefsReference, tryOnHex);
      }
      if (best != null) {
        await prefs.setString(_prefsShadeName, '${best.productName} · ${best.shadeName}');
        await prefs.setString(_prefsShadeHex, best.shadeHex);
        await prefs.setString(_prefsProductKey, best.productKey);
        await prefs.setString(_prefsShadeKey, best.shadeKey);
        await prefs.setDouble(_prefsDeltaE, best.deltaE);
      }
    } catch (e) {
      // A cache write failing must never take the result screen down with it.
      debugPrint('[FoundationMatchService] cache write failed: $e');
    }
  }

  /// The measured skin hex from the last run, or null if there has not been one.
  ///
  /// This is what the try-on sheet sorts by, so it has to work with no network.
  static Future<String?> cachedSkinHex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefsHex);
    } catch (_) {
      return null;
    }
  }

  /// Hex the try-on sheet should sort by: the mapped catalog colour when the
  /// server sent one, otherwise the measured skin hex from an older server.
  static Future<String?> cachedTryOnHex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final reference = prefs.getString(_prefsReference);
      if (reference != null && reference.isNotEmpty) return reference;
      return prefs.getString(_prefsHex);
    } catch (_) {
      return null;
    }
  }

  /// Stores a too-light / right / too-dark vote. Returns the server's note.
  /// A missing table comes back as a sentence, not an exception.
  static Future<String> submitFeedback(String vote) async {
    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(_endpoint),
            headers: _headers(),
            body: jsonEncode({'action': 'feedback', 'vote': vote}),
          )
          .timeout(_timeout);
    } on FoundationMatchException {
      rethrow;
    } catch (e) {
      debugPrint('[FoundationMatchService] feedback network error: $e');
      throw const FoundationMatchException(
        "Couldn't save that vote.",
        hint: 'Check your connection and try again.',
      );
    }
    if (response.statusCode == 401) {
      throw const FoundationMatchException(
        'Please sign in to save your shade match.',
        needsSignIn: true,
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['note'] is String) {
        return decoded['note'] as String;
      }
    } catch (_) {}
    if (response.statusCode == 200) {
      return 'Thanks — that vote is saved for a later review.';
    }
    throw const FoundationMatchException(
      "Couldn't save that vote.",
      hint: 'Please try again in a moment.',
    );
  }

  /// A one-line summary of the last match, for a profile tile.
  static Future<CachedFoundationMatch?> cachedSummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hex = prefs.getString(_prefsHex);
      if (hex == null) return null;
      return CachedFoundationMatch(
        skinHex: hex,
        undertone: prefs.getString(_prefsUndertone),
        depthLevel: prefs.getString(_prefsDepth),
        monkScale: prefs.getInt(_prefsMonk),
        shadeLabel: prefs.getString(_prefsShadeName),
        shadeHex: prefs.getString(_prefsShadeHex),
        productKey: prefs.getString(_prefsProductKey),
        shadeKey: prefs.getString(_prefsShadeKey),
        deltaE: prefs.getDouble(_prefsDeltaE),
        measuredAt: DateTime.tryParse(prefs.getString(_prefsAt) ?? ''),
      );
    } catch (e) {
      debugPrint('[FoundationMatchService] cache read failed: $e');
      return null;
    }
  }

  /// Clears the cached match. Called on sign-out: the next user must not inherit
  /// the previous one's skin tone.
  static Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const [
        _prefsHex,
        _prefsUndertone,
        _prefsDepth,
        _prefsMonk,
        _prefsShadeName,
        _prefsShadeHex,
        _prefsProductKey,
        _prefsShadeKey,
        _prefsDeltaE,
        _prefsAt,
        _prefsReference,
      ]) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('[FoundationMatchService] cache clear failed: $e');
    }
  }
}

/// The locally cached summary of the last foundation match.
class CachedFoundationMatch {
  const CachedFoundationMatch({
    required this.skinHex,
    required this.undertone,
    required this.depthLevel,
    required this.monkScale,
    required this.shadeLabel,
    required this.shadeHex,
    required this.productKey,
    required this.shadeKey,
    required this.deltaE,
    required this.measuredAt,
  });

  final String skinHex;
  final String? undertone;
  final String? depthLevel;
  final int? monkScale;
  final String? shadeLabel;
  final String? shadeHex;
  final String? productKey;
  final String? shadeKey;
  final double? deltaE;
  final DateTime? measuredAt;

  int get packedSkinColour => parseHexColor(skinHex) ?? 0x808080;
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON coercion
// ─────────────────────────────────────────────────────────────────────────────
//
// Postgres numerics arrive as either int or double depending on whether they have
// a fractional part, and `as double` on an int throws. These two functions are the
// reason this parser cannot be brought down by a whole-number price.

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}
