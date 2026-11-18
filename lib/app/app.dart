import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import './utils/app_colors.dart';
import './screens/welcome_screen.dart';



class AppRoot extends StatefulWidget {
  final Widget initialScreen; // 🟢 naya
  const AppRoot({super.key, required this.initialScreen});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late Widget _homeScreen; // 🟢 late — null kabhi nahi hoga

  @override
  void initState() {
    super.initState();
    _homeScreen = widget.initialScreen; // 🟢 turant set, no async needed

    // Sign-out returns to welcome. A Google sign-in return is handled by
    // AuthScreen's listener, not here.
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;
      if (data.event == AuthChangeEvent.signedOut) {
        setState(() => _homeScreen = const WelcomeScreen());
      }
    });
  }

  // 🟢 _resolveHomeScreen() method bilkul hata do — ab zaroorat nahi

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppColors.themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'AR Makeup Try-On',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _materialTheme(Brightness.light),
          darkTheme: _materialTheme(Brightness.dark),
          builder: (context, child) {
            return AppThemeScope(
              notifier: AppColors.themeNotifier,
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: _homeScreen,
        );
      },
    );
  }

  // 🟢 _buildSplash() bhi hata sakte ho — ab use nahi hoga
}

/// Material widgets follow the same light/dark switch as [AppColors].
/// Screens that paint with [AppColors] keep their own surfaces.
ThemeData _materialTheme(Brightness brightness) {
  // Seed stays the previous rose so fromSeed roles other than primary do not shift.
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primaryDark,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: brightness == Brightness.light
        ? scheme.copyWith(
            primary: AppColors.primaryLight,
            onPrimary: Colors.white,
          )
        : scheme,
  );
}