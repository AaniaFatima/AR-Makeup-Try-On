# Phone checklist

This list was not run on a device. No camera session was started from the audit pass that added it. Tick each line on an Android phone.

1. Cold start. The app opens on the welcome screen.
2. Deny the camera, then allow it from the permission screen. Live try-on shows a face, not a black view.
3. Apply a lipstick and move the intensity slider. The colour on the face changes.
4. Save a look. Turn on airplane mode. Open the saved-looks gallery. The look is still there.
5. Sign in. Open foundation match. Before the shutter, the screen says the photo is measured on the phone and is not uploaded, and that the reading can be saved to the profile. The same sentence is on the camera screen. Privacy opens the website `/privacy` page without putting a token in the address bar.
6. In a dark room, the light gate stays up and does not offer a shade.
7. In daylight, take the three frames. A result appears, or a clear line that no foundation shades are in the catalog yet.
8. When a shade is shown, Try in AR returns to the camera with that shade.
9. Buy opens the site on `/products/{product_key}` (a shade chip may be preselected with `?shade=`). It must not be the collection page `/products?product=`.
10. Makeup bag → Add products opens `/makeup-bag?add=1` on the same host as the rest of the app (`WEB_BASE_URL`, default `https://ar-makeup-web.vercel.app`). You are still signed in.
11. Refill / product details opens `/products/{product_key}`.
12. Sign out, then sign in as someone else. The first account's looks are gone, and the previous skin-tone hex is not shown on the new profile.
