import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

/// Contract: 009 US2 / FR-006, FR-007, FR-008.
///
/// `ScrollTapGuard` already protected the center toolbar tap. The 009 change
/// moves the guard in front of the whole single-tap routing decision, so an
/// armed guard consumes an ordinary tap for every tap-to-turn region as well.
///
/// The decision is exercised through the extracted routing seam rather than by
/// building the reader page: the routing rules are what the change is about, and
/// they must stay observable without a comic source, a JavaScript runtime or a
/// real gesture arena.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an armed guard consumes every ordinary single tap', () {
    test('center, leading, trailing, top and bottom taps are all no-ops', () {
      for (final position in <Offset>[
        tapCenter,
        tapLeading,
        tapTrailing,
        tapTop,
        tapBottom,
      ]) {
        final effects = TapEffects()
          ..fire(tapInput(guardArmed: true, position: position));
        expect(
          effects.total,
          0,
          reason: 'an armed guard must consume the tap at $position',
        );
      }
    });

    test('the same tap acts immediately once the guard is disarmed', () {
      // The guard is the only difference between the two runs.
      final armed = TapEffects()
        ..fire(tapInput(guardArmed: true, position: tapTrailing));
      final disarmed = TapEffects()
        ..fire(tapInput(guardArmed: false, position: tapTrailing));
      expect(armed.total, 0);
      expect(disarmed.next, 1);
    });

    test('the guard also beats an open toolbar and the comments page', () {
      final toolbarOpen = TapEffects()
        ..fire(tapInput(guardArmed: true, toolbarOpen: true));
      expect(toolbarOpen.total, 0, reason: 'the toolbar must not be closed');

      final comments = TapEffects()
        ..fire(tapInput(guardArmed: true, onChapterCommentsPage: true));
      expect(comments.total, 0);
    });

    test('a tap with tap-to-turn disabled is consumed as well', () {
      final effects = TapEffects()
        ..fire(tapInput(guardArmed: true, tapToTurnEnabled: false));
      expect(effects.toolbarToggles, 0);
    });
  });

  group('a disarmed guard keeps the existing tap behaviour', () {
    test('a leading tap goes to the previous page', () {
      final effects = TapEffects()..fire(tapInput(position: tapLeading));
      expect(effects.prev, 1);
      expect(effects.next, 0);
      expect(effects.toolbarToggles, 0);
    });

    test('a trailing tap goes to the next page', () {
      final effects = TapEffects()..fire(tapInput(position: tapTrailing));
      expect(effects.next, 1);
      expect(effects.prev, 0);
      expect(effects.toolbarToggles, 0);
    });

    test('top and bottom taps follow the vertical reading mode', () {
      final topTap = TapEffects()
        ..fire(
          tapInput(position: tapTop, mode: ReaderMode.continuousTopToBottom),
        );
      expect(topTap.prev, 1);

      final bottomTap = TapEffects()
        ..fire(
          tapInput(position: tapBottom, mode: ReaderMode.continuousTopToBottom),
        );
      expect(bottomTap.next, 1);
    });

    test('reverse-tap swaps the leading and trailing edges', () {
      final leadingTap = TapEffects()
        ..fire(tapInput(position: tapLeading, reverseTapToTurn: true));
      expect(leadingTap.next, 1);
      expect(leadingTap.prev, 0);

      final trailingTap = TapEffects()
        ..fire(tapInput(position: tapTrailing, reverseTapToTurn: true));
      expect(trailingTap.prev, 1);
      expect(trailingTap.next, 0);
    });

    test('a right-to-left mode swaps the horizontal edges', () {
      final trailingTap = TapEffects()
        ..fire(
          tapInput(
            position: tapTrailing,
            mode: ReaderMode.continuousRightToLeft,
          ),
        );
      expect(trailingTap.prev, 1);
      expect(trailingTap.next, 0);
    });

    test('a center tap toggles the toolbar', () {
      final effects = TapEffects()..fire(tapInput());
      expect(effects.toolbarToggles, 1);
      expect(effects.prev, 0);
      expect(effects.next, 0);
    });

    test('consecutive programmatic tap-to-turn taps are not consumed', () {
      // Nothing here arms a guard: tap-to-turn taps are programmatic page
      // turns, so repeated trailing taps must keep working.
      final effects = TapEffects();
      for (var i = 0; i < 3; i++) {
        effects.fire(tapInput(position: tapTrailing));
      }
      expect(effects.next, 3);
      expect(effects.total, 3);
    });
  });

  group('ScrollTapGuard activity windows still decide the tap', () {
    testWidgets(
      'an armed guard swallows an edge tap and the first tap after the clear turns the page',
      (tester) async {
        final guard = ScrollTapGuard();
        // A user drag armed the guard.
        guard.onScrollStart(userDrag: true);
        expect(guard.isArmed, isTrue);

        final duringGuard = TapEffects()
          ..fire(tapInput(guardArmed: guard.isArmed, position: tapTrailing));
        expect(duringGuard.total, 0);

        // The guard clears 1s after the final scroll activity; the very next
        // tap acts, with no "tap once to stop scrolling" step in between.
        guard.onScrollEnd();
        await tester.pump(const Duration(milliseconds: 999));
        final stillArmed = TapEffects()
          ..fire(tapInput(guardArmed: guard.isArmed, position: tapTrailing));
        expect(stillArmed.total, 0);

        await tester.pump(const Duration(milliseconds: 1));
        expect(guard.isArmed, isFalse);
        final afterClear = TapEffects()
          ..fire(tapInput(guardArmed: guard.isArmed, position: tapTrailing));
        expect(afterClear.next, 1);
      },
    );

    testWidgets('ballistic activity keeps the guard armed', (tester) async {
      final guard = ScrollTapGuard();
      guard.onScrollStart(userDrag: true);
      guard.onScrollEnd();
      // The fling's ballistic scroll follows the drag end.
      guard.onScrollStart(userDrag: false);
      await tester.pump(const Duration(seconds: 1));
      expect(guard.isArmed, isTrue);
      final effects = TapEffects()
        ..fire(tapInput(guardArmed: guard.isArmed, position: tapLeading));
      expect(effects.total, 0);
    });

    testWidgets('a programmatic scroll never arms the guard', (tester) async {
      final guard = ScrollTapGuard();
      guard.onScrollStart(userDrag: false);
      guard.onScrollEnd();
      await tester.pump(const Duration(seconds: 1));
      expect(guard.isArmed, isFalse);
      final effects = TapEffects()
        ..fire(tapInput(guardArmed: guard.isArmed, position: tapTrailing));
      expect(effects.next, 1);
    });
  });
}

