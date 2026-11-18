# Try-on face edge cases

Evidence labels: **code trace**, **unit test**, **needs manual check**. This pass did not run the app on a phone. Nothing below is an on-device result.

DeepAR init, pause/resume/dispose/re-init, resolution, the overlay navigator, camera handover, applicationId, signing, pubspec, and the foundation-match request body were not changed.

## A. Try-on (`lib/app/screens/try_on_screen.dart`)

### 1. What is stored, and what the UI shows

Callbacks are still assigned only in `_bindFaceVisibility` (`try_on_screen.dart:880` visibility, `:893` count). Code trace.

| Callback | Stored | UI |
| --- | --- | --- |
| `onFaceVisibilityChanged` | `_faceVisible`, then `reduceFaceGuidance` | Banner from `FaceGuidanceState.bannerMessage` (`try_on_screen.dart:2960`) |
| `onFaceCountChanged` | `_trackedFaceCount`, then the same helper with `countEvent: true` | Multi-face line only when that count is fresh |

| Situation | Banner | Save |
| --- | --- | --- |
| No face yet (count never needed) | "No face found. Face the camera in good light." | Blocked. Unit test. |
| Exactly one, or visible with no fresh count | Hidden | Allowed immediately. Unit test. |
| Two or more, count fresh | Same block immediately; banner after 400 ms so it does not flash | Blocked. Unit test. |
| Face lost | Hidden for 400 ms, then the no-face line | Allowed during that 400 ms, then blocked. Unit test. |

Strings live in `lib/app/utils/face_guidance.dart:26` and `:29`. The banner is a `Semantics` live region (`try_on_screen.dart:2963`) on a dark scrim (`:2974`) with white text. `AppColors.watch` already runs in `build`, and the scrim darkens in dark mode. Code trace. Contrast on a real preview: **needs manual check**.

### 2. Stale count, missing count, flicker

Before this change the count was kept until the next callback and the banner updated on every callback. Code trace of the old `_faceBlockReason`.

Now:

- Count is sent only when it changes (`DeepArPlugin.java:67`). iOS never sends `on_face_count` (`DeepArCamera.swift:317` is visibility only; `deep_ar_platform_handler.dart:29`).
- A face loss sets `countFresh = false` (`face_guidance.dart:111`). The old number is kept but not used if the face comes back before a new count. Unit test.
- If the count callback never fires, `faceCount` stays null and visibility alone decides. Unit test. That matches iOS.
- 0/1 flaps inside 400 ms do not bring the no-face banner back. Unit test. Grace and debounce are both 400 ms (`face_guidance.dart:21`, `:24`).

### 3. How many faces get makeup

No `maxFaces` (or equivalent) anywhere in this repo. Code trace. Android counts every `FaceData` with `faceDetected` (`DeepArPlugin.java:63`). The effect is `switchEffect('assets/effects/makeup.deepar')` with no face index (`try_on_screen.dart:1430`). Which face is meshed is the SDK default. **Unknown. Needs manual check.**

`takeScreenshot` is the whole frame (`try_on_screen.dart:1925`). A second person would be in a saved still if Save were allowed. Save is refused once a fresh count is above 1 (`try_on_screen.dart:2375`, `:2584`). iOS has no count, so two faces there are not blocked. Gap: major on iOS.

### 4. What is blocked

| Action | Gate |
| --- | --- |
| Save look | `_faceBlockReason()` before the dialog and again before the write (`:2584`, `:2375`). Snack is the one-line reason. |
| Share | No Share control on try-on. Saved-looks share is a stored preview, not a live face. Not gated. |
| Intensity | Slider `onChanged` (`:3744`) does not read the face. Allowed. |
| Category chips | `_buildCategoryTab` (`:3970`) does not read the face. Allowed. |
| Foundation match | Not gated. |
| Camera flip | Try-on never calls `flipCamera`. Nothing to block. |
| Hold / Compare stills | `_takeShot` (`:1925`) has no face gate. Still allowed. |

A screenshot cannot be saved through Save while the gate is closed. It can be saved during the 400 ms grace, and via Hold or Compare. Code trace.

### 5. Guidance copy and TalkBack

Try-on copy is only the two strings in `face_guidance.dart`. Foundation keeps its own lines (it measures size, angle, and light; try-on does not). The try-on banner is a live region. Whether TalkBack announces it on device: **needs manual check**.

### 6. Non-human faces

