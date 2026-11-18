import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Ye package import karein

/// Lets screens that read [AppColors] repaint when the theme switch moves,
/// including a screen already sitting under Settings.
class AppThemeScope extends InheritedNotifier<ValueNotifier<ThemeMode>> {
  const AppThemeScope({
    super.key,
    required ValueNotifier<ThemeMode> notifier,
    required super.child,
  }) : super(notifier: notifier);
}

class AppColors {
  // Theme state ko globally manage karne ke liye Notifier
  static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

  /// Registers [context] with [AppThemeScope] so this build runs again when
  /// [themeNotifier] changes. Call it at the start of a screen's build.
  static void watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<AppThemeScope>();
  }

  // Helper method check karne ke liye ke dark mode on hai ya nahi
  static bool get isDark => themeNotifier.value == ThemeMode.dark;

  // 🔴 NAYA FUNCTION: Jo app start hote hi memory read karega
  static Future<void> initTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDarkMode = prefs.getBool('is_dark_mode') ?? false;
    themeNotifier.value = isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  // Main Brand Colors
  /// Light rose. White labels on it are 5.94:1. Dark keeps the previous rose.
  static const Color primaryLight = Color(0xFF9A4A64);
  static const Color primaryDark = Color(0xFFB75672);
  static Color get primary => isDark ? primaryDark : primaryLight;
  static const Color secondary = Color(0xFFF4C2C2);

  /// Light error is #B42318. Dark stays #D9534F, which is 4.73:1 as text on #121212.
  static const Color errorLight = Color(0xFFB42318);
  static const Color errorDark = Color(0xFFD9534F);
  static Color get error => isDark ? errorDark : errorLight;

  // Background aur Text colors
  static Color get background => isDark ? const Color(0xFF121212) : const Color(0xFFFAF7F5);
  static Color get surface => isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);
  static Color get textMain => isDark ? const Color(0xFFFFFFFF) : const Color(0xFF1F1F1F);
  static Color get textMuted => isDark ? const Color(0xFFA0A0A0) : const Color(0xFF645E5C);
  static Color get border => isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.05);

  // ── Accent ────────────────────────────────────────────────────────────────

  /// Selection accent — progress bars, selected chips, active borders.
  ///
  /// Tracks [primary] in light mode so a selected chip and a primary button read
  /// as the same brand rose. Lifted in dark mode because #C06C84 on a #121212
  /// background is too dim to register as "selected".
  static Color get accentPink =>
      isDark ? const Color(0xFFE38FA8) : primary;

  // ── Neutral ramp ──────────────────────────────────────────────────────────
  //
  // The number is *contrast against the current background*, not brightness:
  // 200 is a fill you can barely see, 700 is comfortable body text. That means
  // the ramp inverts under dark mode — 700 is near-black on the light theme and
  // near-white on the dark one. It looks wrong written down and is right on
  // screen, and it is why callers never have to branch on [isDark] themselves.

  /// Subtle fill — unselected chips, inset panels.
  static Color get neutral200 =>
      isDark ? const Color(0xFF262626) : const Color(0xFFEFEBE8);

  /// Hairline borders and dividers.
  static Color get neutral300 =>
      isDark ? const Color(0xFF383838) : const Color(0xFFDED8D4);

  /// Disabled and placeholder text. Deliberately mid-grey in both themes: a
  /// disabled control should be equally unavailable-looking either way.
  static Color get neutral500 =>
      isDark ? const Color(0xFF8A8A8A) : const Color(0xFF76706E);

  /// Secondary body text — softer than [textMain], still fully readable.
  static Color get neutral700 =>
      isDark ? const Color(0xFFD4D4D4) : const Color(0xFF4A4442);
}