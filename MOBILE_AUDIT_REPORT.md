# Mobile audit — Phase 1 measurement (no code changes)

Date: 2 Nov 2026. App folder: `d:\FYP\AR-Makeup-Try-On` (`makeup_tryon` 1.0.0+1). The website tree was not modified. No commit. No application source was edited. `flutter pub upgrade` was not run. `flutter pub outdated` was not run (the Flutter lock was kept for the profile build).

Runtime numbers below are from the **already-installed debug APK** (package flags `DEBUGGABLE`, `lastUpdateTime` 2026-10-28 20:30). That binary can differ from the source read today. A profile install was **attempted** because the installed signature matches the local debug keystore (same SHA-256). It did not install. **Profile numbers are not measured.** Camera pixels were not seen. Effect quality is **needs manual check by the owner**.

## 1. Environment

| Item | Result |
| --- | --- |
| Flutter | 3.41.4 stable, Dart 3.11.1, SDK `D:\flutter\src\flutter`. `flutter doctor`: Android licenses not accepted; Visual Studio C++ workload missing (does not block Android). |
| Device | `adb devices` and `flutter devices`: `bb55d6c2`, product OnePlus8, model **IN2013**, manufacturer OnePlus, **Android 11 (API 30)**, `arm64-v8a`. |
| Package | `applicationId` `com.example.makeup_tryon` (`android/app/build.gradle.kts` lines 10 and 25). Installed `versionName` 1.0.0, `versionCode` 1, **minSdk 24, targetSdk 36**. First install 2026-10-11, last update 2026-10-28. Debuggable. `ALLOW_BACKUP` set. |
| Signature | Installed APK cert is `CN=Android Debug`. SHA-256 matches `%USERPROFILE%\.android\debug.keystore` alias `androiddebugkey`. Replacing with a profile build signed by that key would **not** wipe data. No project keystore or `key.properties`. Release type still uses the debug signing config (`build.gradle.kts` lines 34–39). |
| adb reverse | `adb reverse --list` empty. The phone is not forwarded to a PC port. |
| Disk at start | C: 5.48 GB free, D: 15.38 GB free. |

`flutter doctor` also reported a short wait on the Flutter startup lock. No `flutter run` or `npm run dev` was killed.

## 2. Feature inventory

Navigation is imperative `Navigator` / `MaterialPageRoute`. `go_router` is in `pubspec.yaml` (locked 17.1.0) and is **not imported**. `MaterialApp` has a single `home` (`lib/app/app.dart` lines 41–53). There is no named route table.

Initial screen (`lib/main.dart` lines 45–53): no session → `WelcomeScreen`; session and camera granted → `TryOnScreen`; session and camera not granted → `CameraPermissionScreen`. Sign-out resets home to `WelcomeScreen` (`lib/app/app.dart` lines 26–30). Session wait is capped at 3 seconds (`lib/main.dart` lines 98–110).

### Screens

| Screen | File | How it is opened |
| --- | --- | --- |
| Welcome | `lib/app/screens/welcome_screen.dart` | Signed out. Get Started → camera permission (line 179). Sign In → `AuthScreen` (line 192). Terms and privacy open the website (lines 29–31). |
| Auth | `lib/app/screens/auth_screen.dart` | Email sign-in/up (lines 161–208). Google OAuth redirect `io.supabase.flutter://login-callback/` (lines 216–218). If the navigator can pop, it pops so it does not stack a second `TryOnScreen` (lines 99–103). |
| Camera permission | `lib/app/screens/camera_permission_screen.dart` | Grant → `TryOnScreen` (lines 57–61). Permanently denied → snackbar + Open Settings (lines 62–69). Maybe later → saved looks if signed in, else welcome (lines 89–101). |
| Try-on | `lib/app/screens/try_on_screen.dart` | Live AR. Overlay navigator pushes other screens **over** the DeepAR view (lines 1262–1272) so the surface is not destroyed on a route push. |
| Home | `lib/app/screens/home_screen.dart` | Tiles: beauty profile, find my shade, favourites, makeup bag, saved looks, skin check (website), shop (website), my orders (website), notifications (lines 97–148). |
| Beauty profile | `lib/app/screens/beauty_profile_questionnaire_screen.dart` | From Home. Save goes to Supabase, not the HTTP route (see API table). |
| Foundation match | `lib/app/screens/foundation_match_screen.dart` | Camera, gallery, or re-rank from a stored hex. `_busy` blocks double taps (line 208). |
| Foundation capture | `lib/app/screens/foundation_capture_screen.dart` | Live stills for the matcher. `PaperTapScreen` is in the same file (line 883) for a white-paper tap. |
| Favourites | `lib/app/screens/favourites_screen.dart` | Web favourites and product buy links (lines 34–42). |
| Makeup bag | `lib/app/screens/makeup_bag_screen.dart` | Add products → `/makeup-bag?add=1` (lines 17–18). Refill → product page with `shade` (lines 21–25). |
| Saved looks | `lib/app/screens/saved_looks_screen.dart` | Grid, share, open look on the web (line 494). |
| Notifications | `lib/app/screens/notifications_inbox_screen.dart` | Orders and restock rows; tap opens the website (lines 145, 166). |
| Profile / edit | `profile_screen.dart`, `edit_profile_screen.dart` | Settings, privacy, avatar upload. |
| Settings | `lib/app/screens/settings_screen.dart` | Dark mode, camera toggle, help (`/support`), notifications, about. |
| Privacy | `lib/app/screens/privacy_security_screen.dart` | Password update (lines 24–67). Delete account via RPC `delete_user` (lines 70–75). |

