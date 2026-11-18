import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app/app.dart';
import 'app/config/app_config.dart';
import 'app/utils/app_colors.dart';
import 'app/cache/looks_cache.dart';
import 'app/cache/products_cache.dart';
import 'app/cache/favourites_cache.dart';
import 'app/cache/makeup_bag_cache.dart';
import 'app/services/beauty_profile_service.dart';
import 'app/services/foundation_match_service.dart';
import 'app/screens/welcome_screen.dart';
import 'app/screens/home_screen.dart';

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Paint the branded startup frame while the existing initialization runs.
  runApp(const _SplashShine());
  FlutterNativeSplash.remove();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  await _waitForInitialSession();

  final session = Supabase.instance.client.auth.currentSession;

   if (session != null) {
    LooksCache.instance.prefetch(session.user.id);
    FavouritesCache.instance.prefetch(session.user.id);
    FavouritesCache.instance.listenRealtime(session.user.id);
    MakeupBagCache.instance.prefetch(session.user.id);
    MakeupBagCache.instance.listenRealtime(session.user.id); // 🆕 Add this
  }
  // The product catalog is public, so it warms up regardless of sign-in state.
  // Fire-and-forget: nothing on the critical path waits for it.
  ProductsCache.instance.prefetch();

  final initialScreen = session == null ? const WelcomeScreen() : const HomeScreen();

  Supabase.instance.client.auth.onAuthStateChange.listen((data) {
    if (data.event == AuthChangeEvent.signedOut) {
      LooksCache.instance.clear();
      FavouritesCache.instance.clear();
      MakeupBagCache.instance.clear();
      BeautyProfileService.clearCache();
      // The next person to sign in on this phone must not inherit the previous
      // user's measured skin tone — it would silently re-sort their foundation
      // list against somebody else's face.
      FoundationMatchService.clearCache();
    }
     // 🆕 Add this
  if (data.event == AuthChangeEvent.tokenRefreshed && data.session != null) {
    Supabase.instance.client.realtime.setAuth(data.session!.accessToken);
  }
  });
  

  await AppColors.initTheme();
  AppColors.themeNotifier.addListener(_syncSystemUiOverlay);

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  _syncSystemUiOverlay();


  runApp(MyApp(initialScreen: initialScreen));
}

void _syncSystemUiOverlay() {
  final dark = AppColors.isDark;
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
    ),
  );
}

Future<void> _waitForInitialSession() async {
  final completer = Completer<void>();

  final sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
    if (data.event == AuthChangeEvent.initialSession) {
      if (!completer.isCompleted) completer.complete();
    }
  });

  await completer.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () {},
  );

  await sub.cancel();
}

class MyApp extends StatelessWidget {
  final Widget initialScreen;
  const MyApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return AppRoot(initialScreen: initialScreen);
  }
}
class _SplashShine extends StatelessWidget {
  const _SplashShine();

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final ink = dark ? const Color(0xFFFFF8EB) : const Color(0xFF512441);
    final glint = dark ? Colors.white : const Color(0xFFA87895);
    return ColoredBox(
      color: dark ? const Color(0xFF1A0A0F) : const Color(0xFFFBF7F2),
      child: Center(
        child: SizedBox(
          width: 164,
          height: 155,
          child: Stack(alignment: Alignment.topCenter, children: [
            Image.asset(
              dark ? 'assets/images/splash_name_ivory.png' : 'assets/images/splash_name_plum.png',
              width: 164, height: 155, semanticLabel: 'AR Makeup Try-On',
            ),
            Image.asset(
          'assets/images/oval_face_ivory.png',
          height: 95,
          excludeFromSemantics: true,
          color: ink,
          frameBuilder: (context, child, frame, _) {
            if (frame == null || MediaQuery.disableAnimationsOf(context)) {
              return child;
            }
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: -0.3, end: 1.3),
              duration: const Duration(milliseconds: 520),
              builder: (_, x, mark) => ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => LinearGradient(
                  colors: [ink, glint, ink],
                ).createShader(Rect.fromLTWH(
                  r.width * (x - 0.25), 0, r.width * 0.5, r.height,
                )),
                child: mark,
              ),
              child: child,
            );
          },
            ),
          ]),
        ),
      ),
    );
  }
}
