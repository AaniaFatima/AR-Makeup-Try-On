// lib/app/cache/beauty_profile_model.dart
//
// User Beauty Profile model and related classes for undertone questionnaire.
//
// This model syncs with the backend `user_skin_profiles` table and stores
// user's personal beauty preferences: undertone, depth level, concerns, etc.

// ── MODELS ────────────────────────────────────────────────────────────────────

/// Abbreviated month names, indexed 1-12 with a padding entry at 0.
///
/// Hand-rolled rather than pulled from `intl`'s DateFormat: the only formatting
/// this file needs is "9 Mar", and `intl` is not a dependency of this project.
/// Adding one to render three characters is not worth the version-resolution risk
/// against the pinned deepar_flutter override.
const List<String> _kShortMonths = [
  '',
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// User's complete beauty profile.
/// Maps to `user_skin_profiles` table on the backend.
class UserBeautyProfile {
  final String? skinType; // 'Oily' | 'Dry' | 'Combination' | 'Normal' | 'Sensitive'
  final String? undertone; // 'cool' | 'warm' | 'neutral' | 'olive'
  final String? depthLevel; // 'fair' | 'light' | 'medium' | 'tan' | 'deep' | 'rich'
  final String? skinToneHex; // e.g. '#E8C3A8'
  final int? monkScale; // 1-10, Monk Skin Tone Scale
  final String? coveragePreference; // 'sheer' | 'medium' | 'full'
  final String? finishPreference; // 'matte' | 'dewy' | 'satin'
  final List<String>? allergies; // e.g. ['parabens', 'silicones']
  final List<String>? concerns; // e.g. ['acne', 'dryness', 'sensitivity']
  final String? source; // 'manual' | 'analysis' | 'both'
  final DateTime? updatedAt;

  UserBeautyProfile({
    this.skinType,
    this.undertone,
    this.depthLevel,
    this.skinToneHex,
    this.monkScale,
    this.coveragePreference,
    this.finishPreference,
    this.allergies,
    this.concerns,
    this.source,
    this.updatedAt,
  });

  /// Whether the profile has meaningful data (not empty/null).
  bool get isEmpty =>
      skinType == null &&
      undertone == null &&
      depthLevel == null &&
      skinToneHex == null &&
      monkScale == null &&
      coveragePreference == null &&
      finishPreference == null &&
      (allergies == null || allergies!.isEmpty) &&
      (concerns == null || concerns!.isEmpty);

  /// Human-readable time since last update, e.g. "15 minutes ago", "3 days ago"
  String? get updatedAgoText {
    if (updatedAt == null) return null;

    final now = DateTime.now();
    final diff = now.difference(updatedAt!);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';

    // For older dates, show formatted date
    return '${updatedAt!.day} ${_kShortMonths[updatedAt!.month]}';
  }

  /// Create from JSON response from `/api/beauty-profile`
  factory UserBeautyProfile.fromJson(Map<String, dynamic> json) => UserBeautyProfile(
    skinType: json['skin_type'] as String?,
    undertone: json['undertone'] as String?,
    depthLevel: json['depth_level'] as String?,
    skinToneHex: json['skin_tone_hex'] as String?,
    monkScale: json['monk_scale'] as int?,
    coveragePreference: json['coverage_preference'] as String?,
    finishPreference: json['finish_preference'] as String?,
    allergies: List<String>.from(json['allergies'] as List? ?? []),
    concerns: List<String>.from(json['concerns'] as List? ?? []),
    source: json['source'] as String? ?? 'manual',
    updatedAt: json['updated_at'] != null
        ? DateTime.parse(json['updated_at'] as String)
        : null,
  );

  /// Convert to JSON for sending to backend
  Map<String, dynamic> toJson() => {
    if (skinType != null) 'skin_type': skinType,
    if (undertone != null) 'undertone': undertone,
    if (depthLevel != null) 'depth_level': depthLevel,
    if (skinToneHex != null) 'skin_tone_hex': skinToneHex,
    if (monkScale != null) 'monk_scale': monkScale,
    if (coveragePreference != null) 'coverage_preference': coveragePreference,
    if (finishPreference != null) 'finish_preference': finishPreference,
    if (allergies != null && allergies!.isNotEmpty) 'allergies': allergies,
    if (concerns != null && concerns!.isNotEmpty) 'concerns': concerns,
    'source': source ?? 'manual',
  };

  /// Copy with modified fields
  UserBeautyProfile copyWith({
    String? skinType,
    String? undertone,
    String? depthLevel,
    String? skinToneHex,
    int? monkScale,
    String? coveragePreference,
    String? finishPreference,
    List<String>? allergies,
    List<String>? concerns,
    String? source,
    DateTime? updatedAt,
  }) =>
      UserBeautyProfile(
        skinType: skinType ?? this.skinType,
        undertone: undertone ?? this.undertone,
        depthLevel: depthLevel ?? this.depthLevel,
        skinToneHex: skinToneHex ?? this.skinToneHex,
        monkScale: monkScale ?? this.monkScale,
        coveragePreference: coveragePreference ?? this.coveragePreference,
        finishPreference: finishPreference ?? this.finishPreference,
        allergies: allergies ?? this.allergies,
        concerns: concerns ?? this.concerns,
        source: source ?? this.source,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

// ── UNDERTONE QUESTIONNAIRE ───────────────────────────────────────────────────

/// Result of the 3-question undertone heuristic questionnaire
/// Questions:
/// 1. Vein color (blue/purple = cool, green = warm)
/// 2. Jewelry preference (silver = cool, gold = warm)
/// 3. Sun reaction (burns only = cool, tans easily = warm)
class UndertoneQuizResult {
  final String? veinColor; // 'blue_purple' | 'green' | 'unsure'
  final String? jewelryPreference; // 'silver' | 'gold' | 'no_preference'
  final String? sunReaction; // 'burns' | 'tans' | 'mixed'
  final bool isSelfIdentifiedOlive;

  UndertoneQuizResult({
    this.veinColor,
    this.jewelryPreference,
    this.sunReaction,
    this.isSelfIdentifiedOlive = false,
  });

  /// Calculate undertone based on heuristic scoring.
  /// Uses published undertone analysis methodology (vein color + jewelry + sun reaction).
  ///
  /// Scoring:
  /// - Vein blue/purple: +2 cool
  /// - Vein green: +2 warm
  /// - Silver jewelry: +1 cool
  /// - Gold jewelry: +1 warm
  /// - Burns only: +1 cool
  /// - Tans easily: +1 warm
  ///
  /// Final: cool score > warm → "cool"
  ///        warm score > cool → "warm"
  ///        equal scores → "neutral"
  String calculateUndertone() {
    if (isSelfIdentifiedOlive) {
      return 'olive';
    }

    int coolScore = 0;
    int warmScore = 0;

    // Vein color scoring
    if (veinColor == 'blue_purple') {
      coolScore += 2;
    } else if (veinColor == 'green') {
      warmScore += 2;
    }

    // Jewelry preference scoring
    if (jewelryPreference == 'silver') {
      coolScore += 1;
    } else if (jewelryPreference == 'gold') {
      warmScore += 1;
    }

    // Sun reaction scoring
    if (sunReaction == 'burns') {
      coolScore += 1; // Fair skin that burns typically has cool undertones
    } else if (sunReaction == 'tans') {
      warmScore += 1;
    }

    // Determine final undertone
    if (coolScore > warmScore) {
      return 'cool';
    } else if (warmScore > coolScore) {
      return 'warm';
    } else {
      return 'neutral';
    }
  }
}

// ── DEPTH SWATCH DATA ─────────────────────────────────────────────────────────

/// Preefined depth level options with visual and color information
class DepthSwatch {
  final String level; // 'fair' | 'light' | 'medium' | 'tan' | 'deep' | 'rich'
  final String hex; // Representative hex color
  final String label; // Display name
  final String description; // Example tones

  const DepthSwatch({
    required this.level,
    required this.hex,
    required this.label,
    required this.description,
  });

  static final List<DepthSwatch> all = [
    DepthSwatch(
      level: 'fair',
      hex: '#F5DEB3',
      label: 'Fair',
      description: 'Porcelain, ivory',
    ),
    DepthSwatch(
      level: 'light',
      hex: '#E8C3A8',
      label: 'Light',
      description: 'Pale golden, beige',
    ),
    DepthSwatch(
      level: 'medium',
      hex: '#D9A77B',
      label: 'Medium',
      description: 'Honey, warm tan',
    ),
    DepthSwatch(
      level: 'tan',
      hex: '#C89968',
      label: 'Tan',
      description: 'Deeper tan, caramel',
    ),
    DepthSwatch(
      level: 'deep',
      hex: '#8B6F47',
      label: 'Deep',
      description: 'Rich brown',
    ),
    DepthSwatch(
      level: 'rich',
      hex: '#664C42',
      label: 'Rich',
      description: 'Very deep brown',
    ),
  ];

  static DepthSwatch? fromLevel(String level) {
    try {
      return all.firstWhere((s) => s.level == level);
    } catch (e) {
      return null;
    }
  }
}

// ── SKIN CONCERN TAGS ─────────────────────────────────────────────────────────

/// Predefined skin concerns that users can select
class SkinConcern {
  final String id; // Internal ID
  final String label; // Display name
  final String icon; // Emoji or icon
  final String description; // Helpful tooltip

  const SkinConcern({
    required this.id,
    required this.label,
    required this.icon,
    required this.description,
  });

  static final List<SkinConcern> all = [
    SkinConcern(
      id: 'acne',
      label: 'Acne-Prone',
      icon: '🔴',
      description: 'Breakouts, blemishes, oily skin',
    ),
    SkinConcern(
      id: 'dryness',
      label: 'Dryness',
      icon: '🏜️',
      description: 'Dry, flaky, tight skin',
    ),
    SkinConcern(
      id: 'sensitivity',
      label: 'Sensitivity',
      icon: '🌡️',
      description: 'Easily irritated, reactive',
    ),
    SkinConcern(
      id: 'aging',
      label: 'Fine Lines & Wrinkles',
      icon: '✨',
      description: 'Anti-aging, firmness',
    ),
    SkinConcern(
      id: 'dark_spots',
      label: 'Dark Spots',
      icon: '🌙',
      description: 'Hyperpigmentation, uneven tone',
    ),
    SkinConcern(
      id: 'redness',
      label: 'Redness',
      icon: '🔥',
      description: 'Rosacea, irritation, soothing',
    ),
    SkinConcern(
      id: 'oiliness',
      label: 'Oily Skin',
      icon: '💧',
      description: 'Excess sebum, shine',
    ),
  ];

  static SkinConcern? fromId(String id) {
    try {
      return all.firstWhere((c) => c.id == id);
    } catch (e) {
      return null;
    }
  }
}

// ── SKIN TYPE ─────────────────────────────────────────────────────────────────

/// Predefined skin types for questionnaire
class SkinType {
  final String id;
  final String label;
  final String description;

  const SkinType({
    required this.id,
    required this.label,
    required this.description,
  });

  static final List<SkinType> all = [
    SkinType(
      id: 'Oily',
      label: 'Oily',
      description: 'Shiny, prone to breakouts',
    ),
    SkinType(
      id: 'Dry',
      label: 'Dry',
      description: 'Tight, flaky, itchy',
    ),
    SkinType(
      id: 'Combination',
      label: 'Combination',
      description: 'Oily T-zone, dry elsewhere',
    ),
    SkinType(
      id: 'Normal',
      label: 'Normal',
      description: 'Balanced, minimal concerns',
    ),
    SkinType(
      id: 'Sensitive',
      label: 'Sensitive',
      description: 'Easily irritated, reactive',
    ),
  ];

  static SkinType? fromId(String id) {
    try {
      return all.firstWhere((t) => t.id == id);
    } catch (e) {
      return null;
    }
  }
}
