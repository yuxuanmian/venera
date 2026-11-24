import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera/foundation/app_page_route.dart';

Future<void> pushReader(
  BuildContext context,
  Widget Function() builder, {
  Offset? tapPosition,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  return navigator.push<void>(
    ReaderEntryRoute(
      builder: (_) => builder(),
      origin: tapPosition != null && overlay is RenderBox
          ? overlay.globalToLocal(tapPosition)
          : null,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    ),
  );
}

/// Reports the point that activated a normal button, with a center for keyboard
/// and accessibility activation.
class ReaderEntryTarget extends StatefulWidget {
  const ReaderEntryTarget({
    super.key,
    required this.builder,
    required this.onOpen,
  });

  final Widget Function(VoidCallback onPressed) builder;
  final ValueChanged<Offset> onOpen;

  @override
  State<ReaderEntryTarget> createState() => _ReaderEntryTargetState();
}

class _ReaderEntryTargetState extends State<ReaderEntryTarget> {
  PointerDownEvent? _down;

  void _open() {
    final box = context.findRenderObject()! as RenderBox;
    final position =
        _down?.position ?? box.localToGlobal(box.size.center(Offset.zero));
    _down = null;
    widget.onOpen(position);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) => _down = event,
      onPointerCancel: (event) {
        if (_down?.pointer == event.pointer) _down = null;
      },
      onPointerUp: (event) {
        final down = _down;
        if (down?.pointer != event.pointer) return;
        scheduleMicrotask(() {
          if (identical(_down, down)) _down = null;
        });
      },
      child: widget.builder(_open),
    );
  }
}

enum ReaderEntryMotion { circle, panels }

class ReaderEntryRoute extends AppPageRoute<void> {
  ReaderEntryRoute({
    required super.builder,
    this.origin,
    this.reduceMotion = false,
    ReaderEntryMotion? motion,
  }) : motion =
           motion ??
           ReaderEntryMotion.values[_random.nextInt(
             ReaderEntryMotion.values.length,
           )];

  static final _random = math.Random();
  final Offset? origin;
  final bool reduceMotion;
  final ReaderEntryMotion motion;

  bool _entered = false;
  Route<dynamic>? _previous;

  bool get isEntering => !reduceMotion && !_entered;

  // The route's public animation temporarily reports completion during Hero
  // layout. Entry effects follow the actual controller until the push ends.
  Animation<double> get entryAnimation => controller!.view;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 800);

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 300);

  @override
  void install() {
    super.install();
    if (!reduceMotion) controller!.addStatusListener(_onEntryStatus);
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    super.didChangePrevious(previousRoute);
    _previous = previousRoute;
  }

  void _onEntryStatus(AnimationStatus status) {
    if (_entered || status != AnimationStatus.completed) return;
    _entered = true;
    controller!.removeStatusListener(_onEntryStatus);
    // Let the route underneath drop the temporary push delegate, so both
    // routes use their usual back transition even before a gesture commits.
    final previous = _previous;
    if (isCurrent && previous != null && previous.navigator == navigator) {
      previous.didChangeNext(this);
    }
  }

  @override
  void dispose() {
    if (!reduceMotion && !_entered) {
      controller?.removeStatusListener(_onEntryStatus);
    }
    super.dispose();
  }

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      isEntering ? _buildOutgoing : null;

  Widget? _buildOutgoing(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (!isEntering || child == null) return child;
    if (motion == ReaderEntryMotion.panels && allowSnapshotting) {
      return _ReaderPanelSnapshot(
        animation: secondaryAnimation,
        edgeColor: Theme.of(context).colorScheme.outlineVariant,
        child: child,
      );
    }
    return child;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion) return child;
    if (!isEntering) {
      return super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return ClipPath(
      clipper: _ReaderEntryClipper(animation, motion, origin),
      child: child,
    );
  }
}

const _entryCurve = Cubic(.24, .68, .30, 1);

class _ReaderEntryClipper extends CustomClipper<Path> {
  _ReaderEntryClipper(this.animation, this.motion, this.origin)
    : super(reclip: animation);

  final Animation<double> animation;
  final ReaderEntryMotion motion;
  final Offset? origin;

