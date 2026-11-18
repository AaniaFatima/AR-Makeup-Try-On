// lib/app/services/skin_sampler.dart
//
// Measures skin colour from a still photo, on device.
//
// ## Why the sampling happens here and not on the server
//
// The obvious design is to POST the photo and let the server do everything. It is
// the wrong one, for three reasons:
//
//  1. A phone frame base64-encodes to several megabytes, which is over the request
//     body limit of every serverless host the website would deploy to. It works in
//     local development and fails in production — the worst failure to ship.
//  2. Decoding JPEG server-side needs an image dependency the web project does not
//     have.
//  3. **The landmarks are here.** ML Kit gives contours and landmark points that
//     locate a cheek to within a few pixels. A server holding only a bounding box
//     would be guessing which pixels are cheek and which are hair, shadow, or wall.
//
// So this file turns a photo into about forty numbers — five patch medians, a
// pixel count and a spread per patch, and one scene illuminant estimate — and only
// those cross the network. No photograph is uploaded or stored anywhere.
//
// ## Why the pixel work runs in an isolate
//
// A 1080×1440 frame is 6.2 MB of RGBA and the passes over it are O(pixels). Done
// on the UI isolate that is several dropped frames at best; on a low-end Android
// device it is a visible freeze right after the shutter, which reads as a crash to
// the person holding the phone. [compute] moves it off the main isolate, so the
// spinner keeps spinning.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../utils/skin_color.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public results
// ─────────────────────────────────────────────────────────────────────────────

/// One sampled region, in exactly the shape `POST /api/foundation-match` expects.
class SkinPatchSample {
  const SkinPatchSample({
    required this.region,
    required this.r,
    required this.g,
    required this.b,
    required this.pixels,
    required this.luminanceStdDev,
    this.regionWeight = 1,
  });

  /// One of the five region names the API accepts.
  final String region;

  /// Median of the accepted pixels. Median rather than mean because one blown-out
  /// pixel drags a mean and cannot move a median.
  final int r;
  final int g;
  final int b;

  /// How many pixels survived rejection. A tiny count means the patch missed skin.
  final int pixels;

  /// Spread of L* within the patch. High means texture, hair or a shadow edge.
  final double luminanceStdDev;

  /// Cheeks weigh more than the jaw. Older servers that ignore the field treat it as 1.
  final double regionWeight;

  Map<String, dynamic> toJson() => {
        'region': region,
        'r': r,
        'g': g,
        'b': b,
        'pixels': pixels,
        'luminanceStdDev': double.parse(luminanceStdDev.toStringAsFixed(2)),
        'regionWeight': double.parse(regionWeight.toStringAsFixed(2)),
      };

  String get hex => rgbToHex(r, g, b);
}

/// Everything the sampler produces, plus enough diagnostics to explain a refusal.
class SkinSampleResult {
  const SkinSampleResult({
    required this.patches,
    required this.illuminant,
    required this.imageWidth,
    required this.imageHeight,
    required this.faceRatio,
    required this.headYaw,
    required this.headRoll,
    this.whiteReference,
  });

  final List<SkinPatchSample> patches;

  /// Scene illuminant from the background, or null when there wasn't enough of it.
  /// A null value tells the server to skip white balance and cap confidence.
  final Map<String, int>? illuminant;

  /// Median of a bright, low-chroma patch outside the face, when one was found.
  final Map<String, int>? whiteReference;

  final int imageWidth;
  final int imageHeight;

  /// Face width as a fraction of image width. Used only for the "move closer"
  /// message; the server does not see it.
  final double faceRatio;

  final double? headYaw;
  final double? headRoll;
}

/// Image-free diagnostics for one sampled camera frame. Colour values are
/// deliberately omitted; only quality spreads and sample coverage are exposed.
class SkinFrameDiagnostics {
  const SkinFrameDiagnostics({
    required this.frameNumber,
    required this.patchCount,
    required this.minPatchPixels,
    required this.meanPatchTexture,
    required this.maxPatchTexture,
    required this.maxRegionDeltaE,
    required this.regionLightnessRange,
    required this.regionChromaRange,
    required this.illuminantLightness,
  });

  final int frameNumber;
  final int patchCount;
  final int minPatchPixels;
  final double meanPatchTexture;
  final double maxPatchTexture;
  final double maxRegionDeltaE;
  final double regionLightnessRange;
  final double regionChromaRange;
  final double? illuminantLightness;

  @override
  String toString() =>
      'frame=$frameNumber patches=$patchCount minPixels=$minPatchPixels '
      'patchTexture(mean/max)=${meanPatchTexture.toStringAsFixed(1)}/'
      '${maxPatchTexture.toStringAsFixed(1)} '
      'preWbRegionSpread(maxΔE/ΔL*/ΔC*)='
      '${maxRegionDeltaE.toStringAsFixed(1)}/'
      '${regionLightnessRange.toStringAsFixed(1)}/'
      '${regionChromaRange.toStringAsFixed(1)} '
      'illuminantL*=${illuminantLightness?.toStringAsFixed(1) ?? 'missing'}';
}

