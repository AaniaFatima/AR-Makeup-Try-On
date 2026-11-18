# Feature inventory — AR Makeup Try-On (Flutter)

Audit date: 16 Oct 2026. Scope: `d:\FYP\AR-Makeup-Try-On` only. The Next.js app is mentioned where the phone calls it.

Package name `makeup_tryon` (`pubspec.yaml` line 1), version `1.0.0+1` (line 19), Dart SDK `^3.10.7` (line 22). Android application id `com.example.makeup_tryon` (`android/app/build.gradle.kts` lines 24–25). Display label `makeup_tryon` (`android/app/src/main/AndroidManifest.xml` line 9). iOS display name `Makeup Tryon` (`ios/Runner/Info.plist` lines 7–8).

## What it is

A phone app for live AR makeup try-on (DeepAR), saving looks, a beauty profile, and foundation shade matching. Sampling stays on the device (ML Kit). Ranking is `POST` to the companion site. Shopping, skin-analysis routines, cart, and checkout stay in the browser, with the Supabase session handed across by `WebBridge`.

Who uses it: a person trying makeup on their own face. Email accounts are Supabase users. “Get Started” on the welcome screen opens the camera without an account (`welcome_screen.dart` lines 198–206). Saving a look, favourites, the bag, and foundation match require a session.

Navigation is `Navigator` + `MaterialPageRoute`. `go_router` is in `pubspec.yaml` (line 38) and is not imported. `ProviderScope` wraps the app (`main.dart` line 90); there are no Riverpod providers. State is `StatefulWidget` plus singleton caches.

## Status key

- **Complete** — the flow is implemented in this tree.
- **Partial** — a real slice works and a visible slice does not.
- **Stubbed** — UI says it is not built.
- **Broken** — the control exists and cannot do what it claims.
- **Dead code** — nothing in the running app calls it.

“Complete” means the code is there. It does not mean a phone camera was exercised. See `02_TEST_AND_ANALYSIS_REPORT.md`.

## Screens and features

