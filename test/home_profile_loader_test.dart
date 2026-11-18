import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/screens/camera_permission_screen.dart';
import 'package:makeup_tryon/app/screens/home_screen.dart';
import 'package:makeup_tryon/app/screens/profile_screen.dart';
import 'package:makeup_tryon/app/screens/try_on_screen.dart';
import 'package:makeup_tryon/app/screens/welcome_screen.dart';
import 'package:makeup_tryon/app/utils/app_colors.dart';
import 'package:makeup_tryon/app/widgets/app_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppColors.themeNotifier.value = ThemeMode.light;
  });

  group('Maybe later', () {
    testWidgets('opens Home for a signed-in user and does not leave permission underneath',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraPermissionScreen(isSignedIn: _signedIn),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Maybe later'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(CameraPermissionScreen), findsNothing);
      expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
    });

    testWidgets('opens Welcome when nobody is signed in', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraPermissionScreen(isSignedIn: _signedOut),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Maybe later'));
      // Welcome keeps a repeating animation, so this cannot pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(CameraPermissionScreen), findsNothing);
    });

    testWidgets('pops back when the permission screen was pushed', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const CameraPermissionScreen(isSignedIn: _signedIn),
                    ),
                  );
                },
                child: const Text('Ask'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maybe later'));
      await tester.pumpAndSettle();

      expect(find.text('Ask'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(CameraPermissionScreen), findsNothing);
    });
  });

  group('Try on from Home', () {
    testWidgets('returns to the screen underneath when the camera is already allowed',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HomeScreen(
                        overCamera: true,
                        signedInOverride: true,
                        greetingNameOverride: 'Amina',
                        looksOverride: <Map<String, dynamic>>[],
                        cameraGrantedOverride: true,
                      ),
                    ),
                  );
                },
                child: const Text('Under the camera'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Under the camera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      expect(find.text('Under the camera'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(TryOnScreen), findsNothing);
    });

    testWidgets('opens the permission screen when the camera is denied', (tester) async {
      await _pumpThemed(
        tester,
        home: const HomeScreen(
          signedInOverride: true,
          greetingNameOverride: 'Amina',
          looksOverride: <Map<String, dynamic>>[],
          cameraGrantedOverride: false,
        ),
      );

      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      expect(find.byType(CameraPermissionScreen), findsOneWidget);
      expect(find.byType(TryOnScreen), findsNothing);
    });
  });

  group('narrow layout', () {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      testWidgets('Home fits at 320 dp and text scale 1.3 in $theme', (tester) async {
        await _pumpThemed(
          tester,
          dark: dark,
          home: const HomeScreen(
            signedInOverride: true,
            greetingNameOverride: 'Alexandria',
            looksOverride: [
              {'look_name': 'Soft daylight rose', 'preview_image_url': ''},
              {'look_name': 'Evening berry', 'preview_image_url': ''},
              {
                'look_name': 'A long saved look name that wraps onto two lines',
                'preview_image_url': '',
              },
            ],
          ),
        );

        expect(find.text('Hi, Alexandria'), findsOneWidget);
        expect(find.text('Find your perfect look'), findsOneWidget);
        expect(find.text('Open camera'), findsOneWidget);
        expect(find.text('Find my shade'), findsOneWidget);
        expect(find.text('Saved looks'), findsOneWidget);
        expect(find.text('Favourites'), findsOneWidget);
        expect(find.text('My Makeup Bag'), findsOneWidget);
        expect(find.text('Skin analysis'), findsOneWidget);
        expect(find.text('Products'), findsOneWidget);
        expect(find.text('Beauty Profile'), findsNothing);
        expect(find.text('My orders'), findsNothing);
        expect(find.text('Notifications'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Profile fits at 320 dp and text scale 1.3 in $theme', (tester) async {
        await _pumpThemed(
          tester,
          dark: dark,
          home: const ProfileScreen(
            preview: ProfilePreview(
              name: 'Alexandria Montgomery-Smith',
              email: 'alexandria.montgomery.smith@example.com',
            ),
          ),
        );

        expect(find.text('Alexandria Montgomery-Smith'), findsOneWidget);
        expect(find.text('Beauty Profile'), findsOneWidget);
        expect(find.text('View your skin details and preferences'), findsOneWidget);
        expect(find.text('My orders'), findsOneWidget);
        expect(find.text('Notifications'), findsOneWidget);
        expect(find.text('Privacy and security'), findsOneWidget);
        expect(find.text('Sign out'), findsOneWidget);
        expect(find.text('AR Makeup'), findsOneWidget);
        expect(find.text('Find my shade'), findsNothing);
        expect(find.text('Saved looks'), findsNothing);
        expect(find.text('Favourites'), findsNothing);
        expect(find.text('Makeup bag'), findsNothing);
        expect(find.text('Skin analysis'), findsNothing);
        expect(find.text('Products'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('signed-out Profile shows a sign-in card', (tester) async {
      await _pumpThemed(
        tester,
        home: const ProfileScreen(preview: ProfilePreview.signedOut()),
      );

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing);
      expect(find.text('Beauty Profile'), findsNothing);
      expect(find.text('AR Makeup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppLoader', () {
    testWidgets('spins, and stays still when animations are disabled', (tester) async {
      await tester.pumpWidget(_loaderApp(const AppLoader(), disable: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      expect(_turns(tester), greaterThan(0.15));

      await tester.pumpWidget(_loaderApp(const AppLoader(), disable: true));
      await tester.pump();
      expect(_turns(tester), 0);
      await tester.pump(const Duration(seconds: 1));
      expect(_turns(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('centered label and inline ring both render', (tester) async {
      await tester.pumpWidget(
        _loaderApp(
          const AppLoader.centered(label: 'Please wait'),
          disable: true,
        ),
      );
      await tester.pump();
      expect(find.text('Please wait'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);

      await tester.pumpWidget(
        _loaderApp(const AppLoader.inline(color: Colors.white), disable: true),
      );
      await tester.pump();
      expect(find.byType(AppLoader), findsOneWidget);
      expect(_turns(tester), 0);
    });
  });
}

bool _signedIn() => true;

bool _signedOut() => false;

Future<void> _pumpThemed(
  WidgetTester tester, {
  required Widget home,
  bool dark = false,
}) async {
  AppColors.themeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return AppThemeScope(
          notifier: AppColors.themeNotifier,
          child: MediaQuery(
            data: media.copyWith(
              textScaler: const TextScaler.linear(1.3),
              disableAnimations: true,
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: home,
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Widget _loaderApp(Widget body, {required bool disable}) {
  return MaterialApp(
    builder: (context, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(disableAnimations: disable),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: Scaffold(body: body),
  );
}

double _turns(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(AppLoader),
      matching: find.byType(CustomPaint),
    ),
  );
  return (paint.painter as AppLoaderPainter).turns;
}