Android deep link in the app manifest is only the Supabase OAuth callback (`AndroidManifest.xml` lines 36–43). `/auth/bridge` is a **website** URL opened in the external browser, not an app route.

### Backend URL

`AppConfig` (`lib/app/config/app_config.dart`):

- `WEB_BASE_URL`, default **`https://ar-makeup-web.vercel.app`** (lines 41–43). Trailing slashes stripped (lines 131–136).
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` via `String.fromEnvironment`, with **defaults compiled into** lines 26–36. The anon key value is not copied here.
- `isEphemeralWebHost` (lines 52–62) is true for empty host, ngrok, trycloudflare, loca.lt, localhost, `10.0.2.2`, `192.168.*`. The Vercel default is not ephemeral. The only user-visible effect of a dead tunnel is a `debugPrint` (`web_bridge.dart` lines 149–153). The link is still launched.
- `ENV_SETUP.md` documents emulator `http://10.0.2.2:3000`, LAN `http://192.168.x.x:3000`, and ngrok. Those are build flags, not the default. No `adb reverse` is configured in the app.

Reachability of the **default** base URL (not an AI route):

- Development machine `HEAD`: `/` **200 in 1535 ms**, `/products` **200 in 1555 ms**, `/terms` **200 in 878 ms**.
- Phone ICMP to that host: 3/3, RTT min/avg/max **38.8 / 47.7 / 52.6 ms**.
- Phone `curl -I`: **HTTP 200** for `/` and `/products` (Vercel, `X-Vercel-Cache` HIT on `/`). A follow-up timing request was mis-quoted by PowerShell and downloaded the public HTML; status was still 200. **Phone TTFB was not captured cleanly.**
- The phone can reach this host. Localhost would not work; this build’s default is not localhost.

When the site is unreachable: foundation match shows “Couldn't reach the shade matcher.” after 25 s (`foundation_match_service.dart` lines 438–443). Catalog and looks keep the disk copy. Web links still open the browser and fail there. There is no connectivity plugin and no global offline banner.

### API and data calls

Timeouts are per call. There is **no shared retry policy**. 429 is not handled as its own case.

| Call | Where | Timeout | Retry | Error behaviour |
| --- | --- | --- | --- | --- |
| `POST {WEB_BASE_URL}/api/foundation-match` JSON patches, not a photo | `foundation_match_service.dart` lines 297, 393–435 | 25 s | No | 401 → sign-in message (lines 446–450). Other non-200 → server `error` string or a generic sentence (lines 453–472). Network/timeout → “Couldn't reach the shade matcher.” Body logged up to 300 chars (lines 465–468). |
| Same URL, `{action: feedback, vote}` | lines 576–614 | 25 s | No | 401 sign-in. Other failures “Couldn't save that vote.” |
| Same URL, `{skinHex, save: false}` re-rank, no photo | lines 415–427 | 25 s | No | Same `_post`. |
| `GET {WEB_BASE_URL}/api/beauty-profile` and `?prefill=true` | `beauty_profile_service.dart` lines 22, 43–46, 67–69 | 10 s | No | 401 is thrown then **swallowed**; caller gets an empty profile (lines 51–58). `print` on failure (analyzer `avoid_print`). |
| Beauty profile **save** is **not** that HTTP route. Upsert `user_skin_profiles` | lines 93–162 | none | Drops unknown columns and retries | `lastSaveError` sentence. |
| `makeup_products` select, `main_category = makeup`, pages of 1000, max 50 pages | `products_cache.dart` lines 110–114, 277–316 | 10 s per page | No | Socket/timeout → null, disk copy kept. In-flight callers share one fetch (lines 237–244). |
| `product_shades` select **all rows** | `try_on_screen.dart` lines 1421–1425 | 12 s | No | Snack/error string if cache was empty (lines 1454–1460). Disk file `product_shades_cache.json`. |
| `ar_lash_configs` select all | lines 1465–1467 | **none** | No | `debugPrint` only. Lashes then have no texture config. |
| `saved_looks` | `looks_cache.dart` lines 143–152 | 8 s | No | Disk per user. Cleared on sign-out. |
| `user_favourites` | `favourites_cache.dart` lines 48–61 | **none** | No | `debugPrint`, disk prefs key is per user. Realtime channel. |
| `makeup_bags` + `makeup_bag_items` | `makeup_bag_cache.dart` lines 40–80 | **none** | No | If no bag named “My Everyday Bag”, **inserts one** (lines 48–55). Prefetch runs at startup when a session exists (`main.dart` lines 34–39). Disk key `makeup_bag_items_cache` is **not** user-scoped (line 11). `clear()` writes an empty list (lines 273–278). |
| `orders`, `product_restock_alerts` | `notifications_inbox_screen.dart` lines 97–124 | **none** | Orders query retries **without** `total` if the first select throws (lines 106–113) | Inline notice, not a crash. |
| `saved_looks` / `saved_look_items` / `looks` writes | `try_on_screen.dart` around 692–721 and 2410–2433 | not wrapped in the reads above | Failed save is queued on disk (`pending_looks_queue.dart`) | |
| `http.get` of a look image | `saved_looks_screen.dart` line 470 | **none** | No | |
| Auth: `signInWithPassword`, `signUp`, `signInWithOAuth`, `updateUser`, `rpc('delete_user')` | auth and privacy screens | Supabase client default | No | Snackbars. Buttons disabled while `isLoading`. |
| Avatar storage `avatars` | `edit_profile_screen.dart` lines 79–83 | none | No | |
| Website open | `web_bridge.dart` | none (external browser) | Refresh session if expired or < 2 min left (lines 43–45, 118–124). Refresh failure still sends the current session (lines 110–114) | Snackbar if `launchUrl` fails (lines 163–165). Tokens go in the **URL fragment** `at`, `rt`, `next` (lines 88–94). `normalizeNext` rejects `//`, absolute URLs, and the bridge path itself (lines 134–139). Unit-tested. |

