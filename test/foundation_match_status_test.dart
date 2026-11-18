import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/services/foundation_match_service.dart';

void main() {
  group('FoundationMatchService HTTP status', () {
    test('401 still asks the user to sign in', () {
      final error = FoundationMatchService.exceptionForHttpStatus(401, '');
      expect(error, isNotNull);
      expect(error!.needsSignIn, isTrue);
      expect(error.message, 'Please sign in to save your shade match.');
    });

    test('429 is a friendly wait, not the server body', () {
      final error = FoundationMatchService.exceptionForHttpStatus(
        429,
        '{"error":"rate limit"}',
      );
      expect(error, isNotNull);
      expect(error!.message, 'Please wait a moment and try again.');
      expect(error.needsSignIn, isFalse);
    });

    test('only 503 is retried, once, after 2 seconds', () {
      expect(FoundationMatchService.retriesServiceUnavailable(503), isTrue);
      expect(FoundationMatchService.retriesServiceUnavailable(429), isFalse);
      expect(FoundationMatchService.retriesServiceUnavailable(401), isFalse);
      expect(FoundationMatchService.retriesServiceUnavailable(500), isFalse);
      expect(FoundationMatchService.retriesServiceUnavailable(200), isFalse);
      expect(
        FoundationMatchService.serviceUnavailableRetryDelay,
        const Duration(seconds: 2),
      );
    });

    test('200 is not an error', () {
      expect(FoundationMatchService.exceptionForHttpStatus(200, '{}'), isNull);
    });
  });
}