/// A refusal the user can act on. Never thrown for programmer errors — those
/// propagate so they show up in development rather than being shown as advice.
class SkinSampleException implements Exception {
  const SkinSampleException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tuning
// ─────────────────────────────────────────────────────────────────────────────

/// Minimum face width as a fraction of the frame.
///
/// Below this the patches are only a handful of pixels each and quantisation
/// noise dominates the measurement. Asking the user to come closer is far better
/// than returning a confident wrong colour. The capture preview uses the same
/// fraction so the live gate and the still agree.
const double skinMinFaceWidthRatio = 0.18;
const double _minFaceRatio = skinMinFaceWidthRatio;

/// Largest head turn, in degrees, that still leaves both cheeks lit comparably.
///
/// Past roughly this the far cheek is in its own shadow, so the two cheek patches
/// disagree for a reason that has nothing to do with complexion — and the
/// server's outlier rejection would then discard a *good* patch.
const double skinMaxHeadYaw = 22.0;
const double _maxHeadYaw = skinMaxHeadYaw;

/// Largest head tilt. The sampling frame is tilt-aware, so this is generous; it
/// exists to catch a photo taken sideways or by accident.
const double skinMaxHeadRoll = 30.0;
const double _maxHeadRoll = skinMaxHeadRoll;

/// Patch radius as a fraction of the inter-ocular distance.
///
/// Scaling to the face rather than to the frame means the patch covers the same
/// piece of skin whether the phone is held at arm's length or close up.
const double _patchRadiusFactor = 0.16;
const int _minPatchRadiusPx = 4;
const int _maxPatchRadiusPx = 30;

/// Pixels at or above this in any channel are specular reflection — the colour of
/// the lamp, not of the skin — and are discarded before anything else.
const int _specularCeiling = 250;

/// Pixels below this L* are in deep shadow and carry almost no chroma.
/// Keep this low enough for the deepest real complexions; the regional median
/// and spread checks handle residual shadow without erasing valid dark skin.
const double _shadowFloorLStar = 8.0;

/// Rejection width, in standard deviations of patch luminance.
const double _rejectSigma = 1.5;

/// Roughly how many pixels to sample for the illuminant estimate.
const int _illuminantTargetSamples = 40000;

/// Cheeks carry the complexion. Forehead is next. Jaw and the nose bridge
/// pick up beard shadow and specular more often, so they weigh less.
const Map<String, double> _regionWeights = {
  'left_cheek': 1.4,
  'right_cheek': 1.4,
  'forehead': 1.0,
  'jaw': 0.62,
  'nose_bridge': 0.55,
};

/// Decoded frame is capped to this on its long edge before any pixel work.
///
/// A modern phone camera hands back 12 MP, which is 48 MB of RGBA — enough to be
/// killed by the Android low-memory killer on a budget device while the isolate
/// copy doubles it. 1440 keeps a patch at a comfortable 20–30 px radius and the
/// buffer under 9 MB.
const int _maxDecodeEdge = 1440;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

class SkinSampler {
  const SkinSampler._();

  /// Detects the face in [imagePath], samples five skin regions and estimates the
  /// scene illuminant from the background, not from the face.
  ///
  /// Throws [SkinSampleException] with a message meant for the user when the photo
  /// cannot be used.
  static Future<SkinSampleResult> sample(
    String imagePath, {
    bool seekWhiteReference = false,
    bool fromGallery = false,
  }) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw const SkinSampleException(
        "That photo couldn't be opened.",
        hint: 'Try taking it again.',
      );
    }

    // ── Decode ───────────────────────────────────────────────────────────────
    final bytes = await file.readAsBytes();
    _DecodedFrame frame;
    try {
      frame = await _decode(bytes);
    } catch (_) {
      throw const SkinSampleException(
        "That photo couldn't be read.",
        hint: 'Use a JPEG or PNG taken with the camera.',
      );
    }

