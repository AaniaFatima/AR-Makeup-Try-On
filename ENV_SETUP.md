# Environment setup

Every environment-dependent value in the app lives in
[`lib/app/config/app_config.dart`](lib/app/config/app_config.dart). Nothing is
hardcoded at a call-site any more, so pointing the app at a different website or
Supabase project is a build-time flag, not a code edit.

Override any of them with `--dart-define`:

| Define              | Meaning                                        |
| ------------------- | ---------------------------------------------- |
| `WEB_BASE_URL`      | Root of the Next.js companion site (no trailing slash) |
| `SUPABASE_URL`      | Supabase project URL                           |
| `SUPABASE_ANON_KEY` | Supabase anon key                              |

The defaults baked into `AppConfig` are the current dev Supabase project and the
ngrok tunnel — fine for day-to-day work, **not** fine for a demo or a release.

---

## Why `WEB_BASE_URL` matters

The app opens the website for the e-commerce and skin-analysis modules. `localhost`
does not mean the same thing on a phone as it does on your PC, so the correct
value depends on where the app is running:

| Running on                | `WEB_BASE_URL`                            | Notes |
| ------------------------- | ----------------------------------------- | ----- |
| Android emulator          | `http://10.0.2.2:3000`                    | `10.0.2.2` is the emulator's alias for the host machine's `127.0.0.1` |
| iOS simulator             | `http://localhost:3000`                   | Shares the host's network stack |
| Physical phone, same Wi-Fi | `http://192.168.x.x:3000`                | Your PC's LAN IP — run `ipconfig` to find it |
| Physical phone, any network | `https://<id>.ngrok-free.dev`           | Needed when the phone can't reach your LAN |
| Production                | `https://<your-domain>`                   | The real thing |

Start the website first (`npm run dev` in `ar-makeup-web`), then launch the app.

For a LAN IP or a tunnel, Next.js must also listen on all interfaces:

```bash
npm run dev -- -H 0.0.0.0
```

### Plain-HTTP hosts on Android

Android blocks cleartext HTTP by default. `http://10.0.2.2:3000` and
`http://192.168.x.x:3000` therefore only work on a debug build (Flutter's debug
manifest permits cleartext). If you need HTTP on a release build, use an ngrok
`https://` tunnel instead of editing the network security config.

### The tunnel warning

`AppConfig.isEphemeralWebHost` returns `true` for ngrok, Cloudflare, localtunnel,
`localhost`, `10.0.2.2` and `192.168.*`. When it does, `WebBridge` prints a
one-line warning to the debug console every time it opens a link. That warning
exists so a dead tunnel is caught before a viva, not during one — ngrok URLs
change every restart on the free tier.

---

## Ready-made commands

### Android emulator against a local website

```bash
flutter run --dart-define=WEB_BASE_URL=http://10.0.2.2:3000
```

### Physical device against a local website

Replace the IP with your PC's LAN address:

```bash
flutter run --dart-define=WEB_BASE_URL=http://192.168.1.5:3000
```

### Physical device through an ngrok tunnel

```bash
flutter run --dart-define=WEB_BASE_URL=https://your-id.ngrok-free.dev
```

### Release build for the demo / submission

Pass all three so the APK is not tied to anything on your machine:

```bash
flutter build apk --release --dart-define=WEB_BASE_URL=https://your-domain.com --dart-define=SUPABASE_URL=https://xxxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJhbGci...
```

---

## VS Code

[`.vscode/launch.json`](.vscode/launch.json) has one entry per scenario above, so
you can pick the target from the Run and Debug dropdown instead of retyping
defines. Edit the LAN IP and the ngrok / production URLs in that file once.

---

## A note on the anon key

The Supabase **anon key is meant to be public** — it identifies the project, it
does not grant access. Row Level Security is what actually protects the data, so
every table the app touches must have policies on it. See
[`../../ar-makeup-web/db/README.md`](../../ar-makeup-web/db/README.md).

The **service-role key bypasses RLS entirely** and must never appear in this
Flutter project — not in `AppConfig`, not in a `--dart-define`, not in a
committed file. It belongs only in the website's server-side environment.

---

## Related

- [`lib/app/config/app_config.dart`](lib/app/config/app_config.dart) — the config itself
- [`lib/app/services/web_bridge.dart`](lib/app/services/web_bridge.dart) — how the session is handed to the browser
- `ar-makeup-web/src/app/auth/bridge/page.tsx` — the receiving end
- `flutter test` — covers URL assembly and the open-redirect guard
