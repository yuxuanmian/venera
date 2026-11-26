import 'dart:math' as math;

import 'package:flutter/material.dart';

class BookletPainter extends CustomPainter {
  static const _designSize = Size(60, 42);

  BookletPainter({
    required this.turn,
    required this.ink,
    required this.paper,
    required this.leaf,
  }) : super(repaint: turn);

  final Animation<double> turn;
  final Color ink;
  final Color paper;
  final Color leaf;

  Path _page(double edge, double lift) => Path()
    ..moveTo(30, 12)
    ..quadraticBezierTo((30 + edge) / 2, 4 - lift, edge, 8 - lift)
    ..lineTo(edge, 33 - lift)
    ..quadraticBezierTo((30 + edge) / 2, 30 - lift, 30, 37)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / _designSize.width,
      size.height / _designSize.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - _designSize.width * scale) / 2,
      (size.height - _designSize.height * scale) / 2,
    );
    canvas.scale(scale);
    final fill = Paint()..color = paper;
    final outline = Paint()
      ..color = ink
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final edge in [6.0, 54.0]) {
      final page = _page(edge, 0);
      canvas.drawPath(page, fill);
      canvas.drawPath(page, outline);
      final middle = (30 + edge) / 2;
      final rule = Paint()
        ..color = ink.withValues(alpha: .35)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(middle - 5, 16), Offset(middle + 5, 17), rule);
      canvas.drawLine(Offset(middle - 5, 21), Offset(middle + 5, 22), rule);
    }
    final progress = const Interval(
      .12,
      .77,
      curve: Curves.easeInOut,
    ).transform(turn.value);
    final visibility = 1 - const Interval(.81, .96).transform(turn.value);
    final angle = progress * math.pi;
    final sheet = _page(30 + 24 * math.cos(angle), 5 * math.sin(angle));
    canvas.drawPath(sheet, fill..color = leaf.withValues(alpha: visibility));
    canvas.drawPath(sheet, outline..color = ink.withValues(alpha: visibility));
    canvas.restore();
  }

  @override
  bool shouldRepaint(BookletPainter oldDelegate) =>
      turn != oldDelegate.turn ||
      ink != oldDelegate.ink ||
      paper != oldDelegate.paper ||
      leaf != oldDelegate.leaf;
}