/// 1000 x 600 with a 0.3 tap-to-turn band: x < 300 is the leading edge,
/// x > 700 the trailing edge, y < 180 the top edge and y > 420 the bottom edge.
const Size tapSurface = Size(1000, 600);

const Offset tapLeading = Offset(50, 300);

const Offset tapTrailing = Offset(950, 300);

const Offset tapTop = Offset(500, 30);

const Offset tapBottom = Offset(500, 570);

const Offset tapCenter = Offset(500, 300);

ReaderTapDecisionInput tapInput({
  bool guardArmed = false,
  bool toolbarOpen = false,
  bool onChapterCommentsPage = false,
  bool tapToTurnEnabled = true,
  bool reverseTapToTurn = false,
  ReaderMode mode = ReaderMode.continuousLeftToRight,
  Offset position = tapCenter,
  Duration eventTime = const Duration(seconds: 5),
  bool isQuickTap = true,
  Duration? lastMenuToggleTime,
}) => ReaderTapDecisionInput(
  guardArmed: guardArmed,
  toolbarOpen: toolbarOpen,
  onChapterCommentsPage: onChapterCommentsPage,
  tapToTurnEnabled: tapToTurnEnabled,
  reverseTapToTurn: reverseTapToTurn,
  mode: mode,
  position: position,
  size: tapSurface,
  eventTime: eventTime,
  isQuickTap: isQuickTap,
  lastMenuToggleTime: lastMenuToggleTime,
);

/// The concrete outcome of firing one tapped surface: which page turn or
/// toolbar toggle was performed. Nothing else in the reader is touched.
class TapEffects {
  int prev = 0;
  int next = 0;
  int toolbarToggles = 0;

  int get total => prev + next + toolbarToggles;

  /// Runs the same routing the reader uses and records the side effect it would
  /// perform, including the toolbar toggle's own quick-tap and cooldown rules.
  void fire(ReaderTapDecisionInput decision) {
    final action = routeReaderSingleTap(decision);
    switch (action) {
      case ReaderTapAction.consume:
        return;
      case ReaderTapAction.previous:
        prev++;
        return;
      case ReaderTapAction.next:
        next++;
        return;
      case ReaderTapAction.toggleToolbar:
        if (decision.toolbarOpen) {
          toolbarToggles++;
          return;
        }
        if (!decision.isQuickTap) return;
        final last = decision.lastMenuToggleTime;
        if (last != null &&
            decision.eventTime - last < decision.menuToggleCooldown) {
          return;
        }
        toolbarToggles++;
        return;
      case ReaderTapAction.none:
        return;
    }
  }
}