| # | Feature | Purpose | Files | Status |
| --- | --- | --- | --- | --- |
| 1 | Native splash | Pink splash until first frame | `pubspec.yaml` 121–126; `main.dart` 23, 88 | Complete |
| 2 | Welcome | Hero, Get Started, Sign In | `lib/app/screens/welcome_screen.dart`; asset `assets/images/hero_model.png` | Complete |
| 3 | Email sign-in | Password login, validation, auth errors | `lib/app/screens/auth_screen.dart` 134–186 | Complete |
| 4 | Email registration | Sign-up, then “check your email”; does not enter the camera | `auth_screen.dart` 164–177 | Complete |
| 5 | Google sign-in | OAuth via Supabase, redirect `io.supabase.flutter://login-callback/` | `auth_screen.dart` 188–196; Android intent filter `AndroidManifest.xml` 36–43. No iOS URL type in `Info.plist` | Partial |
| 6 | Cold-start routing | No session → welcome. Session + camera → try-on. Session without camera → permission | `main.dart` 45–53, 93–107 | Complete |
| 7 | Sign-out | Clears looks, favourites, bag, beauty profile, foundation cache; root returns to welcome | `main.dart` 55–65; `app.dart` 28–32; `profile_screen.dart` 196–208 | Complete |
| 8 | Camera permission | Request, permanently-denied snackbar with Open Settings, Allow → try-on | `lib/app/screens/camera_permission_screen.dart` 48–71, 214–229. “Maybe Later” only shows a snackbar and stays on this screen | Partial |
| 9 | Android live AR try-on | Nine categories, shades, intensity, nested navigator so DeepAR’s surface stays up | `lib/app/screens/try_on_screen.dart` 95–105, 1107–1117, 1167–1244; `assets/effects/makeup.deepar`; `android/app/libs/deepar.aar` | Complete |
| 10 | iOS live AR try-on | Same screen, iOS license is the placeholder `YAHAN_APNI_IOS_LICENSE_KEY_DALEIN` | `try_on_screen.dart` 201–203, 1190–1195. `Info.plist` has no camera or photo usage strings | Broken |
| 11 | Shade sync and offline cache | `product_shades` + `ar_lash_configs`, disk cache, 12s timeout | `try_on_screen.dart` 464–467, 1249–1267 | Complete |
| 12 | Intensity slider | UI 0–1 mapped to a per-category alpha range | `try_on_screen.dart` 107–156 | Complete |
| 13 | Lash textures | `sexy.png` / `gorgeous.png` copied out for DeepAR | `try_on_screen.dart` 1317; `assets/textures/` | Complete |
| 14 | “My bag” shade filter | Try-on sheet can show only bag shades | `try_on_screen.dart` 208, 877, 2503–2516 | Complete |
| 15 | Save look and retry queue | Screenshot, upload, `saved_looks` + `saved_look_items`; failures queued and retried | `try_on_screen.dart` 529–608, 1682+; `lib/app/cache/pending_looks_queue.dart` | Complete |
| 16 | Saved looks gallery | Offline-first list, all / favourites tabs, pull to refresh | `lib/app/screens/saved_looks_screen.dart` 16, 103–162; `lib/app/cache/looks_cache.dart` | Complete |
| 17 | Re-apply a saved look | Loads `saved_look_items`, pops to try-on, reapplies | `saved_looks_screen.dart` 264–299; `try_on_screen.dart` 1620 | Complete |
| 18 | Favourite or delete a look | Optimistic favourite; delete | `saved_looks_screen.dart` 225–310; `looks_cache.dart` 147–157 | Complete |
| 19 | Share a look | Image share, copy public URL, share link. Tokens are not put in the shared URL | `saved_looks_screen.dart` 462–508; `web_bridge.dart` 49–55 | Complete |
| 20 | Open a look on the website | Authenticated `/looks/{id}` | `saved_looks_screen.dart` 493–494; `app_config.dart` 79 | Complete |
| 21 | Buy this look | Price from `ProductsCache`, then `/looks/{id}?action=buy` | `try_on_screen.dart` 2087–2120, 3481–3527 | Complete |
| 22 | Foundation shade match | On-device patches, `POST /api/foundation-match`, retake vs result | `foundation_match_screen.dart`; `foundation_match_service.dart` 292–297, 378–404; web `ar-makeup-web/src/app/api/foundation-match/route.ts` | Complete |
| 23 | Sign-in before the match camera | Unsigned session starts on a sign-in stage; 401 returns to that stage | `foundation_match_screen.dart` 135–169, 275–279 | Complete |
| 24 | Light gate and three frames | Front camera, flash off, shutter locked until a brightness check passes; stream failure falls back to written hints | `foundation_capture_screen.dart` 1–9, 177–243, 321–407 | Complete |
| 25 | Gallery photo for matching | `image_picker` gallery; result copy says a gallery photo is less reliable | `foundation_match_screen.dart` 179–195, 763–764 | Complete |
| 26 | White-paper reference | Optional; if the sampler misses the sheet, `PaperTapScreen` asks the user to tap it | `foundation_match_screen.dart` 128–129, 250–255; `foundation_capture_screen.dart` 594+ | Complete |
| 27 | Refusal instead of a guess | Server `quality.ok != true`, or region spread above 5 ΔE, shows retake | `foundation_match_service.dart` 239; `foundation_match_screen.dart` 364–373, 708–744 | Complete |
| 28 | Short result | One card, or two if the catalog is far; ΔE detail sits under “How this was measured” | `foundation_match_screen.dart` 748–875 | Complete |
| 29 | Shade vote | `too_light` / `right` / `too_dark` posted as `{action: feedback}` | `foundation_match_screen.dart` 375–377, 829–843; `foundation_match_service.dart` 576–584; web route handles `body.action === "feedback"` | Complete |
| 30 | Try matched shade in AR | Pops `FoundationTryOnRequest`; try-on applies it after the overlay closes | `foundation_match_screen.dart` 327–336; `try_on_screen.dart` 1063–1078 | Complete |
| 31 | Add matched shade to the bag | Calls `MakeupBagCache.toggleInBag` only when absent | `foundation_match_screen.dart` 339–351 | Complete |
| 32 | Buy matched shade on the web | Opens `/products?product=<key>` | `foundation_match_screen.dart` 354–360. Web list page `ar-makeup-web/src/app/products/page.tsx` does not read that query. Product pages are `/products/[product_key]` | Broken |
| 33 | Product favourites | Supabase `user_favourites`, realtime, “see on web” uses the auth bridge | `favourites_screen.dart` 35–42; `favourites_cache.dart` | Complete |
| 34 | Makeup bag | Lists `makeup_bags` / `makeup_bag_items`, local cache, remove, Try On filter. Add / refill / details use a hardcoded URL and `url_launcher`, not `WebBridge` | `makeup_bag_screen.dart` 8–42; `makeup_bag_cache.dart` | Partial |
| 35 | Profile | Name, email, avatar, shortcuts, web tiles, camera switch | `profile_screen.dart` | Complete |
| 36 | Edit profile | Name plus gallery avatar upload to Storage bucket `avatars` | `edit_profile_screen.dart` 42–80 | Complete |
| 37 | Beauty profile questionnaire | Four steps, prefill `GET /api/beauty-profile?prefill=true`, save `POST` | `beauty_profile_questionnaire_screen.dart` 1–4, 74–76; `beauty_profile_service.dart` 22–95; web `ar-makeup-web/src/app/api/beauty-profile/route.ts` | Complete |
| 38 | Change password | Min 6 characters, `auth.updateUser` | `privacy_security_screen.dart` 24–67 | Complete |
| 39 | Delete account | RPC `delete_user`, then sign-out | `privacy_security_screen.dart` 70–84 | Complete |
| 40 | Two-factor authentication | Row labelled “Coming soon”, `onTap` is null | `privacy_security_screen.dart` 291–311 | Stubbed |
| 41 | Dark theme | `is_dark_mode` in SharedPreferences; screens read `AppColors`. `MaterialApp` uses an empty `ThemeData()` and never sets `themeMode` | `settings_screen.dart` 246–275; `app_colors.dart` 4–16; `app.dart` 40–48 | Partial |
| 42 | Language | English selectable. Urdu and Hindi show “Soon” and do not change locale | `settings_screen.dart` 51–111 | Stubbed |
| 43 | Notifications (settings) | Tile subtitle is the feature name; control is a coming-soon row | `settings_screen.dart` 279–284 | Stubbed |
| 44 | Notifications toggle (profile) | Switch writes `_notifications` in memory only. Default `true`. Not saved, no permission, no channel | `profile_screen.dart` 32, 1156–1162 | Broken |
| 45 | Help center | Public `/support` | `settings_screen.dart` 46–49; `app_config.dart` 73 | Complete |
| 46 | About | Version 1.0.0 dialog | `settings_screen.dart` 115–188 | Complete |
| 47 | Shop and skin-analysis handoff | Profile opens products, skin analysis, and related authenticated paths in the browser | `profile_screen.dart` 191–194, 986, 1054; paths in `app_config.dart` 69–77 | Complete |
| 48 | Session bridge and open-redirect guard | Fragment tokens, `normalizeNext` rejects `//host` and absolute URLs | `web_bridge.dart` 17–40, 126–140; web `ar-makeup-web/src/app/auth/bridge/page.tsx` | Complete |
| 49 | OAuth return deep link | Android `VIEW` filter for `io.supabase.flutter` / `login-callback`. iOS `Info.plist` has no `CFBundleURLTypes` | `AndroidManifest.xml` 36–43; `Info.plist` (no URL types) | Partial |
| 50 | Try-on loading and failure | Full-screen loading until DeepAR inits; retry after three failures | `try_on_screen.dart` 1167–1244, 2192–2221, 3175, 3230 | Complete |
| 51 | Catalog cache | Public `makeup_products` where `main_category = makeup`, disk then network. Used by the bag and buy-this-look. No in-app catalog screen | `products_cache.dart` 1–28, 40–50 | Complete |
| 52 | MediaPipe face mesh | Android `makeup_tryon/face_mesh` channel and `face_landmarker.task`. No Dart caller | `MainActivity.kt` 16–48; `FaceMeshRunner.kt`; no matches under `lib/` | Dead code |
| 53 | CSV catalogs under `lib/` | `makeup_products.csv`, `product_shades.csv`, `product_shades (2).csv`. No Dart reads them | `lib/*.csv`; grep of `lib/**/*.dart` finds no `rootBundle` load of these files | Dead code |
| 54 | RGB distance helper | `color_utils.dart`. Try-on sorts foundation with `scoreShadesBySkinTone` in `skin_color.dart`. No call to `colorDistance` or `sortShadesByClosest` | `color_utils.dart`; `try_on_screen.dart` 13, 907–911 | Dead code |
| 55 | `go_router` | Declared dependency, zero imports | `pubspec.yaml` 38 | Dead code |
| 56 | Riverpod | `ProviderScope` only | `pubspec.yaml` 39; `main.dart` 90 | Dead code |

