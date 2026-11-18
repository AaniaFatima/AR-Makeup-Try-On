# Test and analysis report — AR Makeup Try-On

Audit date: 16 Oct 2026. No source files were edited. `flutter analyze`, `flutter test`, and `flutter build apk --debug` used `--no-pub`. `git status` afterwards showed only the files that were already modified before this audit. No lockfile change.

## What was run

| Command | Result |
| --- | --- |
| `flutter analyze --no-pub` | Exit 1. **0 errors, 5 warnings, 56 info.** 61 issues, about 101s. Flutter 3.41.4, Dart 3.11.1 |
| `flutter test --no-pub` | **16 tests passed** in `test/phase0_test.dart`. Nothing else is in `test/` |
| `flutter devices` | Windows, Chrome, Edge. **No Android or iOS device.** No `flutter run` was active, so none was touched |
| `flutter build apk --debug --no-pub` | **Succeeded** in 824s. Output `build/app/outputs/flutter-apk/app-debug.apk`. Not installed |

Assets present: `assets/effects/makeup.deepar` (910,304 bytes), `assets/images/hero_model.png`, `assets/textures/gorgeous.png`, `assets/textures/sexy.png`, `android/app/libs/deepar.aar` (37,732,987 bytes), `android/app/src/main/assets/models/face_landmarker.task`.

Release APK was not built. iOS was not built.

### Analyzer noise (not product bugs)

56 info items: `avoid_print` (4), deprecated `withOpacity` / `Share` / `activeColor` / `WillPopScope` / `onPopPage` / `Color.red`, `unnecessary_underscores`, `curly_braces_in_flow_control_structures`, `use_build_context_synchronously` (2), `depend_on_referenced_packages` (`vector_math` imported from `try_on_screen.dart` line 11), `annotate_overrides` on `ProductsCache`, dangling doc comment on `color_utils.dart`.

### Analyzer warnings (real, small)

| Warning | Where |
| --- | --- |
| Unused imports: `permission_handler`, `camera_permission_screen.dart`, `try_on_screen.dart`, `looks_cache.dart` | `lib/app/app.dart` lines 2, 6, 7, 8 |
| Unused field `_beautyProfileLoading` | `profile_screen.dart` line 42. It is set at lines 65 and 77 and never read, so the profile never shows a beauty-profile loading state |

No compile errors. The debug APK confirms this tree builds on this machine.

## How to read the issues

- **Verified by running** — analyze, unit tests, or the debug APK compile.
- **Reviewed in code** — read, not executed.
- **Could not test** — needs a phone, a DeepAR license check, a live Supabase project, or a pasted SQL script.

No **P0** was verified. A P0 here means a core flow that crashes or cannot complete on the Android path this project actually builds. The iOS camera gap is P1 because the working path is Android (`deepar.aar`, CameraX `start_camera`, PowerVR/MediaTek notes in `try_on_screen.dart` lines 1092–1094). On an iPhone that same gap is a dead camera or a process kill.

## Issues

### P1 — iOS camera and AR are not configured

**Reviewed in code.**

- DeepAR iOS license is the literal placeholder `YAHAN_APNI_IOS_LICENSE_KEY_DALEIN` (`try_on_screen.dart` lines 201–203), passed at lines 1192–1193.
- `ios/Runner/Info.plist` has no `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, or `NSPhotoLibraryAddUsageDescription`. iOS terminates the process when camera or photo access is requested without those keys.
- No `CFBundleURLTypes` for `io.supabase.flutter`, so Google return (`auth_screen.dart` lines 193–195) has no iOS hook. Android does (`AndroidManifest.xml` lines 36–43).
- After foundation capture, resume calls `start_camera` only on Android. Other platforms hit `_giveUpOnCamera` (`try_on_screen.dart` lines 1142–1144).

**Fix:** Add the three usage strings and the Supabase URL scheme. Replace the iOS license. Confirm `start_camera` has an iOS equivalent, or do not open the `camera` plugin on iOS until it does.

### P1 — “Buy” on a matched shade does not open that product

**Reviewed in code.**

`_buyOnWeb` opens `/products?product=<productKey>` (`foundation_match_screen.dart` lines 354–360). `ar-makeup-web/src/app/products/page.tsx` takes no search params and renders the collection. The product screen is `src/app/products/[product_key]/page.tsx`. The makeup bag already builds `/products/$productKey` (`makeup_bag_screen.dart` lines 33–36).

**Fix:** Open `/products/${match.productKey}` through `WebBridge.openAuthenticated`. Add `?shade=` only if that product page reads it.

### P1 — Makeup bag links ignore `AppConfig` and the session bridge

**Reviewed in code.**

`makeup_bag_screen.dart` lines 8–36 hardcode `https://ar-makeup-web.vercel.app/` and concatenate another leading slash (`$kWebBaseUrl/makeup-bag`), then `launchUrl` with no tokens. Favourites use `WebBridge.openAuthenticated` (`favourites_screen.dart` lines 35–42). A signed-in user adding or refilling from the bag lands as a visitor if that page requires a session. `--dart-define=WEB_BASE_URL` does not affect this screen.