Startup also fires catalog prefetch for everyone (`main.dart` line 43) and, if signed in, looks, favourites, and bag prefetch (lines 34–39). That is duplicate work with the try-on shade fetch: products and shades are two queries, not one.

Signed-in password flows were **not** exercised. No test password was available. A session was already on the phone: logcat showed `supabase.auth: INFO: Refresh session` at 23:47:01 and then DeepAR init. That means `TryOnScreen` ran (`main.dart` lines 46–49). The account was not identified and tokens were not copied out of logcat. Launching that build also runs makeup-bag prefetch, which **can insert a row** if the default bag is missing. Whether an insert happened was **not verified**. No order, Stripe session, or AI endpoint (chat, routine, skin photo) was called.

## 3. Static audit

### Analyzer and tests

`flutter analyze` (70.3 s, exit code 1): **56 info, 0 warning, 0 error**. Infos are `avoid_print` in `beauty_profile_service.dart` (lines 57, 77, 112, 116, 171), deprecated APIs (`withOpacity`, `Share`, `WillPopScope`, `Color.red/green/blue`, `onPopPage`, `activeColor`), `use_build_context_synchronously` in `saved_looks_screen.dart:454`, `depend_on_referenced_packages` for `vector_math` in `try_on_screen.dart:12`, and style nits. The vendored plugin adds a few infos, including `http://` in `packages/deepar_flutter/pubspec.yaml` line 4 (homepage only).

`flutter test`: **30 passed**, about 21 s. Files: `test/phase0_test.dart` (URL join and open-redirect guard), `test/audit_contracts_test.dart` (product/bag URLs, looks sign-out race, foundation JSON), `test/demo_looks_test.dart`. No widget tests, no device tests. `packages/deepar_flutter/test/deep_ar_test.dart` is a stub.

### Dependencies (locked, not upgraded)

| Package | Lock | Note |
| --- | --- | --- |
| `deepar_flutter` | path, **0.0.5** vendored | Dart 2 homepage constraint was relaxed in the local `pubspec.yaml` so it resolves. Android classes come from `android/app/libs/deepar.aar` (**37,732,987 bytes**). |
| `supabase_flutter` | 2.12.0 (constraint `^2.5.6`) | Used. |
| `go_router` 17.1.0 | unused import | Dead weight. |
| `flutter_riverpod` 3.3.1 | only `ProviderScope` in `main.dart` line 82 | No providers. |
| `cupertino_icons` 1.0.8 | no `CupertinoIcons` use found | Likely unused. |
| `camera` 0.12.0, `google_mlkit_face_detection` 0.13.2, `image_picker` 1.2.1, `share_plus` 12.0.1, `cached_network_image` 3.4.1, `http` 1.6.0, `permission_handler` 12.0.1 (overridden), `shared_preferences` 2.5.5, `path_provider` 2.1.5, `url_launcher` 6.3.2, `flutter_native_splash` 2.4.7 | used | Newer pub.dev versions were **not checked**. |
| `vector_math` | via the plugin, imported by the app | Analyzer info, not a direct dependency. |

`com.google.mediapipe:tasks-vision:0.10.32` is an app dependency (`build.gradle.kts` line 74). `FaceMeshRunner` (`MainActivity.kt` lines 16–40, channel `makeup_tryon/face_mesh`) has **no Dart caller**. The model `android/app/src/main/assets/models/face_landmarker.task` is **3,758,596 bytes** and still ships. Face measurement for foundation uses ML Kit in `skin_sampler.dart`, not this channel.

### Network, cache, lists

- Timeouts: foundation 25 s, beauty GET 10 s, products 10 s, shades 12 s, looks 8 s. **Missing** on lash configs, favourites, makeup bag, notifications, beauty-profile writes, and the look-image `http.get`.
- No retries except beauty-profile column stripping and the orders select fallback.
- Friendly errors exist for foundation match, auth, camera permission, and web-launch failure. Beauty-profile fetch hides 401. There is no 429 copy.
- Offline: products, looks, shades, favourites, and bag read disk first. Try-on can show cached shades. Empty catalog with no disk file has an error string only when the shade list is empty.
- Double-tap: auth, privacy, camera permission, and foundation match (`_busy`) disable the control. WebBridge does not.
- Images: `CachedNetworkImage` on bag, favourites, saved looks. **`memCacheWidth: 140` only on favourites** (`favourites_screen.dart` line 261). Bag and looks decode full files. Auth uses `Image.network` (line 574) with no cache width. Welcome decodes `assets/images/hero_model.png` (**1,841,743 bytes**) at `welcome_screen.dart` line 79.
- Shade list uses `ListView.builder` (`try_on_screen.dart` line 3394). Saved looks and bag use `GridView.builder`. Home’s nine tiles are a shrink-wrapped `GridView.count` (fine).
- `product_shades` is one unbounded `select()`. Products are paged at 1000.
- Session: `Supabase.initialize` sets only URL and anon key (`main.dart` lines 25–28). That is the plugin default store (shared preferences on Android), not an encrypted store. Refresh is listened for at lines 67–69. Sign-out clears looks, favourites, bag, beauty profile, and foundation match memory (lines 56–64).
- Rebuild hotspot (code trace, not frame-timed): face callbacks `setState` the whole try-on screen (`try_on_screen.dart` lines 862–870). The bottom panel is a `BackdropFilter` blur 28 (`try_on_screen.dart` lines 3030–3032) while the camera is open. DeepAR resolution is `Resolution.high` (line 1349).