## Counts

| Status | Count |
| --- | --- |
| Complete | 40 |
| Partial | 5 |
| Broken | 3 |
| Stubbed | 3 |
| Dead code | 5 |
| **Total rows** | **56** |

Partial: 5, 8, 34, 41, 49. Broken: 10, 32, 44. Stubbed: 40, 42, 43. Dead: 52–56.

## Companion calls (phone → web)

Default host `https://ar-makeup-web.vercel.app` (`app_config.dart` lines 41–43), overridable with `--dart-define=WEB_BASE_URL`.

| Call | Where |
| --- | --- |
| `POST /api/foundation-match` | `foundation_match_service.dart` 297, 430–435, 576–584 |
| `GET`/`POST /api/beauty-profile` | `beauty_profile_service.dart` 22–95 |
| Browser `/auth/bridge#at&rt&next` | `web_bridge.dart` 79–94 |
| Browser `/products`, `/skin-analysis`, `/support`, `/cart`, `/my-orders`, `/looks/{id}`, `/looks/{id}?action=buy` | `app_config.dart` 69–93 |
| Makeup bag bypasses that config | `makeup_bag_screen.dart` 8–36 |

Supabase is called directly for auth, `product_shades`, `ar_lash_configs`, `saved_looks`, `saved_look_items`, `user_favourites`, `makeup_bags`, `makeup_bag_items`, `makeup_products`, Storage `avatars` and `looks`, and RPC `delete_user`.