  @override
  Path getClip(Size size) {
    final progress = animation.value;
    if (motion == ReaderEntryMotion.panels) {
      final panels = _PanelGeometry(size, progress);
      return Path()
        ..moveTo(0, panels.left - panels.topTravel)
        ..lineTo(size.width, panels.right - panels.topTravel)
        ..lineTo(size.width, panels.right + panels.bottomTravel)
        ..lineTo(0, panels.left + panels.bottomTravel)
        ..close();
    }
    final point = origin ?? size.center(Offset.zero);
    final center = Offset(
      point.dx.clamp(0.0, size.width),
      point.dy.clamp(0.0, size.height),
    );
    final dx = math.max(center.dx, size.width - center.dx);
    final dy = math.max(center.dy, size.height - center.dy);
    final radius = ui.lerpDouble(
      12,
      math.sqrt(dx * dx + dy * dy) + 1,
      _entryCurve.transform(progress),
    )!;
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(_ReaderEntryClipper oldClipper) =>
      animation != oldClipper.animation ||
      motion != oldClipper.motion ||
      origin != oldClipper.origin;
}

/// The reader is visible in the gap between the two translated edges.
class _PanelGeometry {
  _PanelGeometry(Size size, double progress)
    : left = size.height * .58,
      right = size.height * .44,
      topTravel =
          size.height *
          .64 *
          const Interval(0, .86, curve: _entryCurve).transform(progress),
      bottomTravel =
          size.height *
          .64 *
          const Interval(.14, 1, curve: _entryCurve).transform(progress);

  final double left;
  final double right;
  final double topTravel;
  final double bottomTravel;
}

class _ReaderPanelSnapshot extends StatefulWidget {
  const _ReaderPanelSnapshot({
    required this.animation,
    required this.edgeColor,
    required this.child,
  });

  final Animation<double> animation;
  final Color edgeColor;
  final Widget child;

  @override
  State<_ReaderPanelSnapshot> createState() => _ReaderPanelSnapshotState();
}

class _ReaderPanelSnapshotState extends State<_ReaderPanelSnapshot> {
  final _snapshot = SnapshotController(allowSnapshotting: true);
  late _PanelPainter _painter = _PanelPainter(
    widget.animation,
    widget.edgeColor,
  );

  @override
  void didUpdateWidget(_ReaderPanelSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.edgeColor != widget.edgeColor) {
      _painter.dispose();
      _painter = _PanelPainter(widget.animation, widget.edgeColor);
    }
  }

  @override
  void dispose() {
    _painter.dispose();
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      controller: _snapshot,
      painter: _painter,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: widget.child,
    );
  }
}

class _PanelPainter extends SnapshotPainter {
  _PanelPainter(this.animation, this.edgeColor) {
    animation.addListener(notifyListeners);
  }

  final Animation<double> animation;
  final Color edgeColor;

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final panels = _PanelGeometry(size, animation.value);
    final leftEdge = Offset(0, panels.left);
    final rightEdge = Offset(size.width, panels.right);
    final top = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(rightEdge.dx, rightEdge.dy)
      ..lineTo(leftEdge.dx, leftEdge.dy)
      ..close();
    final bottom = Path()
      ..moveTo(leftEdge.dx, leftEdge.dy)
      ..lineTo(rightEdge.dx, rightEdge.dy)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    final canvas = context.canvas;
    final imagePaint = Paint()..filterQuality = FilterQuality.low;
    final border = Paint()
      ..color = edgeColor.withValues(alpha: .8 * animation.value)
      ..strokeWidth = 2;

    void drawPanel(Path clip, double dy) {
      canvas.save();
      canvas.translate(offset.dx, offset.dy + dy);
      canvas.clipPath(clip);
      canvas.drawImageRect(
        image,
        Offset.zero & sourceSize,
        Offset.zero & size,
        imagePaint,
      );
      canvas.drawLine(leftEdge, rightEdge, border);
      canvas.restore();
    }

    drawPanel(top, -panels.topTravel);
    drawPanel(bottom, panels.bottomTravel);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    painter(context, offset);
  }

  @override
  bool shouldRepaint(_PanelPainter oldPainter) =>
      animation != oldPainter.animation || edgeColor != oldPainter.edgeColor;

  @override
  void dispose() {
    animation.removeListener(notifyListeners);
    super.dispose();
  }
}