**Fix:** Delete `kWebBaseUrl`. Use `WebBridge.openAuthenticated` and `AppConfig` paths `/makeup-bag` and `/products/$productKey`.

### P1 — DeepAR dependency is pinned to one Windows user profile

**Reviewed in code. This machine could still build.**

`pubspec.yaml` lines 59–60 set `deepar_flutter` to `C:\Users\amnat\AppData\Local\Pub\Cache\hosted\pub.dev\deepar_flutter-0.0.5`. The debug APK built because that directory exists here. Another machine, or a wiped Pub cache, cannot resolve the package. `GEMINI_PROJECT_CONTEXT.md` lines 202–203 already say this.

**Fix:** Vendor the package inside the repo (relative `path:`) and keep `deepar.aar` next to it. Drop the absolute override.

### P1 — Release identity is still a debug sample

**Reviewed in code. Release APK not built.**

`android/app/build.gradle.kts` lines 34–39 sign `release` with the debug keystore. `applicationId` is `com.example.makeup_tryon` (lines 24–25). `ENV_SETUP.md` lines 82–87 tell a demo to pass `--dart-define` values; they do not fix the application id or the keystore.

**Fix:** A real application id and an upload keystore before any APK leaves the laptop. Keep debug signing on debug only.

### P1 — Saved-looks cache can come back after sign-out

**Reviewed in code.**

`LooksCache.prefetch` (`looks_cache.dart` lines 71–124) has no generation token. After the network `await` it writes `_looks` and sets `_loaded = true`. `clear()` (lines 167–174) sets `_loaded = false` and does not cancel that in-flight call. `main.dart` lines 55–58 call `clear()` on `signedOut`. If sign-out overlaps a prefetch, the old user’s looks (including preview URLs) are written back, and the next `prefetch` returns immediately because `_loaded` is true (line 72).

The on-disk file is one path, `saved_looks_cache.json` (lines 25–27), not per user. `clear()` does write an empty file, so the bug is the race, not a missing wipe.

**Fix:** Increment a generation in `clear()` and ignore prefetch completions that do not match. Key the file by user id.

### P1 — Tests do not cover the features an evaluator will ask about

**Verified by running.**

`test/phase0_test.dart` covers `AppConfig.publicUrl`, `lookPath`, `buyLookPath`, and `WebBridge.normalizeNext` (16 assertions, all passed). No test loads `FoundationMatchResult.fromJson`, `SkinSampler`, intensity mapping, `LooksCache`, or the buy URL. `color_utils.dart` and `skin_color.dart` are untested. `flutter test` cannot see a wrong `/products?product=` link.

**Fix:** Widget-free tests for JSON parsing, the ΔE sort, intensity bounds, cache clear-vs-prefetch, and the foundation buy path. Keep them free of Supabase.

### P2 — `MaterialApp` theme does not follow the dark switch

**Reviewed in code.**

`app.dart` lines 43–46 build `theme: ThemeData()` (the comment inside the constructor is not a theme) and never set `darkTheme` or `themeMode`. `AppColors.themeNotifier` only rebuilds that same light `ThemeData`. Screens that paint with `AppColors` do switch (`settings_screen.dart` lines 269–274). Material dialogs, text fields, and switches that use `Theme.of` stay light.

