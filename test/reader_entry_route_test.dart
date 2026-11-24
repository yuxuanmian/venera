import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/entry_route.dart';

const _readerKey = ValueKey('reader');
const _openKey = ValueKey('open-reader');

void main() {
  for (final motion in ReaderEntryMotion.values) {
    testWidgets('${motion.name} opens once and releases the preceding route', (
      tester,
    ) async {
      final previousMotionSetting = debugSemanticsDisableAnimations;
      debugSemanticsDisableAnimations = false;
      addTearDown(() {
        debugSemanticsDisableAnimations = previousMotionSetting;
      });
      final navigator = GlobalKey<NavigatorState>();
      late ModalRoute<dynamic> previous;
      late ReaderEntryRoute route;
      const origin = Offset(116, 296);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) {
              previous = ModalRoute.of(context)!;
              return Scaffold(
                body: TextButton(
                  key: _openKey,
                  onPressed: () {
                    route = ReaderEntryRoute(
                      motion: motion,
                      origin: origin,
                      builder: (_) => const _ReaderMarker(key: _readerKey),
                    );
                    navigator.currentState!.push(route);
                  },
                  child: const Text('Read'),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(route.animation!.status, AnimationStatus.forward);

      final reader = find.byKey(_readerKey);
      final state = tester.state(reader);
      final clip = find.ancestor(of: reader, matching: find.byType(ClipPath));
      expect(clip, findsOneWidget);
      final bounds = tester.getSize(clip);
      final path = tester.widget<ClipPath>(clip).clipper!.getClip(bounds);
      expect(
        path.contains(Offset(bounds.width - 1, bounds.height - 1)),
        isFalse,
      );
      expect(route.transitionDuration, const Duration(milliseconds: 800));
      expect(previous.receivedTransition, isNotNull);
      if (motion == ReaderEntryMotion.circle) {
        expect((path.getBounds().center - origin).distance, lessThan(.001));
        expect(path.contains(origin), isTrue);
      } else {
        expect(find.byType(SnapshotWidget), findsOneWidget);
        expect(
          path.contains(Offset(bounds.width / 2, bounds.height * .51)),
          isTrue,
        );
      }

      await tester.pumpAndSettle();
      expect(clip, findsNothing);
      expect(previous.receivedTransition, isNull);
      expect(tester.state(reader), same(state));
      expect(route.popGestureEnabled, isTrue);

      navigator.currentState!.pop();
      await tester.pump();
      expect(clip, findsNothing);
      await tester.pumpAndSettle();
      expect(find.byKey(_openKey), findsOneWidget);
    });
  }

  testWidgets('tap position survives button activation', (tester) async {
    Offset? position;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ReaderEntryTarget(
            onOpen: (value) => position = value,
            builder: (activate) => FilledButton(
              key: _openKey,
              onPressed: activate,
              child: const Text('Read'),
            ),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byKey(_openKey));
    final tap = center + const Offset(13, 4);
    await tester.tapAt(tap);
    expect(position, tap);
    tester.widget<FilledButton>(find.byKey(_openKey)).onPressed!();
    expect(position, center);
  });

  testWidgets('reduced motion opens the reader immediately', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: _openKey,
              onPressed: () => pushReader(
                context,
                () => const _ReaderMarker(key: _readerKey),
              ),
              child: const Text('Read'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    final reader = find.byKey(_readerKey);
    final route = ModalRoute.of(tester.element(reader))! as ReaderEntryRoute;
    expect(route.transitionDuration, Duration.zero);
    expect(route.delegatedTransition, isNull);
    expect(
      find.ancestor(of: reader, matching: find.byType(ClipPath)),
      findsNothing,
    );
  });
}

class _ReaderMarker extends StatefulWidget {
  const _ReaderMarker({super.key});

  @override
  State<_ReaderMarker> createState() => _ReaderMarkerState();
}

class _ReaderMarkerState extends State<_ReaderMarker> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