    // ── Detect ───────────────────────────────────────────────────────────────
    // A fresh detector per call, always closed. Holding one open keeps a native
    // model in memory for the whole session for a feature used once.
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableContours: true,
        // Below this a face is too small to sample from anyway, and raising the
        // floor makes detection markedly faster.
        minFaceSize: 0.15,
      ),
    );

    List<Face> faces;
    try {
      faces = await detector.processImage(InputImage.fromFilePath(imagePath));
    } catch (e) {
      debugPrint('[SkinSampler] face detection failed: $e');
      throw const SkinSampleException(
        "Face detection didn't run on this photo.",
        hint: 'Try again in a moment.',
      );
    } finally {
      await detector.close();
    }

    if (faces.isEmpty) {
      if (fromGallery) {
        throw const SkinSampleException(
          'We could not find a face in this photo. Try a clear, front-facing photo.',
        );
      }
      throw const SkinSampleException(
        "No face was found in that photo.",
        hint: 'Look straight at the camera with your whole face in frame.',
      );
    }

    if (faces.length != 1) {
      throw const SkinSampleException(
        'One face at a time.',
        hint: 'Please retake with only one face in the photo.',
      );
    }

    final face = faces.first;

    // ── Reconcile ML Kit's coordinate space with the decoded buffer ───────────
    //
    // ML Kit reads the file's EXIF orientation; the Flutter decoder normally does
    // too, so the two agree. "Normally" is not "always" — a re-encoded pick or an
    // unusual EXIF tag can leave them a quarter turn apart, and the consequence
    // would be silently sampling a wall and reporting it as someone's skin tone.
    // That is far worse than a refusal, so the containment is checked rather than
    // assumed, and a mismatch is reported instead of guessed at.
    final box = face.boundingBox;
    if (!_boxPlausiblyInside(box, frame.srcWidth, frame.srcHeight)) {
      debugPrint(
        '[SkinSampler] landmark space ${box.left},${box.top} '
        '${box.width}×${box.height} does not fit '
        '${frame.srcWidth}×${frame.srcHeight}',
      );
      throw const SkinSampleException(
        "That photo couldn't be read reliably.",
        hint: 'Take a new one with the in-app camera instead of picking a file.',
      );
    }

    final faceRatio = box.width / frame.srcWidth;
    if (faceRatio < _minFaceRatio) {
      throw const SkinSampleException(
        'Your face is too small in the frame to measure accurately.',
        hint: 'Hold the phone closer, about an arm-and-a-half away.',
      );
    }

    final yaw = face.headEulerAngleY;
    if (yaw != null && yaw.abs() > _maxHeadYaw) {
      throw const SkinSampleException(
        'Your head is turned too far to one side.',
        hint: 'Face the camera straight on so both cheeks are lit the same.',
      );
    }

    final roll = face.headEulerAngleZ;
    if (roll != null && roll.abs() > _maxHeadRoll) {
      throw const SkinSampleException(
        'That photo looks tilted.',
        hint: 'Hold the phone upright and keep your head level.',
      );
    }

    // ── Plan where to sample ─────────────────────────────────────────────────
    // Prefer a full face mask. ML Kit can occasionally omit contours, so the
    // original landmark-disc sampler remains the safety net.
    final contourPlan = _planContourRegions(
      face,
      frame.scale,
      frame.width,
      frame.height,
    );
    final plan = contourPlan == null
        ? _planPatches(face, frame.scale, frame.width, frame.height)
        : const <_PatchPlan>[];
    if (contourPlan == null && plan.length < 3) {
      throw const SkinSampleException(
        'Not enough of your face is visible to measure.',
        hint: 'Move hair off your forehead and keep your whole face in frame.',
      );
    }

    // ── Measure, off the UI isolate ──────────────────────────────────────────
    final request = _SampleRequest(
      rgba: frame.rgba,
      width: frame.width,
      height: frame.height,
      patches: plan,
      contourPlan: contourPlan,
      illuminantStride: _strideFor(frame.width, frame.height),
      seekWhiteReference: seekWhiteReference,
    );

    final measured = await compute(_measureInIsolate, request);

    return SkinSampleResult(
      patches: measured.patches,
      illuminant: measured.illuminant,
      whiteReference: measured.whiteReference,
      imageWidth: frame.width,
      imageHeight: frame.height,
      faceRatio: faceRatio,
      headYaw: yaw,
      headRoll: roll,
    );
  }

  /// Samples each path and returns the per-channel median of the frames that
  /// succeeded. One good frame is enough when the others fail.
  static Future<SkinSampleResult> sampleFrames(
    List<String> imagePaths, {
    bool seekWhiteReference = false,
    bool fromGallery = false,
    void Function(SkinFrameDiagnostics diagnostics)? onFrameDiagnostics,
    void Function(int frameNumber, String reason)? onFrameFailure,
  }) async {
    if (imagePaths.isEmpty) {
      throw const SkinSampleException(
        'No photo was captured.',
        hint: 'Try the camera again, or pick one from your gallery.',
      );
    }
    final results = <SkinSampleResult>[];
    SkinSampleException? lastError;
    for (var i = 0; i < imagePaths.length; i++) {
      final path = imagePaths[i];
      try {
        final result = await sample(
          path,
          seekWhiteReference: seekWhiteReference,
          fromGallery: fromGallery,
        );
        results.add(result);
        if (onFrameDiagnostics != null) {
          try {
            onFrameDiagnostics(_diagnoseFrame(i + 1, result));
          } catch (_) {
            // Diagnostics must never change the measurement outcome.
          }
        }
      } on SkinSampleException catch (e) {
        lastError = e;
        try {
          onFrameFailure?.call(i + 1, e.message);
        } catch (_) {}
      } catch (e) {
        try {
          onFrameFailure?.call(i + 1, e.runtimeType.toString());
        } catch (_) {}
        rethrow;
      }
    }
    if (results.isEmpty) {
      throw lastError ??
          const SkinSampleException(
            "That photo couldn't be used.",
            hint: 'Try again in daylight, with your face filling the oval.',
          );
    }
    if (results.length == 1) return results.first;
    return _mergeFrames(results);
  }

  static SkinFrameDiagnostics _diagnoseFrame(
    int frameNumber,
    SkinSampleResult result,
  ) {
    if (result.patches.isEmpty) {
      return SkinFrameDiagnostics(
        frameNumber: frameNumber,
        patchCount: 0,
        minPatchPixels: 0,
        meanPatchTexture: 0,
        maxPatchTexture: 0,
        maxRegionDeltaE: 0,
        regionLightnessRange: 0,
        regionChromaRange: 0,
        illuminantLightness: null,
      );
    }
    final labs = result.patches
        .map((patch) => rgbToLab(patch.r, patch.g, patch.b))
        .toList(growable: false);
    final meanL = labs.fold<double>(0, (sum, lab) => sum + lab.l) / labs.length;
    final meanA = labs.fold<double>(0, (sum, lab) => sum + lab.a) / labs.length;
    final meanB = labs.fold<double>(0, (sum, lab) => sum + lab.b) / labs.length;
    final centre = Lab(meanL, meanA, meanB);
    final lightness = labs.map((lab) => lab.l).toList(growable: false);
    final chroma = labs.map((lab) => lab.chroma).toList(growable: false);
    final textures = result.patches.map((patch) => patch.luminanceStdDev).toList();
    final illuminant = result.illuminant;
    final illuminantLightness = illuminant == null
        ? null
        : rgbToLab(illuminant['r']!, illuminant['g']!, illuminant['b']!).l;

    return SkinFrameDiagnostics(
      frameNumber: frameNumber,
      patchCount: result.patches.length,
      minPatchPixels: result.patches
          .map((patch) => patch.pixels)
          .reduce((a, b) => a < b ? a : b),
      meanPatchTexture: textures.reduce((a, b) => a + b) / textures.length,
      maxPatchTexture: textures.reduce((a, b) => a > b ? a : b),
      maxRegionDeltaE: labs
          .map((lab) => deltaE2000(lab, centre))
          .reduce((a, b) => a > b ? a : b),
      regionLightnessRange:
          lightness.reduce((a, b) => a > b ? a : b) -
              lightness.reduce((a, b) => a < b ? a : b),
      regionChromaRange:
          chroma.reduce((a, b) => a > b ? a : b) -
              chroma.reduce((a, b) => a < b ? a : b),
      illuminantLightness: illuminantLightness,
    );
  }

  /// Median colour of a small disc. [nx] and [ny] are 0–1 across the decoded frame.
  /// Used when the user taps a sheet of paper. No image is uploaded.
  static Future<Map<String, int>?> colorNear(
    String imagePath,
    double nx,
    double ny,
  ) async {
    final bytes = await File(imagePath).readAsBytes();
    final frame = await _decode(bytes);
    final cx = (nx.clamp(0.0, 1.0) * (frame.width - 1)).round();
    final cy = (ny.clamp(0.0, 1.0) * (frame.height - 1)).round();
    const radius = 8;
    final rs = <int>[];
    final gs = <int>[];
    final bs = <int>[];
    for (var dy = -radius; dy <= radius; dy++) {
      final y = cy + dy;
      if (y < 0 || y >= frame.height) continue;
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final x = cx + dx;
        if (x < 0 || x >= frame.width) continue;
        final i = (y * frame.width + x) * 4;
        if (frame.rgba[i + 3] < 250) continue;
        rs.add(frame.rgba[i]);
        gs.add(frame.rgba[i + 1]);
        bs.add(frame.rgba[i + 2]);
      }
    }
    if (rs.length < 5) return null;
    return {'r': _median(rs), 'g': _median(gs), 'b': _median(bs)};
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

class _DecodedFrame {
  _DecodedFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.srcWidth,
    required this.srcHeight,
  });

  final Uint8List rgba;

  /// Size actually decoded (possibly downscaled).
  final int width;
  final int height;

  /// Size ML Kit saw, i.e. the file's own pixel dimensions.
  final int srcWidth;
  final int srcHeight;

  /// Landmark coordinates are in source pixels; multiply by this to index [rgba].
  double get scale => width / srcWidth;
}

