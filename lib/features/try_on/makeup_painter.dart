import 'package:flutter/material.dart';

class MakeupPainter extends CustomPainter {
  final List<List<Map<String, double>>> faces;
  final bool isFrontCamera;
  final double intensity; // legacy / fallback

  // Multi-category: each category has its own color and intensity
  final Map<String, Color> categoryShades;
  final Map<String, double> categoryIntensities;

  // Legacy single-category (kept for backward compat)
  final Color selectedShade;
  final String category;

  const MakeupPainter({
    required this.faces,
    required this.isFrontCamera,
    this.intensity = 0.7,
    this.categoryShades = const {},
    this.categoryIntensities = const {},
    this.selectedShade = Colors.transparent,
    this.category = '',
  });

  Path _closedLipPath(
    List<Map<String, double>> pts,
    Size size,
    bool isFrontCamera, {
    required List<int> upper,
    required List<int> lower,
    bool expandCornersOnly = false,
    double upperLiftPx = 0.0,
  }) {
    final allPoints = <Offset>[];

    List<Offset> mapIndices(List<int> indices) {
      return indices.map((i) {
        final p = pts[i];
        final rawX = p['x'] ?? 0.0;
        final rawY = p['y'] ?? 0.0;

        double x = rawY;
        double y = 1.0 - rawX;

        if (isFrontCamera) x = 1.0 - x;

        return Offset(x * size.width, y * size.height);
      }).toList();
    }

    final upperPts = mapIndices(upper);
    final lowerPts = mapIndices(lower);

    // Lift upper lip slightly upward
    if (upperLiftPx != 0.0 && upperPts.length >= 7) {
      for (int i = 1; i < upperPts.length - 1; i++) {
        final mid = (upperPts.length - 1) / 2.0;
        final distFromMid = (i - mid).abs();
        final normalized = distFromMid / mid;
        final t = 1.0 - (normalized * 0.6);

        upperPts[i] = Offset(
          upperPts[i].dx,
          upperPts[i].dy - (upperLiftPx * t),
        );
      }
    }

    allPoints.addAll(upperPts);
    allPoints.addAll(lowerPts.reversed);

    if (allPoints.isEmpty) return Path();

    // Expand only corners
    if (expandCornersOnly) {
      double minX = allPoints.first.dx;
      double maxX = allPoints.first.dx;

      for (final p in allPoints) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
      }

      final width = maxX - minX;
      final threshold = width * 0.12;
      const expandPx = 4.0;

      for (int i = 0; i < allPoints.length; i++) {
        final p = allPoints[i];

        if ((p.dx - minX).abs() <= threshold) {
          allPoints[i] = Offset(p.dx - expandPx, p.dy);
        } else if ((maxX - p.dx).abs() <= threshold) {
          allPoints[i] = Offset(p.dx + expandPx, p.dy);
        }
      }
    }

    final path = Path();
    path.moveTo(allPoints.first.dx, allPoints.first.dy);

    for (int i = 0; i < allPoints.length; i++) {
      final current = allPoints[i];
      final next = allPoints[(i + 1) % allPoints.length];

      final mid = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );

      path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
    }

    path.close();
    return path;
  }

  Offset _mapPoint(Map<String, double> p, Size size, bool isFrontCamera) {
    final rawX = p['x'] ?? 0.0;
    final rawY = p['y'] ?? 0.0;

    double x = rawY;
    double y = 1.0 - rawX;

    if (isFrontCamera) x = 1.0 - x;

    return Offset(x * size.width, y * size.height);
  }

  Offset _mid(Offset a, Offset b) {
    return Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  }

  void _drawBlush(
    Canvas canvas,
    Size size,
    List<Map<String, double>> face,
    Color color,
    double intensity,
  ) {
    final leftCheekOuter = _mapPoint(face[234], size, isFrontCamera);
    final leftNoseSide = _mapPoint(face[98], size, isFrontCamera);
    final leftEyeLower = _mapPoint(face[50], size, isFrontCamera);

    final rightCheekOuter = _mapPoint(face[454], size, isFrontCamera);
    final rightNoseSide = _mapPoint(face[327], size, isFrontCamera);
    final rightEyeLower = _mapPoint(face[280], size, isFrontCamera);

    final leftCenter = _mid(leftCheekOuter, leftNoseSide);
    final rightCenter = _mid(rightCheekOuter, rightNoseSide);

    final leftBlushCenter = Offset(
      leftCenter.dx,
      ((leftCenter.dy + leftEyeLower.dy) / 2) + 12,
    );

    final rightBlushCenter = Offset(
      rightCenter.dx,
      ((rightCenter.dy + rightEyeLower.dy) / 2) + 12,
    );

    final leftFaceEdge = _mapPoint(face[234], size, isFrontCamera);
    final rightFaceEdge = _mapPoint(face[454], size, isFrontCamera);
    final faceWidth = (rightFaceEdge.dx - leftFaceEdge.dx).abs();

    final blushRadius = faceWidth * 0.13;

    final blushPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withOpacity((0.22 + intensity * 0.35).clamp(0.22, 0.55))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

    canvas.drawCircle(leftBlushCenter, blushRadius, blushPaint);
    canvas.drawCircle(rightBlushCenter, blushRadius, blushPaint);
  }

  void _drawLipstick(
    Canvas canvas,
    Size size,
    List<Map<String, double>> face,
    Color color,
    double intensity,
  ) {
    const outerUpperLip = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291];
    const outerLowerLip = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291];
    const innerUpperLip = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308];
    const innerLowerLip = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308];

    final outer = _closedLipPath(
      face,
      size,
      isFrontCamera,
      upper: outerUpperLip,
      lower: outerLowerLip,
      expandCornersOnly: true,
      upperLiftPx: 3.0,
    );
    final inner = _closedLipPath(
      face,
      size,
      isFrontCamera,
      upper: innerUpperLip,
      lower: innerLowerLip,
    );

    final lipPath = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(
      lipPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withOpacity(intensity.clamp(0.0, 1.0)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty) return;
    final face = faces.first;

    // Multi-category mode — draw all active categories simultaneously
    if (categoryShades.isNotEmpty) {
      final lip = categoryShades['lipstick'];
      if (lip != null && lip != Colors.transparent) {
        final lipIntensity = categoryIntensities['lipstick'] ?? intensity;
        _drawLipstick(canvas, size, face, lip, lipIntensity);
      }
      final blush = categoryShades['blush'];
      if (blush != null && blush != Colors.transparent) {
        final blushIntensity = categoryIntensities['blush'] ?? intensity;
        _drawBlush(canvas, size, face, blush, blushIntensity);
      }
      return;
    }

    // Legacy single-category mode
    if (category == 'lipstick') {
      _drawLipstick(canvas, size, face, selectedShade, intensity);
    } else if (category == 'blush') {
      _drawBlush(canvas, size, face, selectedShade, intensity);
    }
  }

  @override
  bool shouldRepaint(covariant MakeupPainter oldDelegate) =>
      oldDelegate.faces != faces ||
      oldDelegate.isFrontCamera != isFrontCamera ||
      oldDelegate.categoryShades != categoryShades ||
      oldDelegate.categoryIntensities != categoryIntensities ||
      oldDelegate.selectedShade != selectedShade ||
      oldDelegate.intensity != intensity ||
      oldDelegate.category != category;
}
