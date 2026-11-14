import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps the startup art above the destination only during the handoff. The
/// destination can build and accept input as soon as it is supplied.
class StartupLogo extends StatefulWidget {
  const StartupLogo({super.key, this.child});

  final Widget? child;

  @override
  State<StartupLogo> createState() => _StartupLogoState();
}

class _StartupLogoState extends State<StartupLogo>
    with TickerProviderStateMixin {
  static const _entranceDuration = Duration(milliseconds: 560);
  static const _handoffDuration = Duration(milliseconds: 260);

  late final AnimationController _motion;
  late final AnimationController _handoff;
  late final Listenable _repaint;
  bool _breathing = false;
  bool _showLogo = true;
  double _exitFrom = 1;

  @override
  void initState() {
    super.initState();
    _showLogo = widget.child == null;
    _motion = AnimationController(vsync: this, duration: _entranceDuration)
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed ||
            _breathing ||
            widget.child != null) {
          return;
        }
        _breathing = true;
        _motion.repeat(period: const Duration(seconds: 2));
      });
    _handoff = AnimationController(vsync: this, duration: _handoffDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _showLogo) {
          setState(() => _showLogo = false);
        }
      });
    _repaint = Listenable.merge([_motion, _handoff]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _handoff.stop();
      if (widget.child != null) _showLogo = false;
    } else if (widget.child == null && !_motion.isAnimating) {
      if (_breathing) {
        _motion.repeat(period: const Duration(seconds: 2));
      } else {
        _motion.forward();
      }
    }
  }

  @override
  void didUpdateWidget(StartupLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child == null && widget.child != null) {
      _motion.stop();
      _exitFrom = _breathing ? 1 : _motion.value;
      // If readiness arrives before the lines reach the mark, skip the
      // transition instead of making the user sit through a minimum splash.
      if (MediaQuery.disableAnimationsOf(context) || _exitFrom < 0.15) {
        _showLogo = false;
      } else {
        // A ticker started during build counts time from the beginning of
        // that frame. A slow first layout/paint of the home page can spend
        // the entire transition before a single zoom frame is drawn.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _showLogo && widget.child != null) {
            _handoff.forward();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    _handoff.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (child != null) child,
        if (_showLogo)
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _StartupLogoPainter(
                  repaint: _repaint,
                  entrance: () => reducedMotion
                      ? 1
                      : child != null
                      ? _exitFrom +
                            (1 - _exitFrom) * math.min(1, _handoff.value * 4)
                      : _breathing
                      ? 1
                      : _motion.value,
                  pulse: () => child == null && _breathing && !reducedMotion
                      ? (1 - math.cos(_motion.value * math.pi * 2)) / 2
                      : 0,
                  exit: _handoff,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StartupLogoPainter extends CustomPainter {
  _StartupLogoPainter({
    required Listenable repaint,
    required this.entrance,
    required this.pulse,
    required this.exit,
  }) : super(repaint: repaint);

  final double Function() entrance;
  final double Function() pulse;
  final Animation<double> exit;

  static const _ink = Color(0xfff5f7ff);
  static const _halfExtent = 86.0;
  static const _outerTip = Offset(58, -51);
  static const _innerTip = Offset(35, -51);
  static const _outerFoot = Offset(9, 51);
  static const _outerOtherFoot = Offset(-9, 51);
  static const _outerOtherTip = Offset(-58, -51);
  static const _innerFoot = Offset(0, 24);
  static const _innerOtherTip = Offset(-35, -51);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = size.center(Offset.zero);
    final progress = entrance();
    final end = exit.value;
    final fade = 1 - ((end - 0.26) / 0.74).clamp(0.0, 1.0);
    final glow = pulse();
    final radius = math.min(size.width, size.height);

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(
              const Color(0xff202e7c),
              const Color(0xff354aa1),
              glow,
            )!.withValues(alpha: fade),
            const Color(0xff111a43).withValues(alpha: fade),
            const Color(0xff0b1128).withValues(alpha: fade),
          ],
          stops: const [0, 0.62, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(center.dx, center.dy);
    final baseScale = math.min(1.0, radius / 236);
    // Make the growth visible before the background has mostly dissolved.
    final zoom = (1 - math.cos(end * math.pi)) / 2;
    canvas.scale(baseScale * (1 + 4.5 * zoom));
    if (end == 0) {
      canvas.clipRect(
        Rect.fromCircle(center: Offset.zero, radius: _halfExtent),
      );
    }

    final stroke = Paint()
      ..color = _ink.withValues(alpha: fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final drawing = math.min(1.0, progress / 0.92);
    // The lower gap is part of the outer V. The moving tip crosses it without
    // painting a connection.
    _drawTrack(
      canvas,
      stroke,
      drawing,
      leadStart: const Offset(74.8, -_halfExtent),
      start: _outerTip,
      foot: _outerFoot,
      otherFoot: _outerOtherFoot,
      finish: _outerOtherTip,
    );
    _drawTrack(
      canvas,
      stroke,
      drawing,
      leadStart: const Offset(51.3, -_halfExtent),
      start: _innerTip,
      foot: _innerFoot,
      otherFoot: _innerFoot,
      finish: _innerOtherTip,
    );
    canvas.restore();
  }

  void _drawTrack(
    Canvas canvas,
    Paint stroke,
    double progress, {
    required Offset leadStart,
    required Offset start,
    required Offset foot,
    required Offset otherFoot,
    required Offset finish,
  }) {
    const leadFraction = 0.16;
    if (progress < leadFraction) {
      final t = progress / leadFraction;
      if (t == 0) return;
      canvas.drawLine(
        Offset.lerp(leadStart, start, math.max(0, t - 0.56))!,
        Offset.lerp(leadStart, start, t)!,
        Paint()
          ..color = const Color(0xffa6bfff).withValues(alpha: t * 0.84)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    final down = (foot - start).distance;
    final gap = (otherFoot - foot).distance;
    final up = (finish - otherFoot).distance;
    final length =
        (progress - leadFraction) / (1 - leadFraction) * (down + gap + up);
    final path = Path()..moveTo(start.dx, start.dy);
    final tip = Offset.lerp(start, foot, math.min(1, length / down))!;
    path.lineTo(tip.dx, tip.dy);
    if (length > down + gap) {
      if (gap > 0) path.moveTo(otherFoot.dx, otherFoot.dy);
      final tip = Offset.lerp(otherFoot, finish, (length - down - gap) / up)!;
      path.lineTo(tip.dx, tip.dy);
    }
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _StartupLogoPainter oldDelegate) => true;
}
