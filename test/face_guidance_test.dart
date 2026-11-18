import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/utils/face_guidance.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  FaceGuidanceState at(
    FaceGuidanceState state,
    Duration offset, {
    bool? visible,
    int? count,
    bool countEvent = false,
  }) {
    return reduceFaceGuidance(
      state,
      faceVisible: visible,
      faceCount: count,
      countEvent: countEvent,
      now: t0.add(offset),
    );
  }

  group('reduceFaceGuidance', () {
    test('no face at the start blocks save and shows the no-face line', () {
      const state = FaceGuidanceState();
      expect(state.banner, FaceGuidanceKind.noFace);
      expect(state.bannerMessage, FaceGuidance.noFaceMessage);
      expect(state.blocksSaveAndShare, isTrue);
      expect(state.blockReason, FaceGuidance.noFaceMessage);
    });

    test('one face, including a count of one, clears the banner immediately', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.bannerMessage, isNull);
      expect(state.blocksSaveAndShare, isFalse);

      state = at(state, Duration.zero, count: 1, countEvent: true);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.blocksSaveAndShare, isFalse);
    });

    test('two faces block immediately and the banner waits out the debounce', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      state = at(state, Duration.zero, count: 2, countEvent: true);

      expect(state.blocksSaveAndShare, isTrue);
      expect(state.blockReason, FaceGuidance.severalFacesMessage);
      expect(state.banner, FaceGuidanceKind.clear);

      state = at(
        state,
        const Duration(milliseconds: 399),
      );
      expect(state.banner, FaceGuidanceKind.clear);

      state = at(state, FaceGuidance.debounce);
      expect(state.banner, FaceGuidanceKind.severalFaces);
      expect(state.bannerMessage, FaceGuidance.severalFacesMessage);
      expect(state.blocksSaveAndShare, isTrue);
    });

    test('flapping 0/1 inside the debounce does not bring the banner back', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      final kinds = <FaceGuidanceKind>[state.banner];
      for (var i = 1; i <= 6; i++) {
        state = at(
          state,
          Duration(milliseconds: 50 * i),
          visible: i.isEven,
        );
        kinds.add(state.banner);
        expect(state.blocksSaveAndShare, isFalse);
      }
      expect(kinds, everyElement(FaceGuidanceKind.clear));
      expect(state.bannerMessage, isNull);
    });

    test('a face lost longer than the grace shows the no-face line', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      state = at(state, const Duration(seconds: 2), visible: false);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.blocksSaveAndShare, isFalse);

      state = at(
        state,
        const Duration(seconds: 2, milliseconds: 399),
      );
      expect(state.banner, FaceGuidanceKind.clear);

      state = at(
        state,
        const Duration(seconds: 2) + FaceGuidance.faceLostGrace,
      );
      expect(state.banner, FaceGuidanceKind.noFace);
      expect(state.bannerMessage, FaceGuidance.noFaceMessage);
      expect(state.blockReason, FaceGuidance.noFaceMessage);
    });

    test('a count callback that never fires follows visibility only', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      expect(state.faceCount, isNull);
      expect(state.countFresh, isFalse);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.blocksSaveAndShare, isFalse);

      state = at(state, const Duration(seconds: 1), visible: false);
      state = at(state, const Duration(seconds: 1) + FaceGuidance.faceLostGrace);
      expect(state.banner, FaceGuidanceKind.noFace);
      expect(state.blockReason, isNot(FaceGuidance.severalFacesMessage));
    });

    test('a count from before the face left is not reused when it returns', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      state = at(state, Duration.zero, count: 2, countEvent: true);
      state = at(state, FaceGuidance.debounce);
      expect(state.banner, FaceGuidanceKind.severalFaces);

      state = at(state, const Duration(seconds: 1), visible: false);
      state = at(
        state,
        const Duration(seconds: 1) + FaceGuidance.faceLostGrace,
      );
      expect(state.banner, FaceGuidanceKind.noFace);

      state = at(state, const Duration(seconds: 3), visible: true);
      expect(state.countFresh, isFalse);
      expect(state.faceCount, 2);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.blockReason, isNull);
      expect(state.blocksSaveAndShare, isFalse);
    });

    test('one face after several faces re-enables save immediately', () {
      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      state = at(state, Duration.zero, count: 3, countEvent: true);
      state = at(state, FaceGuidance.debounce);
      expect(state.blocksSaveAndShare, isTrue);

      state = at(state, FaceGuidance.debounce, count: 1, countEvent: true);
      expect(state.banner, FaceGuidanceKind.clear);
      expect(state.blocksSaveAndShare, isFalse);
    });

    test('hold and compare capture use the same gate as save', () {
      const none = FaceGuidanceState();
      expect(none.canCapture, isFalse);
      expect(none.canHold, isFalse);
      expect(none.canCapture, !none.blocksSaveAndShare);
      expect(none.blockReason, FaceGuidance.noFaceMessage);

      var state = at(const FaceGuidanceState(), Duration.zero, visible: true);
      expect(state.canCapture, isTrue);
      expect(state.canHold, isTrue);

      state = at(state, Duration.zero, count: 2, countEvent: true);
      expect(state.canCapture, isFalse);
      expect(state.canHold, isFalse);
      expect(state.blockReason, FaceGuidance.severalFacesMessage);
      expect(state.banner, FaceGuidanceKind.clear);

      state = at(state, FaceGuidance.debounce, count: 1, countEvent: true);
      expect(state.canCapture, isTrue);
      expect(state.canHold, isTrue);
      expect(state.blockReason, isNull);

      state = at(state, const Duration(seconds: 1), visible: false);
      expect(state.canCapture, isTrue);
      expect(state.canHold, isTrue);

      state = at(
        state,
        const Duration(seconds: 1) + FaceGuidance.faceLostGrace,
      );
      expect(state.canCapture, isFalse);
      expect(state.canHold, isFalse);
      expect(state.blockReason, FaceGuidance.noFaceMessage);
      expect(state.canHold, state.canCapture);
      expect(state.canCapture, !state.blocksSaveAndShare);
    });
  });
}
