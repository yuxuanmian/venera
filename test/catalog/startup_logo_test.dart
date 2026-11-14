import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/startup_logo.dart';

void main() {
  testWidgets('a slow first home frame does not consume the logo zoom', (
    tester,
  ) async {
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: ready,
          builder: (context, isReady, _) =>
              StartupLogo(child: isReady ? const Text('Home is ready') : null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    final artwork = find.descendant(
      of: find.byType(StartupLogo),
      matching: find.byType(CustomPaint),
    );
    final restingScale = _paintedScale(tester, artwork);
    ready.value = true;
    await tester.pump();
    expect(find.text('Home is ready'), findsOneWidget);

    // Simulate the first layout/paint of the homepage taking longer than
    // the old transition. Subsequent frames should still show the zoom.
    await tester.pump(const Duration(milliseconds: 320));
    expect(artwork, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_paintedScale(tester, artwork), greaterThan(restingScale * 1.8));

    await tester.pumpAndSettle();
    expect(artwork, findsNothing);
    expect(find.text('Home is ready'), findsOneWidget);
  });
}

double _paintedScale(WidgetTester tester, Finder artwork) {
  final canvas = TestRecordingCanvas();
  tester
      .widget<CustomPaint>(artwork)
      .painter!
      .paint(canvas, const Size(800, 600));
  return canvas.invocations
          .singleWhere((record) => record.invocation.memberName == #scale)
          .invocation
          .positionalArguments
          .first
      as double;
}
