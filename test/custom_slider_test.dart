import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

/// Regression tests for the reader progress slider.
///
/// Dragging the slider used to fire [CustomSlider.onChanged] on every pointer
/// move, which made the reader restart its page animation, rebuild the whole
/// reader and decode images per event — freezing the page. The slider now
/// moves the thumb locally while dragging and commits exactly one jump when
/// the gesture ends.
void main() {
  Future<void> pumpSlider(
    WidgetTester tester,
    void Function(double) onChanged,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CustomSlider(
                key: const Key('slider'),
                focusNode: FocusNode(),
                min: 1,
                max: 100,
                value: 1,
                divisions: 99,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The GestureDetector starts 24px inside the slider because of the left
  // padding, so an x of [dx] in detector coordinates is 24 + dx in slider
  // coordinates. The detector is 352px wide (400 - 2 * 24).
  Offset sliderLocal(WidgetTester tester, double dx) {
    final rect = tester.getRect(find.byKey(const Key('slider')));
    return Offset(rect.left + 24 + dx, rect.center.dy);
  }

  // Value at detector x [dx]: (dx / (352 / 99)).round() + 1.
  double valueAt(double dx) => (dx * 99 / 352).round() + 1;

  testWidgets('a horizontal drag commits exactly one jump on release', (
    tester,
  ) async {
    final changes = <double>[];
    await pumpSlider(tester, changes.add);

    final gesture = await tester.startGesture(sliderLocal(tester, 176));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(changes, isEmpty, reason: 'no jump should fire while dragging');

    await gesture.up();
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single, valueAt(276));
  });

  testWidgets('a vertical drag commits exactly one jump on release', (
    tester,
  ) async {
    final changes = <double>[];
    await pumpSlider(tester, changes.add);

    final gesture = await tester.startGesture(sliderLocal(tester, 176));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(changes, isEmpty, reason: 'no jump should fire while dragging');

    await gesture.up();
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single, valueAt(176));
  });

  testWidgets('a tap commits exactly one jump on tap up', (tester) async {
    final changes = <double>[];
    await pumpSlider(tester, changes.add);

    await tester.tapAt(sliderLocal(tester, 176));
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single, valueAt(176));
  });

  testWidgets('a reversed slider mirrors the position', (tester) async {
    final changes = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CustomSlider(
                key: const Key('slider'),
                focusNode: FocusNode(),
                min: 1,
                max: 100,
                value: 1,
                divisions: 99,
                reversed: true,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    );

    // At detector x 176 (middle), the reversed value mirrors it:
    // mirrored dx = 352 - 176 = 176.
    await tester.tapAt(sliderLocal(tester, 176));
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single, valueAt(176));

    changes.clear();
    // Near the right edge, the reversed value is near the minimum.
    await tester.tapAt(sliderLocal(tester, 300));
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single, valueAt(352 - 300));
  });
}
