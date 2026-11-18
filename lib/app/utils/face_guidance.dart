/// Try-on face banner. Inputs are only what DeepAR already reports:
/// visibility, an optional face count, and timestamps.
///
/// Distance, head angle, light, and species are not measured here, so this
/// helper never mentions them. A null count means the count callback has not
/// produced a count that still belongs to the current face.
enum FaceGuidanceKind {
  /// One face, or a visible face whose count is missing or stale.
  clear,

  /// No face, and the short grace after a loss has elapsed.
  noFace,

  /// More than one face, from a count that still belongs to this appearance.
  severalFaces,
}

/// Copy and timings for [reduceFaceGuidance].
abstract final class FaceGuidance {
  /// How long a new "several faces" banner waits before it is shown.
  static const Duration debounce = Duration(milliseconds: 400);

  /// How long a face may disappear before the no-face banner and save block.
  static const Duration faceLostGrace = Duration(milliseconds: 400);

  static const String noFaceMessage =
      'No face found. Face the camera in good light.';

  static const String severalFacesMessage = 'One face at a time, please.';

  static String? messageFor(FaceGuidanceKind kind) {
    switch (kind) {
      case FaceGuidanceKind.clear:
        return null;
      case FaceGuidanceKind.noFace:
        return noFaceMessage;
      case FaceGuidanceKind.severalFaces:
        return severalFacesMessage;
    }
  }
}

/// One step of the banner. Pure: no widgets and no DeepAR.
class FaceGuidanceState {
  const FaceGuidanceState({
    this.faceVisible = false,
    this.faceCount,
    this.countFresh = false,
    this.lastFaceAt,
    this.banner = FaceGuidanceKind.noFace,
    this.blockReason = FaceGuidance.noFaceMessage,
    this.pendingSince,
    this.wakeAt,
  });

  final bool faceVisible;

  /// Last count value. Ignored for the multi-face line unless [countFresh].
  final int? faceCount;

  /// True when [faceCount] arrived and has not been invalidated by a face loss.
  final bool countFresh;

  /// When a face was last known to be in frame. Null until the first one.
  final DateTime? lastFaceAt;

  /// Banner currently on screen. Lags [blockReason] for a second face.
  final FaceGuidanceKind banner;

  /// Why Save, Hold, and Compare capture are blocked, or null when exactly
  /// one face is accepted.
  final String? blockReason;

  /// When the several-faces banner started waiting out [FaceGuidance.debounce].
  final DateTime? pendingSince;

  /// When the caller should invoke [reduceFaceGuidance] again with no new event.
  final DateTime? wakeAt;

  String? get bannerMessage => FaceGuidance.messageFor(banner);

  bool get blocksSaveAndShare => blockReason != null;

  /// Hold and Compare may grab a frame only when Save would.
  /// False while there is no face or more than one face, including the
  /// several-faces debounce. True again as soon as one face is accepted,
  /// including the short grace after a face leaves.
  bool get canCapture => blockReason == null;

  /// Press-and-hold uses the same acceptance as [canCapture].
  bool get canHold => canCapture;
}

/// Advances [previous] to [now].
///
/// Pass [faceVisible] only when the visibility callback fired, and
/// [countEvent] only when the count callback fired. A later call with neither
/// set is a clock tick (grace or debounce elapsed).
///
/// A count is stale after the face leaves and is ignored if the face returns
/// before a new count callback. A count that never arrives leaves [faceCount]
/// null, and visibility alone decides.
FaceGuidanceState reduceFaceGuidance(
  FaceGuidanceState previous, {
  bool? faceVisible,
  int? faceCount,
  bool countEvent = false,
  required DateTime now,
}) {
  var visible = previous.faceVisible;
  var count = previous.faceCount;
  var fresh = previous.countFresh;
  var lastFaceAt = previous.lastFaceAt;

  if (faceVisible != null) {
    if (faceVisible) {
      visible = true;
      lastFaceAt = now;
    } else if (previous.faceVisible) {
      visible = false;
      fresh = false;
      lastFaceAt = now;
    } else {
      visible = false;
    }
  }

  if (countEvent) {
    count = faceCount;
    fresh = true;
  }

  final raw = _rawKind(visible: visible, count: count, fresh: fresh);

  String? block;
  var desired = raw;
  DateTime? graceWake;
  if (raw == FaceGuidanceKind.noFace && lastFaceAt != null) {
    final lostFor = now.difference(lastFaceAt);
    if (lostFor < FaceGuidance.faceLostGrace) {
      desired = FaceGuidanceKind.clear;
      graceWake = lastFaceAt.add(FaceGuidance.faceLostGrace);
    }
  }

  if (desired == FaceGuidanceKind.clear) {
    block = null;
  } else if (desired == FaceGuidanceKind.noFace) {
    block = FaceGuidance.noFaceMessage;
  } else {
    block = FaceGuidance.severalFacesMessage;
  }

  var banner = previous.banner;
  DateTime? pendingSince = previous.pendingSince;
  DateTime? wakeAt;

  if (desired != FaceGuidanceKind.severalFaces) {
    banner = desired;
    pendingSince = null;
    wakeAt = graceWake;
  } else if (banner == FaceGuidanceKind.severalFaces) {
    pendingSince = null;
  } else {
    pendingSince ??= now;
    final due = pendingSince.add(FaceGuidance.debounce);
    if (!now.isBefore(due)) {
      banner = FaceGuidanceKind.severalFaces;
      pendingSince = null;
    } else {
      if (banner == FaceGuidanceKind.noFace) banner = FaceGuidanceKind.clear;
      wakeAt = due;
    }
  }

  return FaceGuidanceState(
    faceVisible: visible,
    faceCount: count,
    countFresh: fresh,
    lastFaceAt: lastFaceAt,
    banner: banner,
    blockReason: block,
    pendingSince: pendingSince,
    wakeAt: wakeAt,
  );
}

FaceGuidanceKind _rawKind({
  required bool visible,
  required int? count,
  required bool fresh,
}) {
  if (!visible) return FaceGuidanceKind.noFace;
  if (fresh && count != null && count > 1) {
    return FaceGuidanceKind.severalFaces;
  }
  return FaceGuidanceKind.clear;
}
