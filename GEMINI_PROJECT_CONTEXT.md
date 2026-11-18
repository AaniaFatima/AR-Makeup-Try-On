# AR Makeup Try-On Flutter App: AI Handoff Context

This document is the source-of-truth orientation for an AI assistant working on this repository. Read it before changing code. The app is a Flutter mobile application for real-time AR makeup try-on, saved looks, account management, and handoff to a companion e-commerce/skin-analysis website.

## 1. Product Summary

The app lets a user:

- Open a polished welcome/onboarding screen.
- Sign in, register, or use Google OAuth through Supabase Auth.
- Grant camera permission and use live camera AR makeup.
- Try nine makeup categories: eyelashes, lipstick, lip gloss, foundation, blush, mascara, highlighter, eyeliner, and eyeshadow.
- Select shades loaded from Supabase, with a local offline shade cache.
- Adjust category intensity with a 0-100% UI slider.
- Capture and save a complete makeup look.
- View saved looks offline-first, favourite them, delete them, apply them again, share their image, copy/share a public link, or open a look in the authenticated website.
- Edit profile/avatar, change password, delete account, toggle camera permission, and toggle dark mode.
- Open website modules such as products, skin analysis, support, cart, orders, saved looks, checkout, and buy-this-look.

The app is not a generic product catalog UI. The active central experience is the DeepAR camera try-on. Product metadata is cached for future/Phase 1 catalog features but is not currently consumed by an active Flutter screen.

## 2. Runtime Flow

`lib/main.dart` is the entry point:

1. Initializes Flutter and preserves the native splash screen.
2. Initializes Supabase using `AppConfig`.
3. Waits up to 3 seconds for the initial Supabase auth session.
4. If signed in, starts `LooksCache.prefetch(userId)` in the background.
5. Starts public `ProductsCache.prefetch()` regardless of auth state.
6. Chooses the first screen:
   - no session -> `WelcomeScreen`
   - session + camera permission -> `TryOnScreen`
   - session without camera permission -> `CameraPermissionScreen`
7. Clears the saved-looks cache on sign-out.
8. Loads the persisted light/dark theme and starts `AppRoot` inside `ProviderScope`.

`lib/app/app.dart` owns the root `MaterialApp` and swaps to `WelcomeScreen` after sign-out. Navigation is currently done with direct `Navigator.push`/`pop` and `MaterialPageRoute`; although `go_router` is declared in `pubspec.yaml`, it is not the active routing system.

## 3. Folder and File Map

### Root

- `pubspec.yaml`: Flutter SDK constraint, dependencies, assets, DeepAR path override, and native splash settings.
- `analysis_options.yaml`: Dart lint configuration.
- `ENV_SETUP.md`: build-time environment values and emulator/device/tunnel commands.
- `OPTIMIZATION_SUMMARY.md`: rationale for offline-first caches, background saves, splash timing, and timeout behavior.
- `README.md`: still mostly the default Flutter template; do not treat it as an accurate product specification.
- `GEMINI_PROJECT_CONTEXT.md`: this AI handoff document.

### `lib/`

- `lib/main.dart`: app bootstrap, Supabase initialization, initial auth/camera decision, cache warm-up, theme setup.
- `lib/app/app.dart`: root app widget, theme notifier rebuild, sign-out home reset.
- `lib/app/config/app_config.dart`: all environment-dependent Supabase and companion website configuration plus URL builders.
- `lib/app/utils/app_colors.dart`: global theme state stored in `SharedPreferences` and shared colors.

### `lib/app/screens/`

