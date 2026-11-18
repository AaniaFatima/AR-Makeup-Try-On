# Recommendations — AR Makeup Try-On

Specific to this repo. Each gap in `03_GAP_ANALYSIS.md` has a fix here. Priority: **Must** (demo or correctness), **Should** (an evaluator will notice), **Nice** (depth).

## Small (under a day)

### 1. Point Buy at the product page

**Must.** The matched-shade button opens `/products?product=…` (`foundation_match_screen.dart` lines 354–360). The site’s product page is `/products/[product_key]`.

Change `_buyOnWeb` to open `/products/${match.productKey}` through `WebBridge.openAuthenticated`. Add a shade query only if that page reads one. The bag already builds `/products/$productKey` (`makeup_bag_screen.dart` lines 33–36). No new dependency. Risk: confirm the route is the product key.

### 2. Makeup bag uses WebBridge and AppConfig

**Must.** Delete `kWebBaseUrl` (`makeup_bag_screen.dart` line 8). Open `/makeup-bag` and `/products/$productKey` with `openAuthenticated`, same as favourites (`favourites_screen.dart` lines 35–42). `--dart-define=WEB_BASE_URL` will then apply. Risk: the bag page must accept the auth bridge.

### 3. Remove the fake notifications switch

**Must.** `profile_screen.dart` lines 1156–1162 default on and store nothing. Settings already says coming soon (`settings_screen.dart` lines 279–284). Delete the profile switch, or use the same Soon chip. Risk: none.

### 4. Maybe Later leaves the camera gate

**Should.** Pop to `WelcomeScreen` (`camera_permission_screen.dart` lines 214–229). On resume, re-read `Permission.camera.status`. Risk: do not push a second `TryOnScreen` if one is already under the overlay navigator.

### 5. Wire dark mode into MaterialApp

**Should.** `app.dart` lines 43–46 build an empty `ThemeData()` and never set `themeMode`. Pass `theme`, `darkTheme`, and `themeMode` from `AppColors.themeNotifier`. Keep `AppColors` for custom surfaces. Risk: Material colors and `AppColors` disagree until both are checked on settings, profile, and auth.

### 6. README and the stale default-host sentence

**Must** for the viva packet. `README.md` is the Flutter template. Replace it with: Android demo, optional `WEB_BASE_URL`, default host `https://ar-makeup-web.vercel.app` (`app_config.dart` lines 41–43), foundation match needs the web API, iOS is not ready. Fix `ENV_SETUP.md` lines 16–17 (they still say ngrok). Add the `.vscode/launch.json` that lines 94–96 promise, or delete that paragraph. Risk: none.

### 7. One sentence on saved stills

**Should.** `camera_permission_screen.dart` lines 156–157 say video never leaves the device. Add that a saved look uploads a still. Link `/privacy` with `WebBridge.openPublic`, the same pattern as Help (`settings_screen.dart` lines 46–49). Risk: do not put tokens on that URL.

### 8. A failed beauty-profile load is not an empty profile

**Should.** `beauty_profile_service.dart` lines 56–59 return a blank model on any error. Surface the failure. Do not POST a questionnaire over a profile the GET did not successfully read. Risk: a real “no row yet” must stay distinct from a timeout.

### 9. Analyzer warnings and print

**Nice.** Drop the unused imports in `app.dart` lines 2–8. Use or delete `_beautyProfileLoading` (`profile_screen.dart` line 42). Replace `print` with `debugPrint` in the beauty-profile files. Risk: none.

### 10. Favourites on disk

**Should.** Copy the disk-then-network shape from `looks_cache.dart` into `favourites_cache.dart`. Clear the file on sign-out. Risk: the same in-flight race as looks, unless the fetch has a generation token (item 14).

### 11. Try-on targets and labels

**Should.** `_TopBarButton` is 42 by 42 with no semantics (`try_on_screen.dart` lines 3326–3343). Use a 48px hit target and `Semantics` labels for save, profile, looks, and match. Let the welcome column scroll (`welcome_screen.dart` lines 108–109). Risk: short phones. The permission screen already branches under height 700.

### 12. Tests that lock the bugs above

**Must.** Add a test file with no network: `FoundationMatchResult.fromJson` for a retake and a match, `shownUndertone` for a warm hue the server called cool (`foundation_match_screen.dart` lines 79–85), intensity stays inside the ranges at `try_on_screen.dart` lines 117–124, and the buy path is `/products/{key}`. `test/phase0_test.dart` already shows the style (16 tests passed). Risk: keep `shownUndertone` importable.

## Medium (1–3 days)

### 13. Portable DeepAR

**Must.** `pubspec.yaml` lines 59–60 point at one Windows Pub cache. Vendor `deepar_flutter` 0.0.5 in the repo with a relative path, and keep `android/app/libs/deepar.aar`. Rebuild the debug APK from a clean checkout. Risk: the plugin Gradle file expects an AAR named `deepar`. Do not upgrade the plugin in the same change.

### 14. Sign-out cannot revive the previous look cache

**Must.** `LooksCache.clear` (`looks_cache.dart` lines 167–174) does not cancel `prefetch` (lines 71–124). Add a generation counter and ignore stale completions. Name the cache file with the user id. Do the same for the bag. Risk: the first paint after login can be empty until the new fetch finishes. That is the right failure.