Future<_DecodedFrame> _decode(Uint8List bytes) async {
  // First pass: header only, to learn the size without allocating the full bitmap.
  final probe = await ui.instantiateImageCodec(bytes);
  final probeFrame = await probe.getNextFrame();
  final srcWidth = probeFrame.image.width;
  final srcHeight = probeFrame.image.height;
  probeFrame.image.dispose();
  probe.dispose();

  final longEdge = math.max(srcWidth, srcHeight);
  final needsScaling = longEdge > _maxDecodeEdge;

  final codec = needsScaling
      ? await ui.instantiateImageCodec(
          bytes,
          targetWidth: srcWidth >= srcHeight
              ? _maxDecodeEdge
              : (srcWidth * _maxDecodeEdge / srcHeight).round(),
          targetHeight: srcHeight > srcWidth
              ? _maxDecodeEdge
              : (srcHeight * _maxDecodeEdge / srcWidth).round(),
        )
      : await ui.instantiateImageCodec(bytes);

  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('toByteData returned null');
    }
    return _DecodedFrame(
      rgba: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

/// ML Kit boxes can sit a little outside the frame on a face at the edge, so this
/// is a plausibility test, not strict containment. What it is really looking for
/// is a quarter-turn disagreement, which overshoots by far more than 15%.
bool _boxPlausiblyInside(ui.Rect box, int width, int height) {
  final marginX = width * 0.15;
  final marginY = height * 0.15;
  return box.left > -marginX &&
      box.top > -marginY &&
      box.right < width + marginX &&
      box.bottom < height + marginY &&
      box.width > 0 &&
      box.height > 0;
}

int _strideFor(int width, int height) {
  final total = width * height;
  if (total <= _illuminantTargetSamples) return 1;
  return math.max(1, math.sqrt(total / _illuminantTargetSamples).round());
}

// ─────────────────────────────────────────────────────────────────────────────
// Where to sample
// ─────────────────────────────────────────────────────────────────────────────

class _PatchPlan {
  const _PatchPlan(this.region, this.cx, this.cy, this.radius);

  final String region;
  final int cx;
  final int cy;
  final int radius;
}

/// Builds the five sample discs in a face-local frame.
///
/// The frame is derived from the face itself — "up" is the direction from the
/// mouth to the midpoint of the eyes — so a tilted head samples the same skin as
/// a level one. Using image-space offsets instead would walk the forehead patch
/// into the hair as soon as the user tilts their head, which people do constantly
/// when taking a selfie.
///
/// Region choices follow the brief: forehead centre, both cheeks *below* the blush
/// apple, the jaw, and the glabella above the nose bridge. Those five spread
/// across the face's natural colour gradient — foreheads run slightly deeper,
/// cheeks slightly redder — so the median across them is closer to overall
/// complexion than any single spot.
List<_PatchPlan> _planPatches(Face face, double scale, int width, int height) {
  ui.Offset? landmark(FaceLandmarkType type) {
    final p = face.landmarks[type]?.position;
    if (p == null) return null;
    return ui.Offset(p.x.toDouble(), p.y.toDouble());
  }

  final leftEye = landmark(FaceLandmarkType.leftEye);
  final rightEye = landmark(FaceLandmarkType.rightEye);
  final noseBase = landmark(FaceLandmarkType.noseBase);
  final mouth = landmark(FaceLandmarkType.bottomMouth);

  final box = face.boundingBox;

  // Fall back to the bounding box when landmarks are missing. ML Kit occasionally
  // returns a face with no landmarks on a low-contrast frame; a coarser sample is
  // better than no reading, and the server's outlier rejection covers the rest.
  final eyeMid = (leftEye != null && rightEye != null)
      ? ui.Offset((leftEye.dx + rightEye.dx) / 2, (leftEye.dy + rightEye.dy) / 2)
      : ui.Offset(box.center.dx, box.top + box.height * 0.42);

  final interocular = (leftEye != null && rightEye != null)
      ? (leftEye - rightEye).distance
      : box.width * 0.34;

  if (interocular < 8) return const [];

  // Down the face: from the eyes toward the mouth (or nose, if no mouth point).
  final lower = mouth ?? noseBase;
  final down = lower != null && (lower - eyeMid).distance > 4
      ? (lower - eyeMid) / (lower - eyeMid).distance
      : const ui.Offset(0, 1);
  final up = -down;

  final radius = (interocular * _patchRadiusFactor * scale)
      .round()
      .clamp(_minPatchRadiusPx, _maxPatchRadiusPx);

  final cheekL = landmark(FaceLandmarkType.leftCheek) ??
      ui.Offset(box.left + box.width * 0.22, box.top + box.height * 0.62);
  final cheekR = landmark(FaceLandmarkType.rightCheek) ??
      ui.Offset(box.left + box.width * 0.78, box.top + box.height * 0.62);
  final jawAnchor = mouth ?? ui.Offset(box.center.dx, box.top + box.height * 0.82);

  final candidates = <String, ui.Offset>{
    // High on the forehead but not into the hairline: 0.85 × interocular above the
    // eye line lands mid-forehead on a typical face.
    'forehead': eyeMid + up * (interocular * 0.85),
    // Glabella — between the brows, above the bridge. Usually the least
    // made-up part of a face, which is why the brief asks for it.
    'nose_bridge': eyeMid + up * (interocular * 0.34),
    // Below the apple of the cheek, where blush is not applied.
    'left_cheek': cheekL + down * (interocular * 0.35),
    'right_cheek': cheekR + down * (interocular * 0.35),
    'jaw': jawAnchor + down * (interocular * 0.8),
  };

  final plans = <_PatchPlan>[];
  candidates.forEach((region, point) {
    final cx = (point.dx * scale).round();
    final cy = (point.dy * scale).round();
    // A disc that would run off the edge is skipped rather than clamped: clamping
    // slides it onto the background and returns the colour of a wall.
    if (cx - radius < 0 ||
        cy - radius < 0 ||
        cx + radius >= width ||
        cy + radius >= height) {
      return;
    }
    plans.add(_PatchPlan(region, cx, cy, radius));
  });

  return plans;
}

class _RegionBands {
  const _RegionBands({
    required this.foreheadBottom,
    required this.noseBridgeBottom,
    required this.cheekBottom,
    required this.jawBottom,
    required this.faceCenterX,
    required this.centerHalfWidth,
  });

  final double foreheadBottom;
  final double noseBridgeBottom;
  final double cheekBottom;
  final double jawBottom;
  final double faceCenterX;
  final double centerHalfWidth;
}

class _ContourRegionPlan {
  const _ContourRegionPlan({
    required this.faceOval,
    required this.leftEyeHole,
    required this.rightEyeHole,
    required this.mouthHole,
    required this.leftBrowHole,
    required this.rightBrowHole,
    required this.nostrilCenter,
    required this.nostrilRadius,
    required this.foreheadTop,
    required this.bands,
    required this.faceBox,
  });

  final List<ui.Offset> faceOval;
  final List<ui.Offset> leftEyeHole;
  final List<ui.Offset> rightEyeHole;
  final List<ui.Offset> mouthHole;
  final List<ui.Offset> leftBrowHole;
  final List<ui.Offset> rightBrowHole;
  final ui.Offset? nostrilCenter;
  final double nostrilRadius;
  /// Pixels above this are the hairline, not forehead skin.
  final double foreheadTop;
  final _RegionBands bands;
  final ui.Rect faceBox;
}

List<ui.Offset> _contourPoints(Face face, FaceContourType type) {
  final contour = face.contours[type];
  if (contour == null || contour.points.isEmpty) return const [];
  return contour.points
      .map((p) => ui.Offset(p.x.toDouble(), p.y.toDouble()))
      .toList();
}

bool _pointInPolygon(ui.Offset point, List<ui.Offset> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i].dx;
    final yi = polygon[i].dy;
    final xj = polygon[j].dx;
    final yj = polygon[j].dy;
    final intersects = ((yi > point.dy) != (yj > point.dy)) &&
        (point.dx < (xj - xi) * (point.dy - yi) / (yj - yi) + xi);
    if (intersects) inside = !inside;
  }
  return inside;
}

