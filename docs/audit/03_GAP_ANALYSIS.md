# Gap analysis — what an FYP evaluator can fairly expect

The app is an Android AR makeup try-on, a foundation shade matcher, and a handoff into a Next.js shop. Expectations below are for that product, checked against `d:\FYP\AR-Makeup-Try-On` on 16 Oct 2026. “Present” means the phone implements it. It does not mean a face was put in front of a camera during this audit.

## Core functionality

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Live virtual makeup on the front camera | Present on Android code. Broken on iOS | Nine categories `try_on_screen.dart` 95–105. Effect `assets/effects/makeup.deepar`. Android license literal at 201–202. iOS placeholder at 203. Debug APK compiled. Camera not run |
| Several makeup categories with real shades | Present | Shades load from `product_shades` (`try_on_screen.dart` 1249–1267). Category enum at 95–105 |
| Intensity the user can see | Present | Slider value mapped per category, lines 107–156 |
| Save a look and put it back on the face | Present | Gallery and re-apply in `saved_looks_screen.dart`. Offline queue `pending_looks_queue.dart` |
| Foundation shade from the user’s face | Present in the client | ML Kit patches `skin_sampler.dart` 199–247. `POST /api/foundation-match` `foundation_match_service.dart` 378–404. Sign-in gate `foundation_match_screen.dart` 135–139. Light gate `foundation_capture_screen.dart`. Short result 748–875 |
| Enough real foundation shades to demonstrate a match | Partial. Unverified in the database | `ar-makeup-web/db/015_foundation_common_shades.sql` lines 4–7: paste in the SQL editor, not applied automatically. The phone ranks whatever the API returns. Empty catalog copy is at `foundation_match_screen.dart` 791–795 |
| A wrong or dark photo is refused | Present in code | Retake when quality is not ok or spread is above 5 (`foundation_match_screen.dart` 364–373, 708–744). Not filmed |
| Matched shade applied back onto the AR face | Present in code | `try_on_screen.dart` 1063–1078 and CameraX `start_camera` at 1146–1148. Not run on a device |
| Shop the shade or the look | Partial | Buy-this-look opens `/looks/{id}?action=buy` (`try_on_screen.dart` 3524–3527). Matched-shade Buy opens a query the products page ignores. Cart and Stripe stay on the website on purpose (3481–3489) |

## Feature depth

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Before/after or a still compare | Missing | No compare control found in `try_on_screen.dart` |
| Record a short try-on clip | Missing | Save path is a still |
| Shade search or brand filter inside AR | Partial | Bag filter only (`_showOnlyMyBag`, line 208). No text search |
| Explanation of the match a viva can defend | Present | “How this was measured” and `shownUndertone` (`foundation_match_screen.dart` 79–85, 854–868) |
| User correction of a bad match | Present | Votes at 829–843. Copy says the vote does not change today’s shade (831–833) |
| White balance when the room is warm | Partial | Optional paper path (250–255). Default calibration string is Approximate (`foundation_match_service.dart` 221–222) |

## UX

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| A first screen that says what the app is | Present | `welcome_screen.dart` |
| Permission explained, including permanent deny | Partial | Open Settings exists (`camera_permission_screen.dart` 59–66). “Maybe Later” stays on the gate (214–229) |
| Loading, empty, and error states on the main flows | Present | Try-on loading and error (2192–2221). Foundation stages. Bag empty state (`makeup_bag_screen.dart` 144–146) |
| One visual system, including dark mode | Partial | `AppColors` switches. `MaterialApp` theme is empty and has no `themeMode` (`app.dart` 43–46) |
| No controls that pretend to work | Missing that bar | Profile notifications switch (`profile_screen.dart` 1156–1162). Language and 2FA are labelled soon, which is honest. The profile switch is not |
| Matched product opens on the site | Missing | Buy URL issue in report 02 |

