import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_colors.dart';

/// Website ring spinner, drawn natively.
///
/// The look page defines `.spinner`: a 40px circle, a 2.5px track in
/// `--border-soft`, a rose `--rose-primary` top edge, spinning with
/// `ld-spin` for 0.75s linear. [AppLoader.inline] is the same ring at
/// button size. When animations are disabled the arc stays at the top.
class AppLoader extends StatefulWidget {
  const AppLoader({
    super.key,
    this.size = 40,
    this.color,
    this.strokeWidth,
    this.label,
    this.centered = false,
  }) : inline = false;

  const AppLoader.centered({
    super.key,
    this.size = 40,
    this.color,
    this.strokeWidth,
    this.label,
  })  : centered = true,
        inline = false;

  const AppLoader.inline({
    super.key,
    this.size = 18,
    this.color,
    this.strokeWidth,
  })  : centered = false,
        inline = true,
        label = null;

  /// Outer diameter. The website's named spinner is 40.
  final double size;

  /// Arc color. Null uses [AppColors.primary] on an [AppColors.border] track,
  /// matching `--rose-primary` on `--border-soft`.
  final Color? color;

  final double? strokeWidth;

  /// Optional caption for [AppLoader.centered].
  final String? label;

  final bool centered;

  /// Button-sized ring. Stroke stays near the site's 2px button spinner.
  final bool inline;

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (disabled) {
      if (_controller.isAnimating) _controller.stop();
      if (_controller.value != 0) _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _stroke {
    final requested = widget.strokeWidth;
    if (requested != null) return requested;
    if (widget.inline) return 2;
    return 2.5 * widget.size / 40;
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final head = widget.color ?? AppColors.primary;
    final track = widget.color == null
        ? AppColors.border
        : widget.color!.withValues(alpha: 0.22);

    final disabled = MediaQuery.disableAnimationsOf(context);
    final spinner = Semantics(
      label: 'Loading',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              painter: AppLoaderPainter(
                turns: disabled ? 0 : _controller.value,
                track: track,
                head: head,
                strokeWidth: _stroke,
              ),
            );
          },
        ),
      ),
    );

    if (!widget.centered) return spinner;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          spinner,
          if (widget.label != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                widget.label!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Quarter-arc ring. [turns] is the rotation in full circles (0–1).
class AppLoaderPainter extends CustomPainter {
  AppLoaderPainter({
    required this.turns,
    required this.track,
    required this.head,
    required this.strokeWidth,
  });

  final double turns;
  final Color track;
  final Color head;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = track
        ..isAntiAlias = true,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2 + turns * math.pi * 2,
      math.pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = head
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(AppLoaderPainter oldDelegate) {
    return oldDelegate.turns != turns ||
        oldDelegate.track != track ||
        oldDelegate.head != head ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