### DeepAR

One effect: `assets/effects/makeup.deepar` (**910,304 bytes**), loaded at `try_on_screen.dart` lines 1370–1372. Textures `gorgeous.png` (37,170 bytes) and `sexy.png` (32,686 bytes) are lash masks (lines 1638–1641).

| Category | In the chip row? | Game object | Intensity map (user 0–1 → alpha) |
| --- | --- | --- | --- |
| Lipstick | Yes | `lips` | 0.30–0.68 (lines 132–134, 1704–1728) |
| Lip gloss | Yes | `lips` | 0.38–0.60 (lines 135–137, 1744–1768) |
| Blush | Yes | `Blush` | 0.10–0.38 |
| Eyeshadow | Yes | `EyeShadow` | 0.15–0.82 |
| Eyeliner | Yes | `Eyeliner` | 0.55–0.95 |
| Eyelashes | Yes | `EyeLashes` | 0.70–1.00, times lash-config opacity |
| Mascara | **Yes** (not filtered) | same `EyeLashes` | same. If `ar_lash_configs` has no row, apply returns without drawing (lines 1633–1674). |
| Foundation | Yes | `face_makeup` / `foundationColor` | 0.12–0.44 (lines 1682–1688) |
| Highlighter | **Hidden** | mapped to `Highlighter` but never applied | Chips filter it out (lines 3101–3107). `_isHighlighter` returns early (lines 883–886, 1620–1622). Bag/apply shows “Highlighter isn't in this effect.” (lines 426, 1166). Intensity math remains (lines 150–152). |

Init: up to 3 attempts, 8 s on `initialize`, 8 s on `switchEffect`, backoff `600 * attempt` ms (lines 1336–1408). Watchdog **16 s** then “camera did not start” (lines 781–786). Surface wait is 8 frames plus 600 ms (lines 803–815).

Lifecycle: `paused` only marks the surface invalid (lines 491–495). `resumed` destroys and re-inits if this route is current, no overlay, and not within 1.5 s of the last reinit (lines 497–544). `detached` and `dispose` call `destroy` (lines 448–460, 838–855). `configChanges` includes orientation (`AndroidManifest.xml` line 19), so rotation does not recreate the activity; visual result **needs manual check**. An incoming call is a pause/resume and will re-init DeepAR. Overlay routes (login, match) must not start a second session; foundation capture sets `cameraPluginTookDevice` and try-on calls `deep_ar/camerax` `start_camera` with an 8 s timeout (lines 1275–1308). Non-Android resume gives up (lines 1297–1299). iOS license is a placeholder literal, not a key (`try_on_screen.dart` lines 211–213).

No face: save blocked with “Look at the camera.” More than one face: “One face at a time.” If the count callback never fires, only the visibility flag is used (lines 876–879).

Camera denied: permission screen snackbar; permanently denied offers settings (lines 62–73). Capture `CameraException` that mentions denial tells the user to use the gallery (`foundation_capture_screen.dart` lines 191–204). `android.hardware.camera` is `required=false` (`AndroidManifest.xml` lines 5–7), so a device with no camera can install; open failure falls through to the gallery hint. “Camera busy” is not a separate string; it lands in “Couldn't open the camera.”

On this debug launch, logcat (no tokens copied): surface wait 23:47:02.316, surface ready 23:47:03.256, init attempt 1/3 at 23:47:03.263, SDK **v5.6.20** at 23:47:03.627, **ready at 23:47:03.962** (~699 ms from init start, first attempt). No `FATAL EXCEPTION` and no ANR in that buffer (4,167 lines). Whether the mesh sat on the face was **not** seen.

### Foundation match

Sampling is on device in an isolate (`skin_sampler.dart` lines 1–29). ML Kit landmarks place five discs: forehead, both cheeks below the blush apple, jaw, glabella (lines 545–549 and the plan at 594+). Each patch sent is region, median r/g/b, pixel count, luminance stddev, region weight (`SkinPatchSample.toJson` lines 74–82). Optional illuminant and white reference. **The photo is not in the JSON** (`foundation_match_service.dart` lines 393–398). `debugRequestJson` holds that JSON in debug only (lines 305, 400–402).

Saved locally (SharedPreferences, derived fields only, not patches or the image) when the result passes the quality gate (lines 490–546): skin hex, undertone, depth, Monk scale, shade name/hex/keys, delta E, timestamp, reference hex. A retake or high expected error is not written (lines 508–516). Server persistence is whatever the website route does; this audit did not call it.

401 and other HTTP codes: see the API table. There is no 429 branch.

### Looks, bag, deep links

Add products and refill use `openAuthenticated`, so they depend on `WEB_BASE_URL` and a refreshable session. If the site is down, the browser shows the error. If the token is expired and refresh throws, the current (possibly dead) token is still placed in the fragment. If nobody is signed in, the public URL is used and the site shows its own sign-in (`web_bridge.dart` lines 79–86). Changing ngrok without a new `--dart-define` leaves the old host; the app does not probe it first.