### 15. Confirm the foundation catalog, and show a count

**Must** if `db/015_foundation_common_shades.sql` was never pasted. Lines 4–7 say it is manual. For the demo, run that SQL in Supabase, then show on the result how many shades came back (`foundation_match_screen.dart` lines 791–795 already covers the empty case). Risk: the script does not update existing hex values (lines 6–7). Read it before pasting over a live catalog.

### 16. Release identity

**Should** before an APK is handed in. Application id `com.example.makeup_tryon` and debug signing (`android/app/build.gradle.kts` lines 24–39). Use a real id and an upload keystore. Risk: a new application id signs the user out of a debug install.

### 17. Look save as one server call

**Should.** The save is a screenshot, a Storage upload, then two inserts. `pending_looks_queue.dart` retries and can still orphan a file (`GEMINI_PROJECT_CONTEXT.md` lines 154–155). Add one RPC for the two rows. Keep the phone queue for offline. Risk: RLS on the RPC.

### 18. Before and after on the try-on screen

**Should.** There is no compare control. A press-and-hold that zeroes the current alphas and restores them belongs in `try_on_screen.dart`, using the existing clear-to-transparent path. Risk: high. Test on a device. Do not destroy the DeepAR controller.

### 19. Shade name filter on the try-on sheet

**Nice.** The sheet filters by bag (`_showOnlyMyBag`) and not by text. Filter `DbShade` locally, and use `ProductsCache` for brand when it is warm. Risk: a cold cache. Fall back to shade name.

### 20. Retire or label dead code

**Should.** `MainActivity.kt` channel `makeup_tryon/face_mesh` and `face_landmarker.task` have no Dart caller. Delete them, or say “unused scaffold” in the README. Same choice for `lib/*.csv`, `color_utils.dart`, and unused `go_router` / `flutter_riverpod`. Re-enable `CheckAarMetadataTask` (`build.gradle.kts` lines 57–60) only after the AAR dependency is a normal one. The debug build succeeded with the check off. Risk: delete the model only after a Dart search stays empty.

### 21. A device script for the viva

**Must.** One page, not a new feature: cold start, deny camera, allow camera, lipstick and intensity, save look, airplane mode still opens the gallery, foundation sign-in gate, dark room stays on the light gate, three frames, result, Try in AR (camera returns), buy opens the product, sign out and in as someone else (looks and skin hex are gone). This audit could not run that list. No Android device was attached.

## Big (3+ days)

### 22. iOS, only if the panel will see an iPhone

**Must if iOS is in scope. Otherwise say Android-only in the README and stop.** Placeholder license at `try_on_screen.dart` line 203. No camera or photo usage strings and no URL scheme in `Info.plist`. `start_camera` gives up off Android (lines 1142–1144). Work is an Apple DeepAR key, privacy strings, the URL type, and a device pass. Risk: the nested-navigator fixes (`try_on_screen.dart` lines 1081–1117) are about Android `SurfaceView`. Budget a device.

### 23. A short match history on the profile

**Nice.** Votes are stored on the server and do not change today’s shade (`foundation_match_screen.dart` lines 831–833). Keep the last few readings (hex, delta E, shade name, vote) in SharedPreferences beside the keys at `foundation_match_service.dart` lines 495–506, and show them on the profile tile. Risk: do not store patches or photos.

### 24. A small accuracy table

**Nice.** The claim is perceptual (delta E, retake above 5). There is no phone log of known shade versus recommended shade. A debug export of the existing `debugRequestJson` (`foundation_match_service.dart` lines 305–306) plus the chosen shade, for window light and warm light, is enough for a results slide. Do not upload faces. Risk: an ethics form if you record faces. The current design avoids that if you keep only numbers.

### 25. A read-only catalog screen

**Nice.** `ProductsCache` (`products_cache.dart` lines 1–18) still has no browse screen. A list that opens the same product URL as the bag would make the shop feel part of the phone. Do not rebuild cart or Stripe. `try_on_screen.dart` lines 3484–3486 explain why there is one cart. Risk: copying the website’s filters.

## Which item covers which gap

| Gap | Item |
| --- | --- |
| iOS AR broken | 22, or Android-only in 6 |
| Buy URL | 1 |
| Makeup bag host and session | 2 |
| DeepAR absolute path | 13 |
| Debug signing and example application id | 16 |
| Looks cache race | 14 |
| Tests only cover URLs | 12 |
| Dark theme partial | 5 |
| Fake notification switch | 3 |
| Camera Maybe Later | 4 |
| Empty beauty profile on error | 8 |
| Accessibility | 11 |
| Favourites not on disk | 10 |
| Look save is not one transaction | 17 |
| Dead face mesh, CSVs, color utils, unused packages | 20 |
| README and ENV_SETUP | 6 |
| 30 shades unverified | 15 |
| No before/after | 18 |
| No shade search | 19 |
| Privacy wording and no privacy link | 7 |
| No device evidence | 21 |
| No accuracy study | 24 |
| No in-app catalog | 25 |
| Only one cached match | 23 |

Do not start by replacing navigation with `go_router`. The nested navigator in `try_on_screen.dart` lines 1081–1117 exists because a root-navigator push drops the DeepAR surface. That change is a camera risk, not a feature.