- `welcome_screen.dart`: animated welcome/hero screen; entry points to camera permission and auth.
- `auth_screen.dart`: email/password login and registration, Google OAuth, auth-state navigation, and post-login cache warm-up.
- `camera_permission_screen.dart`: requests camera permission; if permanently denied, can open system settings; then routes to try-on.
- `try_on_screen.dart`: primary feature and most sensitive file. Owns DeepAR, shade data, makeup application, sliders, save flow, lifecycle recovery, and navigation to other screens.
- `saved_looks_screen.dart`: offline-first saved-look gallery with all/favourites tabs, image precaching, refresh, favourite toggle, apply, delete, image sharing, public link sharing, and authenticated web opening.
- `profile_screen.dart`: user metadata, avatar/profile entry, camera permission setting, saved looks shortcut, website shortcuts, settings, and sign-out.
- `edit_profile_screen.dart`: selects an image using `image_picker`, uploads it to Supabase Storage bucket `avatars`, and updates Supabase user metadata.
- `privacy_security_screen.dart`: password update and account deletion through Supabase RPC `delete_user`.
- `settings_screen.dart`: persisted dark mode, language placeholder, help-center link, and about dialog.

### `lib/app/cache/`

- `looks_cache.dart`: singleton in-memory plus disk cache for `saved_looks`. It loads JSON from the application support directory first, then fetches Supabase with an 8-second timeout. It exposes optimistic add/update/remove and listeners.
- `pending_looks_queue.dart`: singleton offline save queue. Stores pending metadata in `pending_saved_looks/pending_saved_looks.json` and screenshot files in the same application-support folder.
- `products_cache.dart`: singleton catalog model/cache for `makeup_products`. It loads disk first, fetches paginated Supabase data in pages of 1,000, stops at 50 pages or a short page, and provides product lookup, prices, totals, and categories.

### `lib/app/services/`

- `web_bridge.dart`: safe bridge from Flutter Supabase session to the companion website. Authenticated URLs carry access/refresh tokens only in the URL fragment and must only be opened in the user's own browser.

### Local data and assets

- `assets/effects/makeup.deepar`: DeepAR effect file loaded at runtime.
- `assets/textures/sexy.png`, `assets/textures/gorgeous.png`: lash textures copied to a temporary file because DeepAR expects a file path.
- `assets/images/hero_model.png`: welcome-screen image.
- `lib/makeup_products.csv`: local catalog export with product metadata, pricing, category, image URL, finish, coverage/skin-friendliness/status fields.
- `lib/product_shades.csv`: local shade export containing product key, shade key/name, hex, order, color family, skin tone, and undertone.
- `lib/product_shades (2).csv`: duplicate/alternate shade export; do not assume it is the canonical source without comparing it.

## 4. DeepAR and Makeup Logic

`TryOnScreen` has a `TryOnCategory` enum with exactly these categories:

`eyelashes`, `lipstick`, `lipGloss`, `foundation`, `blush`, `mascara`, `highlighter`, `eyeliner`, `eyeshadow`.

Product keys are the category contract. Prefix mapping is:

| Category | Product key prefix | DeepAR game object |
|---|---|---|
| Eyelashes | `lsh_` | `EyeLashes` |
| Lipstick | `lip_` | `lips` |
| Lip gloss | `gloss_` | `lips` |
| Foundation | `fnd_` | `face_makeup` |
| Blush | `blu_` | `Blush` |
| Mascara | `mas_` | `EyeLashes` |
| Highlighter | `hgl_` | `Highlighter` |
| Eyeliner | `eln_` | `Eyeliner` |
| Eyeshadow | `esh_` | `EyeShadow` |

Do not change these prefixes or DeepAR object names without updating the database rows, saved-look apply logic, and the effect file contract.

### Intensity mapping

The UI stores a normalized user value from 0.0 to 1.0, but it is not sent directly to DeepAR. `_mapIntensityToBackend()` maps each category into a realistic alpha range:

- lipstick: 0.30-0.68
- lip gloss: 0.38-0.60
- foundation: 0.12-0.44
- blush: 0.10-0.38
- eyeshadow: 0.15-0.82
- eyeliner: 0.55-0.95
- highlighter: 0.10-0.44
- eyelashes/mascara: 0.70-1.00, multiplied by the lash config opacity

This is intentional visual tuning. Do not replace it with a single linear alpha range unless the AR result is re-tested on a real device.

### DeepAR parameter rules