### Security

- **Hardcoded secret material (values omitted):** `AppConfig.supabaseAnonKey` default, `lib/app/config/app_config.dart` lines 33–36. DeepAR Android license string, `lib/app/screens/try_on_screen.dart` lines 211–213. Both ship inside the APK. The service-role key was not found in the app.
- Default web URL is HTTPS. The app manifest does **not** set `usesCleartextTraffic`. A debug/LAN `http://` `WEB_BASE_URL` is blocked on release unless a network security config is added (`ENV_SETUP.md` says debug cleartext only). The public catalog page included at least one `http://` product image; those loads will fail on this manifest.
- Session tokens in SharedPreferences and in the browser fragment. Fragment is the right place versus a query string (not sent to the server), but it is still a bearer credential until the page strips it. `normalizeNext` is the open-redirect guard and is tested.
- `ALLOW_BACKUP` is on, so the prefs file can leave the device in a backup.
- `debugPrint` / `print` can include exception text (beauty profile, foundation response snippet, WebBridge refresh failure). This audit’s log excerpt did not include a raw JWT; do not assume future logs are clean.
- `debugShowCheckedModeBanner: false` (`app.dart` line 43). The installed build is still debuggable.
- OAuth scheme `io.supabase.flutter` is exported via the launcher activity (`exported=true`, lines 13–43). That is the Supabase Flutter default.

### Privacy (code trace)

Try-on camera video is not uploaded. The permission screen says so (`camera_permission_screen.dart` lines 157–158 and 186–187). Foundation match uploads colour numbers, not the photo; the match screen copy should be checked by the owner against that behaviour. Skin-check on Home opens the **website** and the dialog says that photo is sent (`home_screen.dart` lines 58–59). Beauty profile answers are written to `user_skin_profiles`. Look screenshots are stored locally and, on save, sent to Supabase storage/rows (try-on save path). Face-mesh channel is unused. ML Kit runs on device for sampling.

### Accessibility (code trace, not a device font/contrast pass)

Computed from `app_colors.dart` constants (WCAG relative luminance, not a screenshot):

| Pair | Ratio | AA normal text (4.5) |
| --- | --- | --- |
| `#1F1F1F` on `#FAF7F5` | 15.45 | Pass |
| `#8A8A8A` (`textMuted`) on `#FAF7F5` | 3.24 | Fail |
| `#9A9290` (`neutral500`) on `#FAF7F5` | 2.86 | Fail |
| White on `#C06C84` (primary buttons) | 3.67 | Fail for normal text |
| `#A0A0A0` on `#121212` | 7.16 | Pass |
| `#E38FA8` on `#121212` | 7.82 | Pass |

No `Semantics` widgets in `lib`. `uiautomator dump` after launch showed only the status bar (date, clock, 37% battery), so Flutter controls were not exposed. “Find my shade” chip height is 32 (`try_on_screen.dart` lines 3133–3136), under 48 dp. Camera Allow is 56 dp high (permission screen lines 205–207). No `textScaler` clamp, so system scaling applies, but the permission column uses `NeverScrollableScrollPhysics` (line 129) and several titles use fixed sizes (welcome 40, permission 28–32). Small screens and large text **need manual check**.

### Release readiness

- Permissions on the **installed** APK: `INTERNET`, `ACCESS_NETWORK_STATE`, `CAMERA`, `RECORD_AUDIO`, `READ_EXTERNAL_STORAGE`, `READ_MEDIA_IMAGES`, `WRITE_EXTERNAL_STORAGE` maxSdk 28, plus the AndroidX exported-receiver permission. The app manifest itself declares only storage read, media images, and camera (`AndroidManifest.xml` lines 2–4). `INTERNET` is also in the debug and profile manifests. `RECORD_AUDIO` and the write-storage cap are **not** in the app manifest; they were merged from a dependency (camera and/or the DeepAR AAR). This app does not record audio in Dart. `READ_MEDIA_IMAGES` does nothing on this API 30 phone.
- minSdk 24 / targetSdk 36 on the installed binary. Source uses `flutter.minSdkVersion` / `flutter.targetSdkVersion` (`build.gradle.kts` lines 28–29).
- Release signing: debug key. `minifyEnabled` / `shrinkResources` / ProGuard: **not set**.
- Installed debug APK pulled with `adb`: **289,048,654 bytes (289.0 MB)**. Release and profile APK/AAB sizes: **not measured**.
- Label `AR Makeup` (manifest line 9). `MaterialApp` title `AR Makeup Try-On` (`app.dart` line 42).
- Icon: `mipmap-*/ic_launcher.png` is the **default Flutter logo** (hdpi file opened).
- Debug banner hidden in source; installed package is still debuggable. `print` remains in the beauty-profile service.

## 4. Test table

Severity: P0 blocker, P1 should fix before a demo, P2 quality, P3 polish.