**Fix:** Pass `theme`, `darkTheme`, and `themeMode: AppColors.themeNotifier.value`.

### P2 — Profile notifications switch does nothing

**Reviewed in code.**

`profile_screen.dart` lines 32 and 1156–1162. Settings already marks notifications “coming soon” (`settings_screen.dart` lines 279–284). The profile switch defaults to on and resets on every visit.

**Fix:** Remove the switch until a real notification path exists.

### P2 — Camera gate can strand the user

**Reviewed in code.**

“Maybe Later” (`camera_permission_screen.dart` lines 214–229) snackbars and stays. There is no `WidgetsBindingObserver`, so returning from system Settings does not re-read permission. The user must tap Allow again. Deny (not permanent) only snackbars (lines 68–69).

**Fix:** “Maybe Later” should pop to welcome. On resume, re-check `Permission.camera.status`.

### P2 — Beauty profile failures look like an empty profile

**Reviewed in code.**

`BeautyProfileService.fetchProfile` (`beauty_profile_service.dart` lines 40–59) returns `UserBeautyProfile()` on any error, including a timeout, and `print`s the error. The profile screen then shows no profile (`profile_screen.dart` lines 63–78). A later questionnaire save can overwrite a real server profile the phone failed to read.

**Fix:** Return a failure to the UI. Do not POST a new profile unless the GET succeeded or the user confirms they are creating one.

### P2 — Try-on controls are small and unnamed

**Reviewed in code.**

`_TopBarButton` is 42×42 (`try_on_screen.dart` lines 3326–3343) with `GestureDetector` and no `tooltip` or `Semantics`. Material’s minimum is 48. Contrast of white icons on a live camera depends on the scene. Welcome text uses fixed sizes (`welcome_screen.dart` lines 123–131) inside a `SingleChildScrollView` with `NeverScrollableScrollPhysics` (lines 108–109), so large text scaling can clip.

A search of `lib/` found no `Semantics` widgets. A few `tooltip:` values exist on foundation, favourites, and the bag.

**Fix:** 48px targets, `Semantics` labels on the try-on bar, and a welcome scroll view that can scroll.

### P2 — Favourites are memory-only

**Reviewed in code.**

`FavouritesCache` (`favourites_cache.dart`) has no disk file. `LooksCache` and `MakeupBagCache` do. Offline, favourites stay empty after a process restart until Supabase answers. Fetch errors are `debugPrint` only (lines 45–46).

**Fix:** Same disk-then-network pattern as `looks_cache.dart`.

### P2 — Look save is several requests, not one transaction

**Reviewed in code.** Documented in `GEMINI_PROJECT_CONTEXT.md` lines 154–155 and 209. `pending_looks_queue.dart` retries. A crash between the Storage upload and the row insert can leave an orphan file or a look without items. Not executed here.

**Fix:** One server RPC that inserts the look and its items, or delete the uploaded object when the queue gives up.

### P2 — Dead weight and a disabled Android check

**Reviewed in code. Debug build still succeeded.**

- Face-mesh channel and `face_landmarker.task` have no Dart caller (`MainActivity.kt` lines 16–48).
- Three CSVs under `lib/` are unused.
- `color_utils.dart` has no callers. `try_on_screen.dart` line 13 still imports it. Analyzer did not report that import. A search of `lib/` found no call to `colorDistance`, `sortShadesByClosest`, or `hexToRgb`.
- `go_router` and Riverpod are unused (inventory rows 55–56).
- `android/app/build.gradle.kts` lines 57–60 set `CheckAarMetadataTask` `enabled = false`.
- `print` in `beauty_profile_service.dart` lines 57, 77, 108, `beauty_profile_questionnaire_screen.dart` line 96, and `profile_screen.dart` line 75.
- Debug-only “Copy sample JSON” (`foundation_match_screen.dart` lines 876–881) is behind `kDebugMode`. It is absent from a release build.

**Fix:** Delete unused libraries and the face-mesh channel, or wire the channel up. Turn the AAR metadata check back on once the local AAR is a normal dependency. Replace `print` with `debugPrint`.