- Foundation uses `foundationColor` on `face_makeup`.
- Lipstick sets ambient, diffuse, subtle specular, and shininess 18 for a semi-matte result.
- Lip gloss sets ambient, diffuse, near-white specular, and shininess 72 for a wet result.
- Blush, eyeshadow, eyeliner, and highlighter use `u_color`.
- Lashes/mascara read `ar_lash_configs`, load either `sexy.png` or `gorgeous.png`, set transform scale, and combine database opacity with mapped intensity.
- Clearing a category sends transparent values rather than removing the whole effect.

### DeepAR lifecycle constraint

The controller is created once and is destroyed only in `dispose()` or the explicit detached-state teardown. Do not destroy it during ordinary `paused` events: Android can emit `paused` when a route is pushed, and destroying the EGL surface then causes `EGL_BAD_NATIVE_WINDOW` on return. Initialization waits for several frames plus approximately 800 ms because `deepar_flutter 0.0.5` has no usable surface-ready callback. Initialization is guarded against races and retried up to three times with backoff.

The Android DeepAR license key is present in `try_on_screen.dart`; the iOS key is a placeholder and iOS AR is not release-ready.

## 5. Supabase Contracts

The Flutter app directly uses these tables/storage/RPC names:

- `product_shades`: shade rows; fields used include `product_key`, `shade_key`, `shade_name`, `shade_hex`, `shade_order`.
- `ar_lash_configs`: lash rows; fields used include `product_key`, `base_mask_type`, `lash_color`, `opacity`, `scale_x`, `scale_y`.
- `makeup_products`: public catalog; fields used by `DbProduct` are `product_key`, `name`, `brand`, `category`, `image_url`, `price`, `finish`, `is_skin_friendly`, `is_active`.
- `saved_looks`: user saved-look metadata including `id`, `user_id`, `look_name`, `preview_image_url`, `created_at`, `is_favourite`.
- `saved_look_items`: item rows associated by `look_id`; they contain the selected product/shade/intensity data needed to reapply a look.
- Storage bucket `looks`: saved screenshot uploads, exposed with public URLs.
- Storage bucket `avatars`: profile image uploads.
- RPC `delete_user`: account deletion.

The save operation is a multi-step sequence: capture screenshot, upload preview to `looks`, insert `saved_looks`, then insert `saved_look_items`. It is not one database transaction. On failure, a pending local queue retains the screenshot and item metadata, and `TryOnScreen` retries it on startup/resume. Partial remote records are possible if an upload or later insert succeeds before a subsequent step fails.

## 6. Saved Looks and Offline Behavior

`LooksCache` is the read model used by the gallery. It:

- Loads `saved_looks_cache.json` from application support storage.
- Fetches current user looks from Supabase in descending `created_at` order.
- Falls back to disk data on socket errors/timeouts.
- Notifies screens on updates.
- Performs optimistic favourite/add/remove changes and persists them immediately.

The gallery applies a saved look by fetching `saved_look_items` for the selected `look_id`, popping back to `TryOnScreen`, and passing the item list as the navigation result. `TryOnScreen` then maps each saved row back to a category and reapplies shade/intensity. Preserve the item field names when changing save logic.

Product data is public and intentionally survives sign-out. Saved looks are user-specific and are cleared from memory on sign-out, but cached files are not a general security boundary; do not expose another user's cache after changing auth behavior.

## 7. Web Integration and Security Rules

`AppConfig` reads `WEB_BASE_URL`, `SUPABASE_URL`, and `SUPABASE_ANON_KEY` through `--dart-define`, with development defaults. Use `ENV_SETUP.md` for emulator, LAN, ngrok, and release commands. Release builds must override all environment values.

Use `WebBridge.openAuthenticated(context, path)` for the signed-in user's own browser when the destination needs their session, such as saved looks, orders, cart, or checkout. The bridge refreshes near-expiry sessions and constructs:

`WEB_BASE_URL/auth/bridge#at=<access>&rt=<refresh>&next=<same-origin-path>`