| ID | Feature | Scenario | Expected vs actual | Severity | Suggested fix | Verified by |
| --- | --- | --- | --- | --- | --- | --- |
| M-01 | Launch | Cold start, signed-in debug build already on device | Window `am start -W`: COLD, TotalTime **1675 ms**, WaitTime **1676 ms**. DeepAR log “ready” ~699 ms after init attempt 1. No crash in that log. | P2 | Profile this again on a current binary. 1675 ms is the activity window, not “effect on face”. | Ran on device (debug APK dated 28 Oct) |
| M-02 | Try-on camera | Effect sits on the face | Not judged. | — | Owner looks at lipstick, gloss, blush, eyeshadow, eyeliner, lashes, foundation. | Not verified (cannot see the camera) |
| M-03 | Highlighter | Chip and apply | Chip list excludes highlighter. Apply bails out and a snackbar says the effect does not include it. | P3 | Keep hidden until the `.deepar` file has a highlighter mesh. | Code trace |
| M-04 | Mascara | Separate from lashes | Chip is shown. Both use `EyeLashes`. Missing lash config draws nothing. | P2 | Hide mascara or point it at a real mesh. Confirm on device. | Code trace |
| M-05 | No face / two faces | Save | Copy blocks save: “Look at the camera.” / “One face at a time.” | P2 | Confirm the count callback fires on this OnePlus. | Code trace |
| M-06 | Camera denied | Permission screen | Permanently denied offers Settings. Capture offers gallery. | P2 | Walk both on the phone. | Code trace |
| M-07 | DeepAR hang | Init never returns | 8 s timeouts, 3 tries, 16 s watchdog sets failure UI. | P2 | Time a killed camera (busy) on device. | Code trace. This launch succeeded on attempt 1 |
| M-08 | Background / call / rotate | Lifecycle | Pause does not destroy. Resume re-inits if the try-on route is current. Rotation is in `configChanges`. | P1 | Manual: home, recents, incoming call, rotate, lock. Crash history in comments is SIGABRT if two inits overlap. | Code trace |
| M-09 | Foundation match | What is uploaded | JSON patches and optional illuminant. No photo field. | P1 | Owner confirms the result screen matches a known face. Endpoint was not called. | Code trace |
| M-10 | Foundation 401 / 429 / down | HTTP | 401 → sign in. Other codes → server string or generic. 429 not special. Down → 25 s then a sentence. No retry. | P2 | Map 429 to “wait and try again”. | Code trace |
| M-11 | Website reachability | Default Vercel host from the phone | ICMP ok. HTTP 200 from the phone for `/` and `/products`. Machine HEAD 1535 / 1555 / 878 ms. | — | None for reachability. Latency is the cold Vercel region, not the app. | Ran from phone and PC. Not an in-app call |
| M-12 | Add products / refill / bridge | Web down, expired token, tunnel change | Opens external browser with fragment tokens. No preflight. Expired refresh failure still sends the old session. Ephemeral host is only a debug log. | P1 | User-facing error if launch URL host does not answer. Don’t send an expired access token after a failed refresh. | Code trace. Not clicked |
| M-13 | Catalog offline | Supabase down after a successful cache | Disk copy kept. First launch with no file shows the shade error string. | P2 | Empty-state illustration. | Code trace |
| M-14 | Signed-in shop / orders / skin photo | Password flows | Skipped. No credentials in the conversation. Skin-check would upload a photo on the website; not opened. | — | Owner. | Not verified |
| M-15 | Analyzer | `flutter analyze` | 56 info, 0 warning, 0 error, exit 1. | P3 | Fix `print` and the deprecated calls before release. | Analyzer |
| M-16 | Unit tests | `flutter test` | 30 passed. | — | Add a widget test for the permission and match error states. | Ran |
| M-17 | Secrets in source | Release binary | Anon key and DeepAR license have source defaults. | P0 | `--dart-define` only, rotate anything that has been in git, no default secret. | Code trace |
| M-18 | Identity / signing | Play-style release | `com.example`, debug keystore, no shrinker, Flutter logo icon, 289 MB debug APK. | P0 | Real id, upload keystore, R8, custom icon, measure AAB. | Code trace + device package dump + icon file |
| M-19 | Memory | Try-on idle after DeepAR ready | PSS **479,133 KB**, graphics **146,848 KB**. Catalog screen not opened. | P1 | Profile build + `meminfo` on catalog vs try-on. Drop unused MediaPipe model. | Ran on device (debug) |
| M-20 | Frames | gfxinfo after launch and again after DeepAR ready | **4 frames, 100% janky**, 50th 200 ms, 90th 1000 ms. Count did not increase once DeepAR was ready. | — | Do not quote 100% as steady-state. Surface is outside this counter. Use a profile GPU trace. | Ran on device (debug). Steady-state **not measured** |
| M-21 | Contrast / semantics | Light theme muted text and buttons; TalkBack | Ratios 3.24 and 3.67 fail AA. Dump had no Flutter nodes. | P1 | Darken muted text, darken or enlarge primary buttons, add semantics. | Code trace (contrast math) + one UI dump |
| M-22 | Audio permission | Installed manifest | `RECORD_AUDIO` present, not declared by the app, no Dart recorder. | P2 | `tools:node="remove"` if the library merge is the source. Confirm which AAR adds it before removing. | Installed APK `aapt dump permissions` |
| M-23 | Cleartext images | Catalog `image_url` starting with `http://` | App does not allow cleartext. Those images fail. | P2 | Store HTTPS URLs on the website. | Code trace + one public page GET (status only used; image hosts not bulk-fetched) |
| M-24 | Bag prefetch | Signed-in cold start | Can insert “My Everyday Bag”. | P2 | Create the bag on first explicit open, not on every cold start. | Code trace. Insert **not confirmed** |
| M-25 | iOS | License and camera resume | Placeholder license. Non-Android camera rebind gives up. | P1 if iOS is in scope | Say Android-only, or ship a real key. | Code trace |

## 5. Performance numbers

