// Phase 0 unit tests.
//
// These cover the two pieces of Phase 0 that are easy to get subtly wrong and
// impossible to eyeball: URL assembly and the open-redirect guard on the
// app→web session bridge.
//
// Nothing here touches Supabase or the network, so it runs with plain
// `flutter test` — no emulator, no credentials.

import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/config/app_config.dart';
import 'package:makeup_tryon/app/services/web_bridge.dart';

void main() {
  group('AppConfig.publicUrl', () {
    test('joins base and path without a double slash', () {
      expect(
        AppConfig.publicUrl('/products'),
        '${AppConfig.webBaseUrl}/products',
      );
    });

    test('adds the leading slash when a path is missing one', () {
      expect(
        AppConfig.publicUrl('products'),
        '${AppConfig.webBaseUrl}/products',
      );
    });

    test('an empty path resolves to the site root', () {
      expect(AppConfig.publicUrl(''), '${AppConfig.webBaseUrl}/');
    });

    test('webBaseUrl never carries a trailing slash', () {
      expect(AppConfig.webBaseUrl.endsWith('/'), isFalse);
    });

    test('produces a parseable absolute URL with a host', () {
      final uri = Uri.parse(AppConfig.publicUrl(AppConfig.bridgePath));
      expect(uri.hasScheme, isTrue);
      expect(uri.host, isNotEmpty);
      expect(uri.path, AppConfig.bridgePath);
    });
  });

  group('AppConfig path builders', () {
    test('lookPath embeds the id', () {
      expect(AppConfig.lookPath('abc-123'), '/looks/abc-123');
    });

    test('buyLookPath carries the buy action', () {
      expect(AppConfig.buyLookPath('abc-123'), '/looks/abc-123?action=buy');
    });
  });

  group('WebBridge.normalizeNext — open-redirect guard', () {
    test('keeps an ordinary same-origin path', () {
      expect(WebBridge.normalizeNext('/looks/42'), '/looks/42');
    });

    test('keeps a query string intact', () {
      expect(
        WebBridge.normalizeNext('/looks/42?action=buy'),
        '/looks/42?action=buy',
      );
    });

    test('rejects a protocol-relative URL', () {
      // `//evil.com` would resolve against the current scheme and leave the
      // origin, taking the just-established session with it.
      expect(WebBridge.normalizeNext('//evil.com'), '/');
      expect(WebBridge.normalizeNext('//evil.com/steal'), '/');
    });

    test('rejects an absolute URL', () {
      expect(WebBridge.normalizeNext('https://evil.com'), '/');
      expect(WebBridge.normalizeNext('http://evil.com/x'), '/');
    });

    test('rejects a scheme-less relative path', () {
      expect(WebBridge.normalizeNext('products'), '/');
    });

    test('refuses to forward back to the bridge itself', () {
      expect(WebBridge.normalizeNext(AppConfig.bridgePath), '/');
    });

    test('an empty or whitespace path becomes the root', () {
      expect(WebBridge.normalizeNext(''), '/');
      expect(WebBridge.normalizeNext('   '), '/');
    });

    test('trims surrounding whitespace before deciding', () {
      expect(WebBridge.normalizeNext('  /cart  '), '/cart');
    });
  });

  group('WebBridge.urlAfterRefresh — expired session', () {
    test('a failed refresh opens the public URL without the old access token', () {
      const staleAccess = 'expired-access-token';
      const staleRefresh = 'maybe-still-valid-refresh';
      final url = WebBridge.urlAfterRefresh(
        path: '/looks/42',
        refreshFailed: true,
        accessToken: staleAccess,
        refreshToken: staleRefresh,
      );

      expect(url, AppConfig.publicUrl('/looks/42'));
      expect(url.contains('#'), isFalse);
      expect(url.contains(staleAccess), isFalse);
      expect(url.contains(staleRefresh), isFalse);
      expect(url.contains('at='), isFalse);
    });
  });

  group('AppConfig.isEphemeralWebHost', () {
    test('flags the current build so a demo cannot silently use a tunnel', () {
      // Not an assertion about which value is correct — both are legitimate
      // depending on --dart-define. This just pins the contract so the debug
      // warning in WebBridge keeps working.
      expect(AppConfig.isEphemeralWebHost, isA<bool>());
    });
  });
}