## Personalization

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Skin questionnaire | Present | `beauty_profile_questionnaire_screen.dart` |
| Measured tone changes try-on order | Present | `_loadMeasuredSkinTone` and delta-E sort (`try_on_screen.dart` 327–336, 883–911) |
| Finish preference sent with the match | Present | `foundation_match_screen.dart` line 259 |
| Bag used as shades I own | Present | Filter on the try-on sheet |
| Recommendations that survive a restart | Partial | Foundation hex is in SharedPreferences (`foundation_match_service.dart` 495–506). Beauty profile cache is memory-only (`beauty_profile_service.dart` 160–172). A failed GET looks like no profile |

## Auth and profile

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Email account | Present | `auth_screen.dart` |
| Guest can try AR before signing up | Present | Welcome Get Started (`welcome_screen.dart` 198–206). Foundation match still requires sign-in |
| Google | Partial | Android redirect filter exists. iOS URL scheme does not. Live OAuth unverified |
| Edit name and photo | Present | `edit_profile_screen.dart` |
| Password change and account delete | Present | `privacy_security_screen.dart` 24–84. Live RPC unverified |
| Session restore | Present | `main.dart` 30–53 |
| Sign-out drops the previous user’s looks | Partial | `clear()` is called (`main.dart` 55–58). An in-flight prefetch can write the old list back (`looks_cache.dart` 71–174) |

## Data persistence

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Looks offline | Present | `looks_cache.dart` |
| Shades offline | Present | `product_shades_cache.json` via `try_on_screen.dart` 464–467 |
| Bag offline | Present | `makeup_bag_cache.dart` |
| Favourites offline | Missing | `favourites_cache.dart` has no disk file |
| Pending look upload | Present | `pending_looks_queue.dart` |
| Product names and prices offline | Present | `products_cache.dart`. No full catalog screen |

## Backend integration

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| One shade authority shared with the website | Present | `foundation_match_service.dart` 1–8 and 292–297 |
| Authenticated browser handoff | Present | `web_bridge.dart`. URL tests passed |
| Beauty profile API | Present | Calls `/api/beauty-profile`. The route exists on the web |
| Direct Supabase for looks, shades, bag, favourites | Present | Cache files name those tables |
| Config not hardcoded at call sites | Partial | `AppConfig` is the rule. `makeup_bag_screen.dart` line 8 breaks it |
| About 30 Maybelline shades | Unverified | SQL file says paste-only |

## Error handling

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Matcher network, 401, and bad JSON | Present | `foundation_match_service.dart` 430–487 |
| Camera open failure offers gallery | Present | `foundation_capture_screen.dart` 149–173 |
| DeepAR init failure can be retried | Present | Three attempts then error view (`try_on_screen.dart` 1181–1244) |
| Beauty profile errors | Partial | Swallowed into an empty model (`beauty_profile_service.dart` 56–59) |
| Auth errors shown to the user | Present | `auth_screen.dart` 179–180 |

## Performance

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Lists do not block the first frame on the network | Present | Prefetch in `main.dart` 34–43. Splash removed at line 88 |
| Pixel work off the UI isolate | Present in comments and structure | `skin_sampler.dart` 23–29. Not profiled |
| Decode size capped | Present | `_maxDecodeEdge = 1440` (`skin_sampler.dart` 193) |
| Frame rate of live AR | Unverified | `Resolution.high` at `try_on_screen.dart` 1194 |

## Security and privacy

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Match photo is not uploaded | Present | Body is patches (`foundation_match_service.dart` 393–399). Camera files deleted after the run (`foundation_match_screen.dart` 305–310) |
| Shared links do not carry tokens | Present | `web_bridge.dart` 34–40. Tests passed |
| Open redirect blocked | Present | `normalizeNext` lines 134–139 |
| Account deletion | Present in the client | RPC name only. Policy unverified |
| Secrets | Partial | Anon key is a documented public default (`app_config.dart` 31–36). DeepAR Android license is a source literal (`try_on_screen.dart` 201–202). No service-role key found in `lib/` |
| Saved look images | Partial | Stills go to Storage and are shared by public URL (`saved_looks_screen.dart` 498–508). The camera gate says video never leaves the device (`camera_permission_screen.dart` 156–157). That sentence is about the stream, not the saved still, and the screen does not say so |
| Privacy policy in the app | Missing | No mobile link to `/privacy`. Settings help opens `/support` only |
| Release signing | Missing | Debug keystore (`build.gradle.kts` 34–39) |
| Row Level Security | Unverified | Not inspected in this mobile audit |