Code knows: a "face" is DeepAR `faceVisibilityChanged` / `faceDetected`, or ML Kit `FaceDetector`. There is no species check, no animal label, and no screen/poster label. Whether a cat, dog, cartoon, poster, photo-on-a-screen, or mask sets those callbacks is **unknown. Needs manual check.** The new copy does not claim animal detection.

### 7. Partial and occluded faces

Try-on has no size, cutoff, yaw, hijab, veil, niqab, mask, sunglasses, or hand handling. Makeup is a mesh colour write with no occlusion test. Whether lipstick or eyeshadow lands off the feature is **unknown. Needs manual check.**

## B. Foundation (ML Kit)

Live gate: `foundation_capture_screen.dart` `_interpretFaces` (`:424`). Still/gallery: `skin_sampler.dart` `sample` (`:211`).

Several faces are **not** the largest face. Both paths reject when the list length is not 1 (`foundation_capture_screen.dart:425`, `skin_sampler.dart:275`) and use `faces.first` only after that check. Code trace.

| Case | Capture (live) | Still / gallery | Message |
| --- | --- | --- | --- |
| Zero | Shutter stays off | Throws before patches | Live: "Move your face into the oval." (`:429`). Camera still: "No face was found in that photo." Gallery: "We could not find a face in this photo. Try a clear, front-facing photo." (`skin_sampler.dart:264`) |
| Several | Shutter stays off | Throws before patches | Live: "One face at a time. Please retake." (`:426`). Still/gallery title "One face at a time." hint "Please retake with only one face in the photo." (`:275`) |
| Very small | Width under 0.18 after `minFaceSize` 0.12 | Width under 0.18 (`skin_sampler.dart:142`, `:306`) after `minFaceSize` 0.15 (`:246`) | Live: "Move closer." Below the detector floor this looks like zero faces. |
| Off-centre | Centre must sit in the oval (`:443`) | Not checked | Live: "Move your face into the oval." Gallery can pass if the face is large and frontal. |
| Tilted | Yaw above 22° or roll above 30° (`:439`) | Same thresholds (`:313`, `:321`). A null angle is allowed. | Live: "Face the camera." Still: "Your head is turned too far to one side." / "That photo looks tilted." |
| Closed eyes | Not read. Classification mode is off (`:399`). | Not read. | No eye message. |
| Low-confidence landmarks | Not scored | Missing landmarks fall back to the box (`_planPatches`). If the contour is missing and fewer than 3 patches plan, refuse (`:341`). | "Not enough of your face is visible to measure." |
| Low light | Mean, blown, and left/right gates (`:296`) | Not measured on the still | "Too dark. Face a window." / "Too bright. Step out of direct sun." / "This side is brighter. Turn to face the light." |

`matchSample` returns before `POST` when patches are fewer than 3 (`foundation_match_service.dart:385`). `sample` throws on no face, several faces, and the quality gates above, so those paths never build patches. Code trace. `matchFromSkinHex` posts a stored hex, not patches (`:415`). Not changed.

The capture status line is a live region on a dark scrim (`foundation_capture_screen.dart` status text). TalkBack on device: **needs manual check**.

## C. Scenario table

