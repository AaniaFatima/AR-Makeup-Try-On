/// Central configuration for every environment-dependent value in the app.
///
/// Nothing that changes between machines / demos / deployments should be
/// hardcoded at a call-site any more — put it here and override it at build
/// time with `--dart-define`:
///
/// ```
/// flutter run \
///   --dart-define=WEB_BASE_URL=https://ar-makeup.vercel.app \
///   --dart-define=SUPABASE_URL=https://xxxxx.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=eyJhbGci...
/// ```
///
/// Local development pointing at `next dev` on the same machine:
///   * Android emulator  → `--dart-define=WEB_BASE_URL=http://10.0.2.2:3000`
///   * Physical device   → `--dart-define=WEB_BASE_URL=http://192.168.x.x:3000`
///     (your PC's LAN IP; the phone must be on the same Wi-Fi)
///   * Tunnel (ngrok)    → `--dart-define=WEB_BASE_URL=https://<id>.ngrok-free.dev`
///
/// See `ENV_SETUP.md` for the ready-made commands.
class AppConfig {
  const AppConfig._();

  // ── Supabase ───────────────────────────────────────────────────────────────

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://gzyjcfwcjibtrdhmojcn.supabase.co',
  );

  /// Anon key is safe to ship in the client — RLS is what protects the data.
  /// The service-role key must never appear in this project.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd6eWpjZndjamlidHJkaG1vamNuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjkwODA4NjgsImV4cCI6MjA4NDY1Njg2OH0.D50ErvGX0Sif9n-EvwS9NYTxK08zZU-4TIIZm0UwhGM',
  );

  // ── Companion website ──────────────────────────────────────────────────────

  static const String _webBaseUrlRaw = String.fromEnvironment(
    'WEB_BASE_URL',
    defaultValue: 'https://ar-makeup-web.vercel.app',
  );

  /// Root of the Next.js site, guaranteed without a trailing slash.
  static String get webBaseUrl => _stripTrailingSlashes(_webBaseUrlRaw);

  /// True when the web base URL still points at a throwaway tunnel / localhost.
  /// Used to surface a one-line warning in debug builds instead of silently
  /// launching a dead link during a demo.
  static bool get isEphemeralWebHost {
    final host = Uri.tryParse(webBaseUrl)?.host ?? '';
    return host.isEmpty ||
        host.contains('ngrok') ||
        host.contains('trycloudflare') ||
        host.contains('loca.lt') ||
        host == 'localhost' ||
        host == '10.0.2.2' ||
        host.startsWith('192.168.') ||
        host.contains('your-production-domain');
  }

  // ── Web paths ──────────────────────────────────────────────────────────────
  // Keep these in sync with the Next.js route folders in `src/app/`.

  /// Receives the app's Supabase session and signs the browser in.
  /// See `src/app/auth/bridge/page.tsx` on the web side.
  static const String bridgePath = '/auth/bridge';

  static const String productsPath = '/products';
  static const String skinAnalysisPath = '/skin-analysis';
  static const String supportPath = '/support';

  /// Public password reset page (`src/app/auth/forgot-password`). No session.
  static const String forgotPasswordPath = '/auth/forgot-password';

  /// Public terms page (`src/app/terms`).
  static const String termsPath = '/terms';

  /// Public privacy page on the companion site (`src/app/privacy`).
  static const String privacyPath = '/privacy';

  /// Makeup bag on the website. `?add=1` opens the catalog picker.
  static const String makeupBagPath = '/makeup-bag';

  static String makeupBagAddPath() => '$makeupBagPath?add=1';

  /// Product detail route. The page reads `shade` and preselects that chip.
  static String productPagePath(String productKey, {String? shadeKey}) {
    final key = Uri.encodeComponent(productKey.trim());
    final path = '$productsPath/$key';
    final shade = shadeKey?.trim() ?? '';
    if (shade.isEmpty) return path;
    return '$path?shade=${Uri.encodeComponent(shade)}';
  }

  static const String cartPath = '/cart';
  static const String myLooksPath = '/my-looks';
  static const String myOrdersPath = '/my-orders';

  /// Order detail on the website (`src/app/my-orders/[id]`).
  static String orderPath(String orderId) =>
      '$myOrdersPath/${Uri.encodeComponent(orderId.trim())}';

  static const String checkoutPath = '/checkout/shipping';

  static String lookPath(String lookId) => '/looks/$lookId';

  /// Shared foundation shade-match endpoint. The device samples skin patches and
  /// posts about forty numbers here; the colour science, ΔE2000 ranking and
  /// persistence all live on the web side so the app and the website can never
  /// recommend different shades for the same face.
  /// See `src/app/api/foundation-match/route.ts`.
  static const String foundationMatchPath = '/api/foundation-match';

  /// Beauty profile read/write, used by [beauty_profile_service.dart].
  static const String beautyProfilePath = '/api/beauty-profile';

  /// Look page in "buy the whole look" mode — the web page auto-fills the cart
  /// and forwards to checkout. Consumed in Phase 1 (Buy This Look).
  static String buyLookPath(String lookId) => '/looks/$lookId?action=buy';

  // ── URL builders ───────────────────────────────────────────────────────────

  /// Absolute, token-free URL. Safe to copy, share or post anywhere.
  static String publicUrl(String path) => '$webBaseUrl${_normalizePath(path)}';

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _stripTrailingSlashes(String value) {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  static String _normalizePath(String path) {
    final p = path.trim();
    if (p.isEmpty) return '/';
    return p.startsWith('/') ? p : '/$p';
  }
}