import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../utils/app_colors.dart';

/// Bridges the Flutter app and the Next.js companion site.
///
/// ## Why this exists
///
/// The app and the website are two separate Supabase clients with two separate
/// session stores. Before this, tapping "Web Store" dropped the user on the
/// site as an **anonymous visitor** — so "my looks", "my orders" and (from
/// Phase 1 onwards) "buy this look" all landed on a sign-in wall.
///
/// ## How the handoff works
///
/// [openAuthenticated] sends the user to `/auth/bridge` with the current
/// Supabase tokens in the **URL fragment**:
///
/// ```
/// https://site/auth/bridge#at=<access_token>&rt=<refresh_token>&next=/looks/123
/// ```
///
/// The fragment is deliberate, not incidental:
///   * browsers never transmit the fragment to the server, so the tokens are
///     not written to any server / proxy / CDN access log;
///   * the bridge page calls `supabase.auth.setSession(...)`, then strips the
///     fragment with `history.replaceState` before forwarding to `next`.
///
/// This is the same mechanism Supabase's own OAuth redirect uses.
///
/// ## The rule that must not be broken
///
/// A URL containing tokens is a **bearer credential**. It may only ever be
/// opened in the user's own browser. Anything the user might hand to somebody
/// else — copy link, share sheet, WhatsApp — must go through [publicUrl] /
/// [openPublic], which never touch the session.
class WebBridge {
  const WebBridge._();

  /// Refresh the access token when it has less than this long to live, so the
  /// browser doesn't receive an already-dead token.
  static const Duration _refreshLeeway = Duration(minutes: 2);

  // ── Public (token-free) ────────────────────────────────────────────────────

  /// Absolute URL with no session material attached. Use for copy / share.
  static String publicUrl(String path) => AppConfig.publicUrl(path);

  /// Opens [path] on the website as an anonymous visitor.
  static Future<bool> openPublic(BuildContext context, String path) {
    return _launch(context, AppConfig.publicUrl(path));
  }

  // ── Authenticated ──────────────────────────────────────────────────────────

  /// Opens [path] on the website, carrying the signed-in user's session so the
  /// browser lands already authenticated.
  ///
  /// Falls back to a plain public URL when nobody is signed in or the session
  /// can't be refreshed — the user simply sees the site's own sign-in prompt,
  /// which is strictly better than failing to open anything.
  static Future<bool> openAuthenticated(
    BuildContext context,
    String path,
  ) async {
    final url = await buildAuthenticatedUrl(path);
    if (!context.mounted) return false;
    return _launch(context, url);
  }

  /// Builds the bridge URL for [path] without launching it.
  ///
  /// Exposed separately so Phase 1 features (Buy This Look, favourites,
  /// makeup bag) can pre-compute a destination before showing a confirmation
  /// sheet, and so it can be unit-tested.
  static Future<String> buildAuthenticatedUrl(String path) async {
    final handoff = await _freshSession();
    return urlAfterRefresh(
      path: path,
      refreshFailed: handoff.refreshFailed,
      accessToken: handoff.session?.accessToken,
      refreshToken: handoff.session?.refreshToken,
    );
  }

  /// Bridge URL after a refresh attempt, or the public URL when the attempt
  /// failed. A failed refresh must not place the previous access token in the
  /// fragment — the website shows its own sign-in instead.
  @visibleForTesting
  static String urlAfterRefresh({
    required String path,
    required bool refreshFailed,
    String? accessToken,
    String? refreshToken,
  }) {
    if (refreshFailed ||
        accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty) {
      return AppConfig.publicUrl(path);
    }

    final fragment = <String>[
      'at=${Uri.encodeComponent(accessToken)}',
      'rt=${Uri.encodeComponent(refreshToken)}',
      'next=${Uri.encodeComponent(normalizeNext(path))}',
    ].join('&');

    return '${AppConfig.publicUrl(AppConfig.bridgePath)}#$fragment';
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /// Current session, refreshed first if it is expired or about to expire.
  ///
  /// [refreshFailed] is true only when a needed refresh threw. The previous
  /// access token is dropped in that case so it cannot be copied into a URL.
  static Future<({Session? session, bool refreshFailed})> _freshSession() async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    if (session == null) return (session: null, refreshFailed: false);

    if (!_needsRefresh(session)) {
      return (session: session, refreshFailed: false);
    }

    try {
      final res = await auth.refreshSession();
      return (
        session: res.session ?? auth.currentSession,
        refreshFailed: false,
      );
    } catch (_) {
      debugPrint('⚠️ WebBridge: session refresh failed');
      return (session: null, refreshFailed: true);
    }
  }

  static bool _needsRefresh(Session session) {
    if (session.isExpired) return true;
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return false;
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    return expiry.isBefore(DateTime.now().add(_refreshLeeway));
  }

  /// The web bridge only forwards to same-origin paths. Normalising here keeps
  /// the two sides' expectations identical and avoids a silent redirect to `/`.
  ///
  /// This is the app-side half of the open-redirect guard: `//evil.com` is a
  /// protocol-relative URL, so forwarding it would send the browser — carrying
  /// a freshly-set session — to another origin. The web bridge repeats the same
  /// check, because it must not trust a hand-edited fragment either.
  @visibleForTesting
  static String normalizeNext(String path) {
    final p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/') || p.startsWith('//')) return '/';
    if (p.startsWith(AppConfig.bridgePath)) return '/'; // never loop
    return p;
  }

  static Future<bool> _launch(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showError(context, 'That link looks malformed.');
      return false;
    }

    if (AppConfig.isEphemeralWebHost) {
      debugPrint(
        '⚠️ WebBridge: WEB_BASE_URL is "${AppConfig.webBaseUrl}" — a tunnel or '
        'local address. Pass --dart-define=WEB_BASE_URL=<url> before a demo.',
      );
    }

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return true;
    } catch (e) {
      debugPrint('❌ WebBridge: launchUrl failed for ${uri.host}: $e');
    }

    if (context.mounted) {
      _showError(context, 'Could not open the link. Please try again.');
    }
    return false;
  }

  static void _showError(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}