| Metric | Value | Method | Build |
| --- | --- | --- | --- |
| Activity cold start | TotalTime 1675 ms, WaitTime 1676 ms, LaunchState COLD | `adb shell am start -W -n com.example.makeup_tryon/.MainActivity` after `am force-stop` | **Debug** APK last updated 28 Oct 2026. Not profile. |
| Time to first Flutter/DeepAR log | Refresh-session log 23:47:01.197; “Waiting for surface” 23:47:02.316; ready 23:47:03.962 | `adb logcat -d` after that start. Process start line for pid 29069 was not in the filtered slice, so this is **not** a full process-start-to-ready figure | Debug |
| DeepAR init + effect | ~699 ms, attempt 1/3, SDK v5.6.20 | Same log, init attempt timestamp to “DeepAR: ready” | Debug |
| APK size | 289,048,654 bytes | `adb pull` of `pm path` base.apk | Debug. Profile/release **not measured** |
| Effect asset | 910,304 bytes | File size of `assets/effects/makeup.deepar` | Source |
| gfxinfo | 4 frames, 4 janky (100%), 50th 200 ms, 90/95/99th 1000 ms, missed vsync 2, slow UI thread 4. Second dump identical after DeepAR ready | `dumpsys gfxinfo` | Debug. **Not a try-on frame rate** |
| meminfo, try-on path (DeepAR had logged ready) | TOTAL PSS 477,480 KB at ~12 s, then **479,133 KB**. Graphics 146,848 KB. Native heap 33,120 KB. Java heap 12,208 KB. 1 activity | `dumpsys meminfo` | Debug. Catalog and signed-out welcome **not measured** |
| Battery / thermal | Level 37, USB powered, temperature 29.8°C, thermal status 0 | `dumpsys battery`, `dumpsys thermalservice` | Not a load test |
| Website HEAD | 1535 ms `/`, 1555 ms `/products`, 878 ms `/terms`, all 200 | PC `HttpWebRequest` HEAD | Not in-app |
| Phone → website | ICMP avg 47.7 ms; HTTP 200 | `ping`, `curl -I` on device | Not in-app. TTFB **not measured** |

**Profile: not measured.** Signatures match, so an in-place install would have kept app data. `flutter run --profile -d bb55d6c2` ran Gradle `assembleProfile` for **585 s** and then failed. The Gradle daemon (pid 19036, `-Xmx2048m`) crashed: `hs_err_pid19036.log` says **insufficient memory**, native `mmap` of 354,418,688 bytes failed (`Out of Memory Error`, `os_windows.cpp`). The log’s host line is **7 GB RAM**. The debug APK on the phone was not replaced. Do not treat the debug PSS or the 100% jank line as a release number. Debug builds inflate size and CPU. The crash log was removed from `android/` after the cause was read so it is not left in the project.

## 6. Caching and speed plan (do not implement)

| Change | Where | Expected gain | Effort | Risk |
| --- | --- | --- | --- | --- |
| Ship a profile/release APK and re-measure cold start, PSS, and a GPU trace. Drop the unused face landmarker and MediaPipe dependency if Dart never calls it (3.8 MB model plus the AAR weight inside the 289 MB debug APK). | `build.gradle.kts` line 74, `FaceMeshRunner.kt`, `face_landmarker.task` | APK: not measured until a release build. Memory: the 479 MB figure is debug; expect a drop, amount **not measured**. | M | Removing MediaPipe is safe only while nothing invokes `makeup_tryon/face_mesh`. |
| Don’t block `runApp` on a 3 s session wait. Show welcome/shell immediately and swap when the session arrives. | `main.dart` lines 30 and 98–110 | Startup: up to 3 s on a slow auth restore. This launch’s window was 1.7 s, so the cap was not the whole story. Gain **not measured** separately. | S | Wrong first screen if the swap is late. |
| Page `product_shades` the way products are paged, and give lash/favourites/bag/notifications the same 8–12 s timeout. | `try_on_screen.dart` 1421–1467, favourites, bag, notifications | Catalog time **not measured**. Avoids one unbounded PostgREST response. | M | A short page can hide shades if the loop stops early. |
| Set `memCacheWidth` / `cacheWidth` on bag, looks, and auth images. Compress or resize `hero_model.png` (1.8 MB). | `makeup_bag_screen.dart`, `saved_looks_screen.dart` line 470, `auth_screen.dart` 574, `welcome_screen.dart` 79 | Decode memory **not measured**. Favourites already does this at 140 px. | S | Blurry thumbs if the width is too small. |
| Keep one in-flight shade fetch (products already dedupes). Don’t prefetch the bag (and its possible insert) before the bag screen. | `main.dart` 34–43, `products_cache.dart` 237–244 | Fewer calls at startup. Count **not measured**. | S | Bag screen waits on first open. |
| DeepAR: stay on `Resolution.medium` for this GPU, and avoid `setState` of the full tree on every face callback. Blur the panel only when it moves. | `try_on_screen.dart` 862–870, 1349, 3030–3032 | Frame time **not measured** (gfxinfo did not see the surface). | M | Makeup edges look softer at lower resolution. Re-init bugs if dispose timing changes. |
| Preload `makeup.deepar` off the first frame only after the surface exists (already the case). Cache the switched effect; don’t call `switchEffect` again on resume if the same controller survived. Today resume destroys the controller. | `try_on_screen.dart` 497–544 and 1370 | Resume cost **not measured**. The successful init was ~0.7 s plus ~0.9 s of surface wait. | M | The comment in that file says destroying on pause caused `EGL_BAD_NATIVE_WINDOW`. Don’t “optimize” that without a device pass. |
| If the website HEAD fails, show the snackbar instead of opening a dead host. One retry on foundation 429/503. | `web_bridge.dart` 142–166, `foundation_match_service.dart` 430–443 | Demo reliability, not fps. Latency of a failed tunnel **not measured**. | S | A false negative if HEAD is blocked but GET works. |