| Scenario | Try-on | Foundation | User-visible message | Gap | Evidence |
| --- | --- | --- | --- | --- | --- |
| No face at start | Banner and Save blocked | Shutter off | Try-on: no-face line. Capture: "Move your face into the oval." | none | code trace `face_guidance.dart:51`, `foundation_capture_screen.dart:429`; unit test |
| Face leaves frame | 400 ms grace, then no-face block | Next frame: empty → oval line | No-face line after grace. Capture: oval line | minor (400 ms Save still open) | unit test; code trace `face_guidance.dart:24` |
| Two faces | Save blocked; banner after 400 ms. iOS count never arrives, so Save stays open | Reject, not largest. Retake | "One face at a time, please." / "One face at a time. Please retake." | major on iOS try-on | unit test; code trace `DeepArCamera.swift:317`, `skin_sampler.dart:275` |
| Three or more | Same as two | Same reject | Same | major on iOS try-on | code trace (count > 1) |
| Partly outside frame | No cutoff test. Makeup mesh unchanged | Oval on live; still only checks the box is inside the image | Live: oval line if the centre is out | major for makeup placement | code trace `try_on_screen.dart:1430`; needs manual check |
| Very far | Not measured | Under 0.18 width, or invisible to `minFaceSize` | "Move closer." or the no-face line | minor (tiny faces look like no face) | code trace `skin_sampler.dart:142` |
| Very close | Not measured | No "move back" gate | None on try-on | minor | code trace |
| Strong side profile | Not measured | Yaw/roll gates | "Face the camera." / turned-head line | none on foundation; major on try-on (no angle) | code trace `foundation_capture_screen.dart:439` |
| Low light | Not measured | Live light gates. Three detector failures fall through to written hints and can still shoot; the still is sampled afterwards | "Too dark. Face a window." | minor | code trace `foundation_capture_screen.dart:296` |
| Glasses | Not detected | Not detected | None | major | code trace (no branch); needs manual check |
| Hijab or veil | Not detected | Contour/landmark fallback only | "Not enough of your face is visible to measure." only if the plan is short | major | code trace `skin_sampler.dart:341`; needs manual check |
| Mask | Not detected | Same | Same, or a normal match if the detector still returns a face | major | code trace; needs manual check |
| Hand on face | Not detected | Same | Same | major | code trace; needs manual check |
| Cat or dog | Treated as a face if DeepAR says visible | Treated as a face if ML Kit returns one | No animal wording | major | code trace (no species field); needs manual check |
| Cartoon or poster | Same | Same | Same | major | needs manual check |
| Photo on a screen | Same | Same | Same | major | needs manual check |
| Back camera, no face | No flip control. Android default lens is front (`CameraXHandler.java:51`) | Capture asks for the front lens | No-face / oval line if a camera is open and empty | minor (cannot flip) | code trace; needs manual check |
| Count callback never fires | Visibility only. No multi-face line | n/a (ML Kit returns a list every check) | No-face line, or nothing when visible | major for two faces on iOS | unit test; code trace `deep_ar_platform_handler.dart:29` |

## What was fixed

- `lib/app/utils/face_guidance.dart`: pure map from visibility, count, and timestamps to a banner and a Save reason. 400 ms debounce. 400 ms grace after a loss. Stale counts ignored. Missing count falls back to visibility.
- `try_on_screen.dart`: the existing `setState` in the two callbacks calls the helper. Callback registration is unchanged. Banner scrim, white text, live region. Save uses the helper reason. Category chips and intensity are not blocked.
- Foundation copy: several faces ask for a retake and still reject (largest is not used). Gallery with no face uses the gallery sentence. Capture status is a live region on a scrim.
- `test/face_guidance_test.dart`. No try-on widget test: `TryOnScreen` builds `DeepArController` and `DeepArPreview` in the first frame, and DeepAR was not mocked.

## What was not changed, and why

| Item | Why | Effort |
| --- | --- | --- |
| iOS face count | Needs a Swift callback. Forbidden native change. | L |
| Which face is meshed, `maxFaces` | Would be a DeepAR start/effect change. | L |
| Distance, "move back", angle, light on try-on | Not measured. Copy would be false. | L (new signal) |
| Animal, cartoon, poster, screen, glasses, mask, hand | No classifier in the app. A model would be a new package or native code. | L |
| Block Hold / Compare stills | Request named Save and Share only. | S |
| Share button | Try-on has no Share control. | S if one is added later |
| Camera flip | No flip control on try-on. Not added. | S |
| Pick the largest face | Current code rejects. Kept, and the copy says so. | S |
| POST body / when patches are refused | Already refused before POST. Message only. | — |
| DeepAR lifecycle, resolution, overlay navigator, camera handover | Out of scope. | — |

## Manual check

| Scenario | What to do | What should happen |
| --- | --- | --- |
| No face at start | Open try-on in an empty room | Banner: "No face found. Face the camera in good light." Save snack shows that line. Chips and intensity still work. |
| One face | Step into frame | Banner hides and Save works on that frame, without waiting. |
| Face leaves | Step out, wait under half a second, step back | Banner does not flash. Then stay out for about half a second: banner and Save block return. |
| Two people, Android | Both in frame | Save snack: "One face at a time, please." Banner follows within about half a second. Makeup target: record which face is painted. |
| Two people, iOS | Both in frame | Expect no multi-face line (no count callback). Record it. |
| Flap in and out | Move through the edge quickly | Banner stays steady. |
| Foundation, two faces | Live camera, then a gallery photo with two people | "One face at a time. Please retake." No match request in the network log. |
| Gallery, no face | Pick a photo of a room | "We could not find a face in this photo. Try a clear, front-facing photo." |
| Gallery, one clear face | Front-facing photo | Match runs. |
| Cat, poster, phone screen, mask, hijab, hand, glasses, profile, dark room | One try each on try-on and on foundation capture | Record whether a face is announced. The app has no special line for these. |
| TalkBack | Focus the try-on banner and the capture status | Each change is spoken once. White text on the scrim is readable. |