### P2 — Docs disagree with the code

**Reviewed in code.**

- `README.md` is the Flutter template (“A new Flutter project”).
- `ENV_SETUP.md` lines 16–17 say defaults are “the current dev Supabase project and the ngrok tunnel”. `app_config.dart` lines 41–43 default `WEB_BASE_URL` to `https://ar-makeup-web.vercel.app`.
- `GEMINI_PROJECT_CONTEXT.md` lines 188–189 say `camera` and `google_mlkit_face_detection` are unused. Both are used (`foundation_capture_screen.dart`, `skin_sampler.dart`).
- `.vscode/launch.json` is referenced from `ENV_SETUP.md` lines 94–96 and is not in the project.

**Fix:** Replace the README with the real run command, the Vercel default, and what is Android-only. Update or retire `GEMINI_PROJECT_CONTEXT.md`.

### Secrets seen, values not copied here

| File | Kind |
| --- | --- |
| `lib/app/config/app_config.dart` lines 26–36 | Supabase project URL and **anon** JWT as `defaultValue`. `ENV_SETUP.md` lines 100–109 say the anon key is public and that the service-role key must not appear. No service-role key was found under `lib/` |
| `lib/app/screens/try_on_screen.dart` lines 201–202 | DeepAR **Android license key** string literal, next to the iOS placeholder |

No `.env` values were printed.

## What is in good shape (reviewed)

- Foundation match failures are typed (`FoundationMatchException`, `SkinSampleException`) and the screen has sign-in, working, retake, and result stages (`foundation_match_screen.dart` lines 74, 471–475).
- Capture disposes the `CameraController` before pop (`foundation_capture_screen.dart` lines 88–113, 412–419). `PopScope` blocks a back-press during the shutter (lines 410–414, 425–429).
- DeepAR is not destroyed on ordinary `paused` (`try_on_screen.dart` lines 371–379). Overlay routes avoid the root navigator (lines 1081–1117).
- Auth sign-in from an overlay pops instead of stacking a second `TryOnScreen` (`auth_screen.dart` lines 68–98). The listener is cancelled in `dispose` (lines 126–127).
- Open-redirect cases in `phase0_test.dart` lines 56–96 match `WebBridge.normalizeNext` (`web_bridge.dart` lines 134–139). Those tests passed.
- Email and password length checks exist (`auth_screen.dart` lines 134–152; `privacy_security_screen.dart` lines 25–33).
- Sign-out clears the foundation hex so the next account does not inherit a skin tone (`main.dart` lines 61–64; `foundation_match_service.dart` lines 640–662).
- Sampling comments and the code agree that photos are not uploaded: patches and an illuminant are (`skin_sampler.dart` lines 6–21; request body `foundation_match_service.dart` lines 393–399).

## Could not test

- Front camera, light gate, three-frame shutter, ML Kit on a real face, DeepAR license acceptance, effect file on a face, CameraX rebind after foundation capture.
- Google OAuth return, email confirmation, RLS, Storage uploads, `delete_user`.
- Whether `db/015_foundation_common_shades.sql` has been pasted. The file itself says it is not applied automatically (lines 4–7).
- Live `POST /api/foundation-match` and `/api/beauty-profile` against the Vercel host.
- Release manifest merge, release shrinking, and iOS compile.
- Contrast on a live camera frame, TalkBack, and large text on a device.
- Offline behaviour on a phone (caches were read, not flown).

## Code vs tests vs docs

| Claim | Code | Tests | Docs |
| --- | --- | --- | --- |
| URL join and open-redirect guard | Yes | 16 passing tests | `ENV_SETUP.md`, `phase0_test.dart` header |
| Foundation match and light gate | Yes | None | `GEMINI_PROJECT_CONTEXT.md` does not describe them |
| `camera` and ML Kit unused | False | — | `GEMINI_PROJECT_CONTEXT.md` 188–189 |
| Default web host is ngrok | False; default is Vercel | `isEphemeralWebHost` only asserts `isA<bool>` (`phase0_test.dart` 98–104) | `ENV_SETUP.md` 16–17 |
| README describes the product | — | — | No. Template only |