double _cross(ui.Offset o, ui.Offset a, ui.Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

/// Makes one conservative mouth hole from the two lip contours.
List<ui.Offset> _convexHull(List<ui.Offset> points) {
  if (points.length < 3) return const [];
  final sorted = [...points]
    ..sort((a, b) => a.dx == b.dx ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx));
  final lower = <ui.Offset>[];
  for (final point in sorted) {
    while (lower.length >= 2 && _cross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <ui.Offset>[];
  for (final point in sorted.reversed) {
    while (upper.length >= 2 && _cross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
}

List<ui.Offset> _scaledPoints(List<ui.Offset> points, double scale) =>
    points.map((p) => p * scale).toList();

/// Moves each vertex toward (negative [delta]) or away from the centroid.
List<ui.Offset> _offsetFromCentroid(List<ui.Offset> points, double delta) {
  if (points.length < 3 || delta == 0) return points;
  var cx = 0.0, cy = 0.0;
  for (final p in points) {
    cx += p.dx;
    cy += p.dy;
  }
  cx /= points.length;
  cy /= points.length;
  final c = ui.Offset(cx, cy);
  ui.Offset moved(ui.Offset p) {
    final d = p - c;
    final len = d.distance;
    if (len < 1) return p;
    return p + d / len * delta;
  }
  return [for (final p in points) moved(p)];
}

List<ui.Offset> _browHole(
  Face face,
  FaceContourType top,
  FaceContourType bottom,
  double scale,
  double dilate,
) {
  final points = [
    ..._contourPoints(face, top),
    ..._contourPoints(face, bottom),
  ];
  final hull = _convexHull(points);
  if (hull.length < 3) return const [];
  return _offsetFromCentroid(_scaledPoints(hull, scale), dilate);
}

double _averageY(List<ui.Offset> points, double fallback) {
  if (points.isEmpty) return fallback;
  return points.map((p) => p.dy).reduce((a, b) => a + b) / points.length;
}

_ContourRegionPlan? _planContourRegions(
  Face face,
  double scale,
  int width,
  int height,
) {
  final faceOvalSource = _contourPoints(face, FaceContourType.face);
  final leftEyeSource = _contourPoints(face, FaceContourType.leftEye);
  final rightEyeSource = _contourPoints(face, FaceContourType.rightEye);

  // These three are the minimum contours needed to make a useful skin mask.
  if (faceOvalSource.length < 3 ||
      leftEyeSource.length < 3 ||
      rightEyeSource.length < 3) {
    return null;
  }

  final upperLip = _contourPoints(face, FaceContourType.upperLipTop);
  final lowerLip = _contourPoints(face, FaceContourType.lowerLipBottom);
  final mouthSource = _convexHull([...upperLip, ...lowerLip]);

  final box = face.boundingBox;
  final faceCenterX = box.center.dx;
  final eyebrowY = [
    ..._contourPoints(face, FaceContourType.leftEyebrowBottom),
    ..._contourPoints(face, FaceContourType.rightEyebrowBottom),
  ];
  final noseY = _contourPoints(face, FaceContourType.noseBottom);
  final mouthY = [...upperLip, ...lowerLip];
  final foreheadBottom = _averageY(eyebrowY, box.top + box.height * 0.38);
  final noseBridgeBottom = _averageY(noseY, box.top + box.height * 0.58);
  final cheekBottom = _averageY(mouthY, box.top + box.height * 0.70);
  final chinY = faceOvalSource.map((p) => p.dy).reduce(math.max);
  final jawBottom = cheekBottom + (chinY - cheekBottom) * 0.75;

  final scaledBox = ui.Rect.fromLTRB(
    box.left * scale,
    box.top * scale,
    box.right * scale,
    box.bottom * scale,
  );
  final erode = math.max(4.0, scaledBox.width * 0.045);
  final browDilate = math.max(3.0, scaledBox.width * 0.018);
  final faceOval = _offsetFromCentroid(_scaledPoints(faceOvalSource, scale), -erode);
  final leftBrow = _browHole(face, FaceContourType.leftEyebrowTop, FaceContourType.leftEyebrowBottom, scale, browDilate);
  final rightBrow = _browHole(face, FaceContourType.rightEyebrowTop, FaceContourType.rightEyebrowBottom, scale, browDilate);
  final nose = _scaledPoints(_contourPoints(face, FaceContourType.noseBottom), scale);
  ui.Offset? nostrilCenter;
  var nostrilRadius = 0.0;
  if (nose.length >= 2) {
    var nx = 0.0, ny = 0.0;
    for (final p in nose) {
      nx += p.dx;
      ny += p.dy;
    }
    nostrilCenter = ui.Offset(nx / nose.length, ny / nose.length);
    nostrilRadius = math.max(4.0, scaledBox.width * 0.045);
  }

  final bands = _RegionBands(
    foreheadBottom: foreheadBottom * scale,
    noseBridgeBottom: noseBridgeBottom * scale,
    cheekBottom: cheekBottom * scale,
    jawBottom: jawBottom * scale,
    faceCenterX: faceCenterX * scale,
    centerHalfWidth: box.width * scale * 0.09,
  );
  final ovalTop = faceOval.map((p) => p.dy).reduce(math.min);
  final foreheadTop = ovalTop + (bands.foreheadBottom - ovalTop) * 0.34;

  final plan = _ContourRegionPlan(
    faceOval: faceOval,
    leftEyeHole: _scaledPoints(leftEyeSource, scale),
    rightEyeHole: _scaledPoints(rightEyeSource, scale),
    mouthHole: _scaledPoints(mouthSource, scale),
    leftBrowHole: leftBrow,
    rightBrowHole: rightBrow,
    nostrilCenter: nostrilCenter,
    nostrilRadius: nostrilRadius,
    foreheadTop: foreheadTop,
    bands: bands,
    faceBox: scaledBox,
  );

  // Reject obviously unusable geometry before handing it to the isolate.
  final bounds = plan.faceOval.fold<ui.Rect?>(null, (current, point) {
    final one = ui.Rect.fromLTWH(point.dx, point.dy, 0, 0);
    return current == null ? one : current.expandToInclude(one);
  });
  if (bounds == null || bounds.width < 8 || bounds.height < 8) {
    return null;
  }
  if (bounds.left >= width || bounds.top >= height ||
      bounds.right < 0 || bounds.bottom < 0) {
    return null;
  }
  return plan;
}

String? _regionForPoint(ui.Offset point, _RegionBands bands) {
  if (point.dy < bands.foreheadBottom) return 'forehead';
  if (point.dy < bands.noseBridgeBottom) {
    if ((point.dx - bands.faceCenterX).abs() < bands.centerHalfWidth) {
      return 'nose_bridge';
    }
    return point.dx < bands.faceCenterX ? 'left_cheek' : 'right_cheek';
  }
  if (point.dy < bands.cheekBottom) {
    return point.dx < bands.faceCenterX ? 'left_cheek' : 'right_cheek';
  }
  if (point.dy <= bands.jawBottom) return 'jaw';
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pixel work — runs in a background isolate
// ─────────────────────────────────────────────────────────────────────────────

class _SampleRequest {
  const _SampleRequest({
    required this.rgba,
    required this.width,
    required this.height,
    required this.patches,
    required this.contourPlan,
    required this.illuminantStride,
    required this.seekWhiteReference,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final List<_PatchPlan> patches;
  final _ContourRegionPlan? contourPlan;
  final int illuminantStride;
  final bool seekWhiteReference;
}

class _SampleOutcome {
  const _SampleOutcome(this.patches, this.illuminant, this.whiteReference);

  final List<SkinPatchSample> patches;
  final Map<String, int>? illuminant;
  final Map<String, int>? whiteReference;
}

_SampleOutcome _measureInIsolate(_SampleRequest req) {
  var patches = req.contourPlan != null
      ? _measureContourRegions(req.rgba, req.width, req.height, req.contourPlan!)
      : <SkinPatchSample>[];
  if (req.contourPlan == null || patches.length < 3) {
    patches = req.patches
        .map((plan) => _measurePatch(req.rgba, req.width, plan))
        .whereType<SkinPatchSample>()
        .toList();
  }
  final faceBox = req.contourPlan?.faceBox ?? _boxAroundPatches(req.patches);
  return _SampleOutcome(
    patches,
    _estimateIlluminant(
      req.rgba,
      req.width,
      req.height,
      req.illuminantStride,
      faceBox: faceBox,
      leftEye: req.contourPlan?.leftEyeHole,
      rightEye: req.contourPlan?.rightEyeHole,
    ),
    req.seekWhiteReference
        ? _findWhiteReference(
            req.rgba,
            req.width,
            req.height,
            faceOval: req.contourPlan?.faceOval,
            faceBox: faceBox,
          )
        : null,
  );
}

/// Median colour of one disc, after rejecting highlights, shadows and outliers.
///
/// Two passes. The first collects every pixel in the disc that is not blown out or
/// in deep shadow and records its L*; the second keeps only those within ±1.5σ of
/// the patch's mean L* and takes the per-channel median of the survivors.
///
/// The ±1.5σ pass is the step that makes this usable in a real room. A cheek in
/// ordinary indoor light contains a specular sheen a few stops brighter than the
/// skin and a shadow at the edge of the disc; both are the colour of the *light*,
/// not of the person. Averaging them in is exactly why naive implementations
/// report everyone as lighter and less saturated than they are.
SkinPatchSample? _measurePatch(Uint8List rgba, int width, _PatchPlan plan) {
  final rs = <int>[];
  final gs = <int>[];
  final bs = <int>[];
  final ls = <double>[];

  final r2 = plan.radius * plan.radius;

  for (var dy = -plan.radius; dy <= plan.radius; dy++) {
    final y = plan.cy + dy;
    final rowStart = y * width;
    for (var dx = -plan.radius; dx <= plan.radius; dx++) {
      if (dx * dx + dy * dy > r2) continue; // disc, not square
      final i = (rowStart + plan.cx + dx) * 4;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      final alpha = rgba[i + 3];

      if (alpha < 250) continue; // transparent — not image content
      if (r >= _specularCeiling || g >= _specularCeiling || b >= _specularCeiling) {
        continue; // specular reflection: the lamp's colour, not the skin's
      }

      final l = luminanceLStar(r, g, b);
      if (l < _shadowFloorLStar) continue; // deep shadow carries no chroma

      rs.add(r);
      gs.add(g);
      bs.add(b);
      ls.add(l);
    }
  }

  return _summarizePixels(plan.region, rs, gs, bs, ls);
}

SkinPatchSample? _summarizePixels(
  String region,
  List<int> rs,
  List<int> gs,
  List<int> bs,
  List<double> ls,
) {
  if (ls.length < 12) return null;

  // Mean and σ of L* over the survivors.
  var sum = 0.0;
  for (final l in ls) {
    sum += l;
  }
  final mean = sum / ls.length;
  var varSum = 0.0;
  for (final l in ls) {
    final d = l - mean;
    varSum += d * d;
  }
  final sigma = math.sqrt(varSum / ls.length);

  // Second pass: keep the middle of the luminance distribution.
  final keptR = <int>[];
  final keptG = <int>[];
  final keptB = <int>[];
  final keptL = <double>[];

  // A perfectly flat patch has σ = 0 and would reject everything but the exact
  // mean, so in that case keep the lot — there is nothing to reject.
  final band = sigma < 0.5 ? double.infinity : _rejectSigma * sigma;

  for (var i = 0; i < ls.length; i++) {
    if ((ls[i] - mean).abs() > band) continue;
    keptR.add(rs[i]);
    keptG.add(gs[i]);
    keptB.add(bs[i]);
    keptL.add(ls[i]);
  }

  if (keptL.length < 12) return null;

  final chromas = <double>[];
  final hues = <double>[];
  for (var i = 0; i < keptL.length; i++) {
    final lab = rgbToLab(keptR[i], keptG[i], keptB[i]);
    chromas.add(math.sqrt(lab.a * lab.a + lab.b * lab.b));
    final deg = math.atan2(lab.b, lab.a) * 180 / math.pi;
    hues.add(deg < 0 ? deg + 360 : deg);
  }
  final medianChroma = _medianDouble(chromas);
  final hueR = <int>[];
  final hueG = <int>[];
  final hueB = <int>[];
  final hueL = <double>[];
  for (var i = 0; i < keptL.length; i++) {
    final c = chromas[i];
    // Hue is meaningless near grey. Deep skin can be low-chroma and must stay.
    final hueOk = c < 4 || (hues[i] >= 15 && hues[i] <= 90);
    final chromaOk = (c - medianChroma).abs() <= math.max(12.0, medianChroma * 0.85);
    if (!hueOk || !chromaOk) continue;
    hueR.add(keptR[i]);
    hueG.add(keptG[i]);
    hueB.add(keptB[i]);
    hueL.add(keptL[i]);
  }
  if (hueL.length >= 12) {
    keptR
      ..clear()
      ..addAll(hueR);
    keptG
      ..clear()
      ..addAll(hueG);
    keptB
      ..clear()
      ..addAll(hueB);
    keptL
      ..clear()
      ..addAll(hueL);
  }

  var keptSum = 0.0;
  for (final l in keptL) {
    keptSum += l;
  }
  final keptMean = keptSum / keptL.length;
  var keptVar = 0.0;
  for (final l in keptL) {
    final d = l - keptMean;
    keptVar += d * d;
  }

  return SkinPatchSample(
    region: region,
    r: _median(keptR),
    g: _median(keptG),
    b: _median(keptB),
    pixels: keptL.length,
    luminanceStdDev: math.sqrt(keptVar / keptL.length),
    regionWeight: _regionWeights[region] ?? 1,
  );
}

List<SkinPatchSample> _measureContourRegions(
  Uint8List rgba,
  int width,
  int height,
  _ContourRegionPlan plan,
) {
  final regions = <String, List<List<num>>>{
    'forehead': [<int>[], <int>[], <int>[], <double>[]],
    'left_cheek': [<int>[], <int>[], <int>[], <double>[]],
    'right_cheek': [<int>[], <int>[], <int>[], <double>[]],
    'jaw': [<int>[], <int>[], <int>[], <double>[]],
    'nose_bridge': [<int>[], <int>[], <int>[], <double>[]],
  };

  final minX = plan.faceOval.map((p) => p.dx).reduce(math.min).floor().clamp(0, width - 1);
  final maxX = plan.faceOval.map((p) => p.dx).reduce(math.max).ceil().clamp(0, width - 1);
  final minY = plan.faceOval.map((p) => p.dy).reduce(math.min).floor().clamp(0, height - 1);
  final maxY = plan.faceOval.map((p) => p.dy).reduce(math.max).ceil().clamp(0, height - 1);

  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final point = ui.Offset(x.toDouble(), y.toDouble());
      if (!_pointInPolygon(point, plan.faceOval) ||
          point.dy < plan.foreheadTop ||
          _pointInPolygon(point, plan.leftEyeHole) ||
          _pointInPolygon(point, plan.rightEyeHole) ||
          _pointInPolygon(point, plan.mouthHole) ||
          _pointInPolygon(point, plan.leftBrowHole) ||
          _pointInPolygon(point, plan.rightBrowHole) ||
          _inDisc(point, plan.nostrilCenter, plan.nostrilRadius)) {
        continue;
      }

      final region = _regionForPoint(point, plan.bands);
      if (region == null) continue;
      final i = (y * width + x) * 4;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      if (rgba[i + 3] < 250 ||
          r >= _specularCeiling ||
          g >= _specularCeiling ||
          b >= _specularCeiling) {
        continue;
      }
      final l = luminanceLStar(r, g, b);
      if (l < _shadowFloorLStar) continue;
      final bucket = regions[region]!;
      (bucket[0] as List<int>).add(r);
      (bucket[1] as List<int>).add(g);
      (bucket[2] as List<int>).add(b);
      (bucket[3] as List<double>).add(l);
    }
  }

  final result = <SkinPatchSample>[];
  for (final entry in regions.entries) {
    final bucket = entry.value;
    final sample = _summarizePixels(
      entry.key,
      bucket[0] as List<int>,
      bucket[1] as List<int>,
      bucket[2] as List<int>,
      bucket[3] as List<double>,
    );
    if (sample != null) result.add(sample);
  }
  return result;
}

int _median(List<int> values) {
  values.sort();
  final mid = values.length ~/ 2;
  if (values.length.isOdd) return values[mid];
  return ((values[mid - 1] + values[mid]) / 2).round();
}

/// Scene illuminant from pixels *outside* the face.
///
/// A shades-of-grey average over the face converges on skin and then divides
/// skin by skin, which is how a reading loses its chroma. Background pixels are
/// the light. Very dark pixels and specular pixels are left out. If there are
/// not enough of them, a small bright low-chroma sample inside the eye contours
/// (sclera) is tried. If that fails too, null is returned and the server skips
/// the correction.
Map<String, int>? _estimateIlluminant(
  Uint8List rgba,
  int width,
  int height,
  int stride, {
  ui.Rect? faceBox,
  List<ui.Offset>? leftEye,
  List<ui.Offset>? rightEye,
}) {
  final exclusion = faceBox?.inflate(math.max(8, faceBox.width * 0.12));

  final estimate = _shadesOfGrey(
    rgba,
    width,
    height,
    stride,
    accept: (x, y, r, g, b) {
      if (r >= _specularCeiling || g >= _specularCeiling || b >= _specularCeiling) {
        return false;
      }
      if (luminanceLStar(r, g, b) < 18) return false;
      if (exclusion != null && exclusion.contains(ui.Offset(x.toDouble(), y.toDouble()))) {
        return false;
      }
      return true;
    },
  );
  if (estimate != null) return estimate;

  final sclera = _medianOfMask(
    rgba,
    width,
    height,
    accept: (x, y, r, g, b) {
      final point = ui.Offset(x.toDouble(), y.toDouble());
      final inEye = (leftEye != null && _pointInPolygon(point, leftEye)) ||
          (rightEye != null && _pointInPolygon(point, rightEye));
      if (!inEye) return false;
      if (r >= _specularCeiling || g >= _specularCeiling || b >= _specularCeiling) {
        return false;
      }
      final lab = rgbToLab(r, g, b);
      final c = math.sqrt(lab.a * lab.a + lab.b * lab.b);
      return lab.l > 58 && c < 12;
    },
    minimum: 12,
  );
  return sclera;
}

/// Bright, low-chroma pixels outside the face oval — a sheet of paper.
Map<String, int>? _findWhiteReference(
  Uint8List rgba,
  int width,
  int height, {
  List<ui.Offset>? faceOval,
  ui.Rect? faceBox,
}) {
  final stride = math.max(1, _strideFor(width, height));
  return _medianOfMask(
    rgba,
    width,
    height,
    stride: stride,
    accept: (x, y, r, g, b) {
      final point = ui.Offset(x.toDouble(), y.toDouble());
      if (faceOval != null && faceOval.length >= 3 && _pointInPolygon(point, faceOval)) {
        return false;
      }
      if ((faceOval == null || faceOval.length < 3) &&
          faceBox != null &&
          faceBox.contains(point)) {
        return false;
      }
      if (r >= 252 && g >= 252 && b >= 252) return false;
      final lab = rgbToLab(r, g, b);
      final c = math.sqrt(lab.a * lab.a + lab.b * lab.b);
      return lab.l >= 82 && c <= 10;
    },
    minimum: 40,
  );
}

Map<String, int>? _shadesOfGrey(
  Uint8List rgba,
  int width,
  int height,
  int stride, {
  required bool Function(int x, int y, int r, int g, int b) accept,
}) {
  var sr = 0.0, sg = 0.0, sb = 0.0;
  var n = 0;
  for (var y = 0; y < height; y += stride) {
    final rowStart = y * width;
    for (var x = 0; x < width; x += stride) {
      final i = (rowStart + x) * 4;
      if (rgba[i + 3] < 250) continue;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      if (!accept(x, y, r, g, b)) continue;
      final rr = r / 255.0;
      final gg = g / 255.0;
      final bb = b / 255.0;
      sr += rr * rr * rr * rr * rr * rr;
      sg += gg * gg * gg * gg * gg * gg;
      sb += bb * bb * bb * bb * bb * bb;
      n++;
    }
  }
  if (n < 80) return null;
  double norm(double s) => math.pow(s / n, 1 / 6).toDouble() * 255;
  final r = norm(sr).round().clamp(0, 255);
  final g = norm(sg).round().clamp(0, 255);
  final b = norm(sb).round().clamp(0, 255);
  if (r + g + b < 3) return null;
  return {'r': r, 'g': g, 'b': b};
}

Map<String, int>? _medianOfMask(
  Uint8List rgba,
  int width,
  int height, {
  int stride = 1,
  required bool Function(int x, int y, int r, int g, int b) accept,
  required int minimum,
}) {
  final rs = <int>[];
  final gs = <int>[];
  final bs = <int>[];
  for (var y = 0; y < height; y += stride) {
    final rowStart = y * width;
    for (var x = 0; x < width; x += stride) {
      final i = (rowStart + x) * 4;
      if (rgba[i + 3] < 250) continue;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      if (!accept(x, y, r, g, b)) continue;
      rs.add(r);
      gs.add(g);
      bs.add(b);
    }
  }
  if (rs.length < minimum) return null;
  return {'r': _median(rs), 'g': _median(gs), 'b': _median(bs)};
}

ui.Rect? _boxAroundPatches(List<_PatchPlan> patches) {
  if (patches.isEmpty) return null;
  var left = patches.first.cx.toDouble();
  var top = patches.first.cy.toDouble();
  var right = left;
  var bottom = top;
  for (final p in patches) {
    left = math.min(left, (p.cx - p.radius).toDouble());
    top = math.min(top, (p.cy - p.radius).toDouble());
    right = math.max(right, (p.cx + p.radius).toDouble());
    bottom = math.max(bottom, (p.cy + p.radius).toDouble());
  }
  return ui.Rect.fromLTRB(left, top, right, bottom);
}

bool _inDisc(ui.Offset point, ui.Offset? center, double radius) {
  if (center == null || radius <= 0) return false;
  return (point - center).distance <= radius;
}

SkinSampleResult _mergeFrames(List<SkinSampleResult> frames) {
  final byRegion = <String, List<SkinPatchSample>>{};
  for (final frame in frames) {
    for (final patch in frame.patches) {
      byRegion.putIfAbsent(patch.region, () => []).add(patch);
    }
  }
  final patches = <SkinPatchSample>[];
  for (final entry in byRegion.entries) {
    final group = entry.value;
    patches.add(SkinPatchSample(
      region: entry.key,
      r: _median(group.map((p) => p.r).toList()),
      g: _median(group.map((p) => p.g).toList()),
      b: _median(group.map((p) => p.b).toList()),
      pixels: _median(group.map((p) => p.pixels).toList()),
      luminanceStdDev: _medianDouble(group.map((p) => p.luminanceStdDev).toList()),
      regionWeight: group.first.regionWeight,
    ));
  }
  final first = frames.first;
  return SkinSampleResult(
    patches: patches,
    illuminant: _medianRgb(frames.map((f) => f.illuminant).whereType<Map<String, int>>().toList()),
    whiteReference: _medianRgb(
      frames.map((f) => f.whiteReference).whereType<Map<String, int>>().toList(),
    ),
    imageWidth: first.imageWidth,
    imageHeight: first.imageHeight,
    faceRatio: frames.map((f) => f.faceRatio).reduce(math.max),
    headYaw: first.headYaw,
    headRoll: first.headRoll,
  );
}

Map<String, int>? _medianRgb(List<Map<String, int>> values) {
  if (values.isEmpty) return null;
  return {
    'r': _median(values.map((v) => v['r'] ?? 0).toList()),
    'g': _median(values.map((v) => v['g'] ?? 0).toList()),
    'b': _median(values.map((v) => v['b'] ?? 0).toList()),
  };
}

double _medianDouble(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}