Use `WebBridge.publicUrl(path)` or `openPublic` for anything copied, shared, posted, or sent to another person. Never put access/refresh tokens in copy/share links. `normalizeNext()` rejects non-path URLs, protocol-relative paths such as `//evil.com`, and bridge recursion.

Keep Flutter web paths synchronized with the companion Next.js site's route folders. The companion website is a separate project and is not included in this workspace.

## 8. State, Theme, and Dependencies

- `ProviderScope` is present, but no Riverpod providers are currently used; most state is local `StatefulWidget` state or singleton caches.
- `AppColors.themeNotifier` controls light/dark state. The preference key is `is_dark_mode`.
- Screens mostly use `AppColors` directly. `AppRoot` currently has a placeholder `ThemeData(/* same as before */)`, so global Material theme changes may not affect all screens.
- Direct navigation is used instead of `go_router`.
- Declared but apparently unused in active Dart code: `camera`, `go_router`, and `google_mlkit_face_detection`. Do not remove them blindly; verify whether planned integrations depend on them.

## 9. Android Native Integration

- `android/app/libs/deepar.aar`: checked-in local DeepAR Android SDK artifact.
- `android/app/src/main/assets/models/face_landmarker.task`: MediaPipe face-landmarker model.
- `MainActivity.kt`: transparent Flutter activity and `makeup_tryon/face_mesh` MethodChannel.
- `FaceMeshRunner.kt`: converts NV21 frames to bitmaps and runs MediaPipe FaceLandmarker in video mode.

The face-mesh channel currently has no active Dart caller according to the inspected code, so it is scaffolding for a future/custom face-landmark path rather than the current DeepAR rendering path.

Android build constraints include Kotlin/Java 17, the local AAR, and a debug signing configuration used for release. Do not assume a clean machine can build until the local DeepAR dependency override and AAR are available.

## 10. Important Known Risks

- `pubspec.yaml` overrides `deepar_flutter` with a machine-specific absolute Windows Pub cache path. Replace this with a portable dependency before sharing/building elsewhere.
- iOS DeepAR license is a placeholder; iOS camera usage/OAuth configuration should be validated before release.
- Android release signing currently uses debug signing.
- Development Supabase and ephemeral ngrok defaults are present. Always use release `--dart-define` values for demo/submission builds.
- The anon key is client-safe only when Supabase Row Level Security policies are correctly configured. Never add a service-role key.
- Authenticated browser URLs contain bearer tokens in fragments. They must never be logged, copied, shared, or persisted.
- Multi-step look saves are not transactional.
- Cached data can be stale; a product or look may have been deleted/de-listed upstream.
- `DbShade.color` assumes a valid six-digit hex color. Validate data before widening the input contract.

## 11. Rules for Future AI Changes

1. Read this file plus the target Dart file before editing.
2. Preserve the product-key prefixes, DeepAR game-object names, parameter names, and saved-look database field names.
3. Keep DeepAR lifecycle changes isolated and test them on a physical Android device; do not “simplify” the surface waits or destroy-on-pause behavior.
4. Preserve offline-first behavior and do not turn cache/network work into a blocking UI operation.
5. For new website links, choose authenticated bridge vs token-free public URL deliberately.
6. Do not put secrets or service-role credentials in Flutter code, CSV files, or build arguments committed to source control.
7. Prefer the existing direct-navigation, singleton-cache, and `AppColors` patterns unless there is a concrete reason to migrate architecture.
8. When changing a Supabase query, update the documented table/column contract and verify RLS assumptions.
9. Test at minimum with `flutter analyze` and focused `flutter test`; AR, permissions, OAuth, uploads, and lifecycle behavior require device testing beyond unit tests.

## 12. Useful Validation Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=WEB_BASE_URL=<reachable-web-url>
```

For a release/demo APK, also provide `WEB_BASE_URL`, `SUPABASE_URL`, and `SUPABASE_ANON_KEY` explicitly. Never rely on the development defaults during evaluation or deployment.