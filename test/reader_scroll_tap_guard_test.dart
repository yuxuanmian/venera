import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  testWidgets(
    'a user drag arms the guard immediately and it disarms 1s after the scroll ends',
    (tester) async {
      final guard = ScrollTapGuard();
      expect(guard.isArmed, isFalse);

      guard.onScrollStart(userDrag: true);
      expect(guard.isArmed, isTrue);

      guard.onScrollEnd();
      await tester.pump(const Duration(milliseconds: 999));
      expect(guard.isArmed, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(guard.isArmed, isFalse);
    },
  );

  testWidgets('a programmatic scroll does not arm the guard', (tester) async {
    final guard = ScrollTapGuard();
    guard.onScrollStart(userDrag: false);
    expect(guard.isArmed, isFalse);
    guard.onScrollEnd();
    await tester.pump(const Duration(seconds: 1));
    expect(guard.isArmed, isFalse);
  });

  testWidgets(
    'a new activity invalidates a pending clear so the guard stays armed through ballistic scrolling',
    (tester) async {
      final guard = ScrollTapGuard();
      guard.onScrollStart(userDrag: true); // drag starts
      guard.onScrollEnd(); // drag ends
      guard.onScrollStart(
        userDrag: false,
      ); // ballistic scroll follows the fling
      await tester.pump(const Duration(seconds: 1));
      expect(guard.isArmed, isTrue); // the drag-end clear was invalidated
      guard.onScrollEnd(); // ballistic ends
      await tester.pump(const Duration(seconds: 1));
      expect(guard.isArmed, isFalse);
    },
  );

  testWidgets('fast consecutive flicks keep the guard armed', (tester) async {
    final guard = ScrollTapGuard();
    guard.onScrollStart(userDrag: true);
    guard.onScrollEnd();
    guard.onScrollStart(userDrag: true); // next flick before the clear
    await tester.pump(const Duration(seconds: 1));
    expect(guard.isArmed, isTrue);
    guard.onScrollEnd();
    await tester.pump(const Duration(seconds: 1));
    expect(guard.isArmed, isFalse);
  });
}