## 7. Evaluator assessment

**Strengths.** The phone reached the configured Vercel host (HTTP 200). Foundation matching is designed so the photo stays on device and only patch numbers are posted. Disk caches exist for products, shades, looks, favourites, and the bag, with sign-out clearing the user-owned ones. The auth-bridge `next` path rejects open redirects and that behaviour is unit-tested (30 tests passed). Highlighter is actually removed from the chip row, not only commented. DeepAR is kept alive under a nested navigator specifically to avoid a second camera. This debug launch initialized DeepAR on the first attempt without a fatal exception. Analyzer has no errors or warnings.

**Weaknesses.** The installed app is a 289 MB debuggable `com.example` build signed with the debug key, last updated 28 Oct, with the Flutter logo as the icon. About 479 MB PSS once DeepAR had started, on a debug build. Secrets have defaults in source. Several Supabase reads have no timeout. Mascara is a second chip on the lash mesh. Semantics are absent and two light-theme text pairs fail contrast math. `RECORD_AUDIO` is in the merged manifest. Steady-state frame time was not measurable with `gfxinfo`. Profile numbers are missing because `assembleProfile` ran out of memory after 585 s and did not install. The binary that was timed may not match today’s source.

**Likely questions.** Does the camera upload video? (Try-on path: no. Skin-check on the website: yes, and the dialog says so. Foundation: numbers, not the photo.) Why is highlighter gone? (One `.deepar` file, chip filtered.) Why is the APK huge and memory ~480 MB? (Debug build, DeepAR AAR 38 MB, unused MediaPipe model, high resolution, graphics ~147 MB; release not built.) Can it run offline? (Cached catalog and shades yes; match and shop no.) Is `com.example` and the debug keystore acceptable for hand-in? (No.) Was the effect checked on a face? (No.)

## 8. Needs manual check by the owner

- Look at the live camera: lipstick, gloss, blush, eyeshadow, eyeliner, lashes, foundation. Intensity at the default slider and at 0% and 100%.
- Mascara chip: does anything change, or is it a duplicate of lashes?
- Highlighter stays hidden, including from the bag.
- No face, two faces, face leaves the frame, glasses, low light.
- Deny camera, permanently deny, then Settings. Pull the camera with another app (busy) and come back.
- Home, recents, incoming call, rotate, lock/unlock. Confirm no black screen and no crash.
- Foundation capture and a real match while signed in (this audit did not POST). Confirm the saved shade is the one you expect and that no photo appears in the website logs.
- Add products, refill, shop, orders, skin check, with the website online and with the phone in airplane mode.
- Expired session: sign out on the website and use a bridge link.
- TalkBack, largest system font, a small phone, light and dark theme, especially muted grey and white-on-rose buttons.
- Confirm `RECORD_AUDIO` is acceptable. Replace the Flutter logo and `com.example` before any hand-in build.

## 9. Ranked roadmap

**Must-fix**

1. Remove default anon key and DeepAR license from source (`app_config.dart` 33–36, `try_on_screen.dart` 211–213). Rotate anything already committed. Pass them with `--dart-define`.
2. New `applicationId`, release keystore, R8/shrink. The debug signing block is `build.gradle.kts` 34–39.
3. Replace the Flutter logo (`mipmap-*/ic_launcher.png`) and decide the store name (`AR Makeup` vs `AR Makeup Try-On`).
4. Re-run this sheet on a **profile** build of **current** source once the machine has free RAM (this attempt died at ~7 GB). The numbers in section 5 are a 28 Oct debug APK.

**Quick wins**

5. Delete unused `go_router`, and drop `flutter_riverpod` unless a provider is about to appear. `cupertino_icons` if still unused.
6. Timeouts on lash configs, favourites, bag, notifications, and `saved_looks_screen.dart` line 470.
7. `memCacheWidth` on the other `CachedNetworkImage`s. Smaller `hero_model.png`.
8. Replace `print` in `beauty_profile_service.dart`.
9. Don’t prefetch-insert the makeup bag at startup (`makeup_bag_cache.dart` 48–55).
10. 429 copy on foundation match.

**High impact**

11. Remove unused `FaceMeshRunner`, the `.task` model, and the MediaPipe dependency after confirming the channel is dead. Re-measure APK size.
12. Stop `setState` of the whole try-on tree on face ticks; lower DeepAR resolution only after a profile GPU trace.
13. Page `product_shades`.
14. Contrast and semantics (section 3). “Find my shade” tap height 32 → at least 48.
15. Strip `RECORD_AUDIO` if the merge allows it.
16. If refresh fails, open the public URL instead of an expired fragment (`web_bridge.dart` 110–114).

**Polish**

17. Hide mascara or give it its own mesh.
18. User-visible message when `WEB_BASE_URL` is a dead tunnel (today only `debugPrint`).
19. Widget tests for permission denied and foundation error states.
20. `flutter pub outdated` when a profile build is not holding the Flutter lock. Not run in this pass.
21. Android licenses: `flutter doctor --android-licenses` (toolchain, not the app).

Profile compile status: **failed** after 585 s. Gradle daemon out of memory on a 7 GB host (`-Xmx2048m`, native mmap of ~338 MB failed). No profile APK was installed. Do not mix a future profile run with the debug table above.
