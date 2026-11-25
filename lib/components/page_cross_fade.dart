part of 'components.dart';

class PageCrossFadeController<T extends Object> extends AnimationController {
  PageCrossFadeController({required super.vsync})
    : super(duration: const Duration(milliseconds: 300), value: 1);

  T? _incoming;
  T? _outgoing;
  double _incomingStart = 1;
  double _outgoingStart = 0;

  T? get incoming => _incoming;
  T? get outgoing => _outgoing;

  double get _progress => Curves.easeInOut.transform(value);
  double get incomingOpacity => ui.lerpDouble(_incomingStart, 1, _progress)!;
  double get outgoingOpacity => _outgoingStart * (1 - _progress);

  void show(T? previous, T next, {required bool animate}) {
    final continuing = previous == _incoming;
    final previousOpacity = continuing ? incomingOpacity : 1.0;
    final outgoingOpacity = continuing ? this.outgoingOpacity : 0.0;
    final returning = next == _outgoing && outgoingOpacity > 0;
    _incoming = next;
    if (!animate || previous == null) {
      _outgoing = null;
      _incomingStart = 1;
      _outgoingStart = 0;
      value = 1;
      return;
    }

    // Continue from the visible opacity when reversing or skipping a page.
    _incomingStart = returning ? outgoingOpacity : 0;
    if (returning || previousOpacity >= outgoingOpacity) {
      _outgoing = previous;
      _outgoingStart = previousOpacity;
    } else {
      _outgoingStart = outgoingOpacity;
    }
    forward(from: 0);
  }
}

class PageCrossFade extends StatelessWidget {
  const PageCrossFade({
    required this.active,
    required this.opacity,
    required this.child,
    super.key,
  });

  final bool active;
  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !active && opacity == 0,
    child: TickerMode(
      enabled: active,
      child: ExcludeFocus(
        excluding: !active,
        child: ExcludeSemantics(
          excluding: !active,
          child: IgnorePointer(
            ignoring: !active,
            child: HeroMode(
              enabled: active,
              child: Opacity(opacity: opacity, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}
