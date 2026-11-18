import 'package:flutter/material.dart';

/// A numbered medal for one of the first three places in a ranking.
class RankingMedal extends StatelessWidget {
  const RankingMedal({super.key, required this.rank})
    : assert(rank >= 1 && rank <= 3);

  final int rank;

  @override
  Widget build(BuildContext context) {
    final (highlight, shade, rim, ribbon, ink) = switch (rank) {
      1 => const (
        Color(0xFFFFF1C7),
        Color(0xFFDB9F3D),
        Color(0xFF94601E),
        Color(0xFFBA7E2D),
        Color(0xFF4D2D0C),
      ),
      2 => const (
        Color(0xFFF5F8FF),
        Color(0xFFAEBACC),
        Color(0xFF69778A),
        Color(0xFF8494A9),
        Color(0xFF28364A),
      ),
      3 => const (
        Color(0xFFFFE0C7),
        Color(0xFFD38B63),
        Color(0xFF83482E),
        Color(0xFFA95439),
        Color(0xFF4E291A),
      ),
      _ => throw ArgumentError.value(rank, 'rank', 'Expected 1, 2, or 3'),
    };

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: 44,
        height: 51,
        child: CustomPaint(
          painter: _MedalPainter(
            highlight: highlight,
            shade: shade,
            rim: rim,
            ribbon: ribbon,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: Text(
                  '$rank',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: ink,
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MedalPainter extends CustomPainter {
  const _MedalPainter({
    required this.highlight,
    required this.shade,
    required this.rim,
    required this.ribbon,
  });

  final Color highlight;
  final Color shade;
  final Color rim;
  final Color ribbon;

  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(22, 22);
    final tails = Path()
      ..moveTo(11, 32)
      ..lineTo(8, 51)
      ..lineTo(15, 47)
      ..lineTo(20, 51)
      ..lineTo(22, 37)
      ..lineTo(24, 51)
      ..lineTo(29, 47)
      ..lineTo(36, 51)
      ..lineTo(33, 32)
      ..close();
    final face = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [highlight, shade],
      ).createShader(Rect.fromCircle(center: center, radius: 22));
    final border = Paint()
      ..color = rim
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas
      ..drawPath(tails, Paint()..color = ribbon)
      ..drawCircle(center, 21.5, face)
      ..drawCircle(center, 21.5, border)
      ..drawCircle(center, 18.5, border);
  }

  @override
  bool shouldRepaint(_MedalPainter oldDelegate) =>
      highlight != oldDelegate.highlight ||
      shade != oldDelegate.shade ||
      rim != oldDelegate.rim ||
      ribbon != oldDelegate.ribbon;
}