## Accessibility

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Labels on the main camera controls | Missing | `_TopBarButton` has no semantics (`try_on_screen.dart` 3319–3347) |
| 48px targets on that bar | Missing | 42 by 42 (lines 3332–3333) |
| Text scaling | Partial | Scaling is not disabled. Welcome body cannot scroll (`welcome_screen.dart` 108–109) |
| Text colors on cards | Present | `AppColors` ramp. Camera-overlay contrast unverified |

## Testing

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Unit tests for matcher, delta E, caches | Missing | 16 URL tests passed. Nothing else |
| Widget tests | Missing | No widget tests under `test/` |
| Device notes | Missing | Camera, OAuth, and match were not run |
| Analyzer and debug build | Present with noise | 0 errors, 5 warnings, 56 info. Debug APK built |

## Documentation

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| README a marker can follow | Missing | Flutter template |
| How to point the phone at the website | Partial | `ENV_SETUP.md` is useful and still says the default host is ngrok (lines 16–17). Code default is Vercel |
| Architecture note that matches the code | Partial | `GEMINI_PROJECT_CONTEXT.md` is strong on DeepAR and stale on ML Kit and foundation match |
| Optimization write-up | Present | `OPTIMIZATION_SUMMARY.md`. Not re-measured |

## Release readiness

| Expectation | Verdict | Evidence |
| --- | --- | --- |
| Debug Android build | Present | `app-debug.apk` built in this audit |
| Installable demo identity | Missing | `com.example.makeup_tryon`, debug signing |
| Builds on a second machine | Missing | Absolute Pub cache path `pubspec.yaml` 59–60 |
| iOS | Missing | Placeholder license, no privacy strings, no URL scheme |
| Store listing assets | Unverified | Not opened |

## Half-finished or unused

| Piece | Verdict | Evidence |
| --- | --- | --- |
| MediaPipe face mesh | Unused by the running app | `MainActivity.kt` channel, no Dart caller |
| CSV files under `lib/` | Unused copies | Not loaded |
| `color_utils.dart` | Superseded by `skin_color.dart` | No callers |
| `go_router`, Riverpod | Declared, unused | `pubspec.yaml` 38–39 |
| Language, notifications, 2FA | Stubs | Settings and privacy screens |
| AAR metadata check disabled | Build workaround | `build.gradle.kts` 57–60. Debug build still succeeded |

## Questions this app cannot answer well

1. Was the 30-shade Fit Me list actually loaded? The SQL file says it is a manual paste. The phone cannot show a shade count.
2. How close is a match on a real face, in daylight and in a warm room? The UI explains delta E. This audit did not capture a face. There is no phone evaluation log in this repo.
3. Show the product I was just matched to. Buy opens the catalog, not `/products/{product_key}`.
4. Does it run on an iPhone? The iOS license is a placeholder and `Info.plist` has no camera usage string.
5. Where are the tests for sampling and ranking? Only URL tests exist, and they passed.
6. What is the privacy story for a saved look? The camera screen talks about video. Saved stills are uploaded and given a public URL.
7. Can another PC build this? Not without that Pub-cache path and `android/app/libs/deepar.aar`.
8. Why is a face-landmarker model in the APK? Nothing in Dart calls it.
9. Is dark mode finished? The settings switch changes `AppColors`. `MaterialApp` does not.
10. Is the notifications switch on? It defaults to on and saves nothing.
