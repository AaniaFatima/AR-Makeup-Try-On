// Contracts from the mobile audit that can be checked without a phone,
// a camera, or a network call.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/cache/looks_cache.dart';
import 'package:makeup_tryon/app/config/app_config.dart';
import 'package:makeup_tryon/app/screens/foundation_match_screen.dart';
import 'package:makeup_tryon/app/services/foundation_match_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('product and bag URLs', () {
    test('buy opens /products/{key} and preselects shade', () {
      expect(
        AppConfig.productPagePath(
          'fnd_maybelline_fitme_liquid',
          shadeKey: '220',
        ),
        '/products/fnd_maybelline_fitme_liquid?shade=220',
      );
    });

    test('buy does not use the catalog query the products page ignores', () {
      final path = AppConfig.productPagePath('fit-me', shadeKey: 'ivory');
      expect(path.startsWith('/products/fit-me'), isTrue);
      expect(path.contains('?product='), isFalse);
      expect(path.contains('/products?'), isFalse);
    });

    test('bag and product links use the configured host', () {
      expect(AppConfig.makeupBagAddPath(), '/makeup-bag?add=1');
      expect(
        AppConfig.publicUrl(AppConfig.makeupBagPath),
        '${AppConfig.webBaseUrl}/makeup-bag',
      );
      expect(
        AppConfig.publicUrl(AppConfig.makeupBagAddPath()),
        '${AppConfig.webBaseUrl}/makeup-bag?add=1',
      );
      expect(
        AppConfig.publicUrl(AppConfig.productPagePath('fit-me')),
        '${AppConfig.webBaseUrl}/products/fit-me',
      );
      expect(AppConfig.webBaseUrl.endsWith('/'), isFalse);
    });

    test('product keys and shade keys are encoded', () {
      expect(
        AppConfig.productPagePath('a b', shadeKey: 'shade/1'),
        '/products/a%20b?shade=shade%2F1',
      );
    });
  });

  group('LooksCache sign-out race', () {
    test('a prefetch still in flight does not restore the previous looks', () async {
      final started = Completer<void>();
      final gate = Completer<List<Map<String, dynamic>>>();
      final cache = LooksCache.forTest((userId) {
        started.complete();
        return gate.future;
      });

      final pending = cache.prefetch('user-a');
      await started.future;
      cache.clear();
      gate.complete([
        {'id': 'look-1', 'user_id': 'user-a'},
      ]);
      await pending;

      expect(cache.looks, isEmpty);
      expect(cache.isLoaded, isFalse);
    });

    test('a prefetch that finishes for the same user is kept', () async {
      final cache = LooksCache.forTest(
        (_) async => [
          {'id': 'look-1'},
        ],
      );

      await cache.prefetch('user-a');

      expect(cache.looks, [
        {'id': 'look-1'},
      ]);
      expect(cache.isLoaded, isTrue);
    });

    test('cache file names cannot leave the account directory', () {
      expect(
        LooksCache.cacheFileNameFor('user/../other'),
        'saved_looks_cache_user____other.json',
      );
      expect(LooksCache.cacheFileNameFor('user-a'), 'saved_looks_cache_user-a.json');
    });
  });

  group('foundation match contract', () {
    test('fromJson marks a failed quality check as a retake', () {
      final result = FoundationMatchResult.fromJson({
        'quality': {
          'ok': false,
          'retakeReason': 'Too dark',
          'retakeHint': 'Face a window',
        },
        'confidence': {'score': 0.1, 'label': 'low'},
      });

      expect(result.needsRetake, isTrue);
      expect(result.retakeReason, 'Too dark');
      expect(result.best, isNull);
    });

    test('fromJson keeps the first match', () {
      final result = FoundationMatchResult.fromJson({
        'quality': {'ok': true},
        'confidence': {'score': 0.9, 'label': 'high'},
        'matches': [
          {
            'productKey': 'fnd_maybelline_fitme_liquid',
            'shadeKey': '220',
            'shadeName': 'Natural Beige',
            'productName': 'Fit Me',
            'deltaE': 2.4,
          },
        ],
        'savedToProfile': true,
      });

      expect(result.needsRetake, isFalse);
      expect(result.best?.productKey, 'fnd_maybelline_fitme_liquid');
      expect(result.best?.shadeKey, '220');
      expect(result.best?.deltaE, 2.4);
      expect(result.savedToProfile, isTrue);
    });

    test('a warm hue the server called cool is shown as neutral', () {
      final skin = SkinReading(
        hex: '#C68642',
        l: 60,
        a: 10,
        b: 18,
        ita: 20,
        depthLevel: 'medium',
        undertone: 'cool',
        monkScale: 5,
        regionsUsed: const ['cheek'],
      );

      expect(shownUndertone(skin), 'neutral');
    });

    test('an undertone the server did not call cool is left as-is', () {
      final skin = SkinReading(
        hex: '#C68642',
        l: 60,
        a: 10,
        b: 18,
        ita: 20,
        depthLevel: 'medium',
        undertone: 'warm',
        monkScale: 5,
        regionsUsed: const ['cheek'],
      );

      expect(shownUndertone(skin), 'warm');
    });
  });
}