## Verified recent context

- ML Kit sampling: `skin_sampler.dart` lines 234–247 (`google_mlkit_face_detection`).
- POST to `/api/foundation-match`: `foundation_match_service.dart` lines 297 and 430–435.
- Light gate: `foundation_capture_screen.dart` lines 61–66 and 225–243. It is a preview-brightness check, not ML Kit.
- Sign-in before the match camera: `foundation_match_screen.dart` lines 135–139.
- Short result: `foundation_match_screen.dart` lines 748–875.
- Maybelline SQL: `ar-makeup-web/db/015_foundation_common_shades.sql` lines 1–7 say it must be pasted and is not applied automatically. The phone does not embed those 30 shades. Whether the live database has them is **unverified**.
- Camera freeze fix: `FoundationCaptureScreen.cameraPluginTookDevice` (`foundation_capture_screen.dart` 45–48, 137–138) and `MethodChannel('deep_ar/camerax').invokeMethod('start_camera')` (`try_on_screen.dart` 1120–1148). That channel exists in `deepar_flutter` 0.0.5 (`CameraXHandler.java`, `MethodStrings.cameraXChannel`). Not run on a device in this audit.
- Web default is the Vercel host above, not an ngrok URL. `ENV_SETUP.md` lines 16–17 still say the default is an ngrok tunnel.
- `pubspec.yaml` lines 40, 47–49, 56–60: `camera`, `image_picker`, `google_mlkit_face_detection`, and a path override of `deepar_flutter` 0.0.5. `camera` and ML Kit are used. `GEMINI_PROJECT_CONTEXT.md` lines 188–189 say they are unused. That document is stale.
