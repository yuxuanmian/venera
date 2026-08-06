import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';

/// Regression tests for the iOS-style interactive back gesture.
///
/// A single back gesture must pop exactly one route. If the route is already
/// being popped (e.g. the system back gesture delivered while the interactive
/// drag is still in flight), releasing the finger must not pop the page below
/// as well.
void main() {
  group('Android predictive back', () {
    late GlobalKey<NavigatorState> innerKey;

    setUp(() {
      innerKey = GlobalKey<NavigatorState>();
      App.mainNavigatorKey = innerKey;
    });

    Future<void> pumpShell(
      WidgetTester tester, {
      List<NavigatorObserver> rootObservers = const [],
      List<NavigatorObserver> innerObservers = const [],
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          navigatorObservers: rootObservers,
          home: Scaffold(
            body: Navigator(
              key: innerKey,
              observers: innerObservers,
              onGenerateRoute: (settings) => _PredictiveTestRoute(
                applyNavigatorGuard: true,
                builder: (_) => const _ShellFirstPage(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> sendBackGesture(
      WidgetTester tester,
      String method, [
      Map<Object?, Object?> args = const {},
    ]) async {
      final message = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, args),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        message,
        (_) {},
      );
      await tester.pump();
    }

    testWidgets('inner navigator route is disabled while root has routes', (
      tester,
    ) async {
      await pumpShell(tester);

      // "Details" page on the inner navigator.
      final inner = innerKey.currentState!;
      inner.push(
        _PredictiveTestRoute(
          applyNavigatorGuard: true,
          builder: (_) => const _DetailsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // "Reader" page on the root navigator, above the shell.
      final root = App.rootNavigatorKey.currentState!;
      root.push(
        _PredictiveTestRoute(
          applyNavigatorGuard: true,
          builder: (_) => const _ReaderPage(),
        ),
      );
      await tester.pumpAndSettle();

      final detailsRoute = ModalRoute.of(
        tester.element(find.text('details', skipOffstage: false)),
      )!;
      final readerRoute = ModalRoute.of(tester.element(find.text('reader')))!;

      // The visible root route may claim the gesture, the covered inner
      // navigator route must not.
      expect(readerRoute.popGestureEnabled, isTrue);
      expect(detailsRoute.popGestureEnabled, isFalse);
    });

    testWidgets('AppPageRoute disables the gesture for covered inner routes', (
      tester,
    ) async {
      final innerKey = GlobalKey<NavigatorState>();
      App.mainNavigatorKey = innerKey;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: Navigator(
              key: innerKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                builder: (_) => const _ShellFirstPage(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Details page on the inner navigator: enabled while the root is clear.
      innerKey.currentState!.push(
        AppPageRoute<void>(builder: (context) => const _DetailsPage()),
      );
      await tester.pumpAndSettle();
      final detailsRoute = ModalRoute.of(tester.element(find.text('details')))!;
      expect(detailsRoute.popGestureEnabled, isTrue);

      // Reader page on the root navigator: covers the shell, so the inner
      // navigator route must no longer claim the system back gesture.
      App.rootNavigatorKey.currentState!.push(
        AppPageRoute<void>(builder: (context) => const _ReaderPage()),
      );
      await tester.pumpAndSettle();
      final coveredDetailsRoute = ModalRoute.of(
        tester.element(find.text('details', skipOffstage: false)),
      )!;
      expect(coveredDetailsRoute.popGestureEnabled, isFalse);

      // Reader back on the root: the inner route is enabled again.
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      final restoredRoute = ModalRoute.of(
        tester.element(find.text('details')),
      )!;
      expect(restoredRoute.popGestureEnabled, isTrue);
    });

    testWidgets('route content always sits on an opaque background', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const Scaffold(body: Center(child: Text('open'))),
        ),
      );
      await tester.pumpAndSettle();
      App.rootNavigatorKey.currentState!.push(
        AppPageRoute<void>(builder: (context) => const _OpaqueProbe()),
      );
      await tester.pumpAndSettle();

      // A page whose content is fully transparent must still be covered by an
      // opaque surface-colored box, so it never shows the layer below through
      // during a route transition or the held back gesture.
      final box = tester.widget<ColoredBox>(
        find
            .ancestor(
              of: find.byType(_OpaqueProbe),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      final surface = Theme.of(
        tester.element(find.byType(_OpaqueProbe)),
      ).colorScheme.surface;
      expect(box.color, surface);
      expect(box.color.a, 1.0);
    });

    testWidgets('a single predictive back commit pops only the root route', (
      tester,
    ) async {
      final rootCounter = _PopCounter();
      await pumpShell(tester, rootObservers: [rootCounter]);

      final inner = innerKey.currentState!;
      inner.push(
        _PredictiveTestRoute(
          applyNavigatorGuard: true,
          builder: (_) => const _DetailsPage(),
        ),
      );
      await tester.pumpAndSettle();

      final root = App.rootNavigatorKey.currentState!;
      root.push(
        _PredictiveTestRoute(
          applyNavigatorGuard: true,
          builder: (_) => const _ReaderPage(),
        ),
      );
      await tester.pumpAndSettle();

      await sendBackGesture(tester, 'startBackGesture', {
        'touchOffset': [0.0, 300.0],
        'progress': 0.3,
        'swipeEdge': 0,
      });
      await sendBackGesture(tester, 'commitBackGesture');

      await tester.pumpAndSettle();

      expect(find.text('reader'), findsNothing);
      expect(find.text('details', skipOffstage: false), findsOneWidget);
      expect(find.text('shell', skipOffstage: false), findsOneWidget);
      expect(rootCounter.pops, 1);
    });

    testWidgets(
      'without the navigator guard a single commit pops both navigators',
      (tester) async {
        final rootCounter = _PopCounter();
        final innerCounter = _PopCounter();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            navigatorObservers: [rootCounter],
            home: Scaffold(
              body: Navigator(
                key: innerKey,
                observers: [innerCounter],
                onGenerateRoute: (settings) => _PredictiveTestRoute(
                  applyNavigatorGuard: false,
                  builder: (_) => const _ShellFirstPage(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final inner = innerKey.currentState!;
        inner.push(
          _PredictiveTestRoute(
            applyNavigatorGuard: false,
            builder: (_) => const _DetailsPage(),
          ),
        );
        await tester.pumpAndSettle();

        final root = App.rootNavigatorKey.currentState!;
        root.push(
          _PredictiveTestRoute(
            applyNavigatorGuard: false,
            builder: (_) => const _ReaderPage(),
          ),
        );
        await tester.pumpAndSettle();

        await sendBackGesture(tester, 'startBackGesture', {
          'touchOffset': [0.0, 300.0],
          'progress': 0.3,
          'swipeEdge': 0,
        });
        await sendBackGesture(tester, 'commitBackGesture');

        await tester.pumpAndSettle();

        // Both the root route and the inner navigator route pop for one gesture.
        expect(rootCounter.pops, 1);
        expect(innerCounter.pops, 1);
      },
    );
  });

  group('iOS interactive back gesture', () {
    Future<(NavigatorState, TestPageRoute<dynamic>)> pushSecondPage(
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: FirstPage()));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final route =
          ModalRoute.of(tester.element(find.text('second')))!
              as TestPageRoute<dynamic>;
      return (navigator, route);
    }

    testWidgets('committed back gesture pops exactly the top route', (
      tester,
    ) async {
      final (navigator, route) = await pushSecondPage(tester);

      final gesture = IOSBackGestureController(
        route,
        route.testController,
        navigator,
      );
      gesture.dragUpdate(0.4); // drag right, finger held
      gesture.dragEnd(5.0); // rightward fling: commit the pop
      await tester.pumpAndSettle();

      expect(find.text('second'), findsNothing);
      expect(find.text('first'), findsOneWidget);
    });

    testWidgets('release after the route was already popped does not pop again', (
      tester,
    ) async {
      final (navigator, route) = await pushSecondPage(tester);

      final gesture = IOSBackGestureController(
        route,
        route.testController,
        navigator,
      );
      gesture.dragUpdate(0.4);

      // The route is popped by the system back while the finger is still down.
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('second'), findsNothing);

      // Releasing the finger with a rightward fling must not pop the page below.
      gesture.dragEnd(5.0);
      await tester.pumpAndSettle();

      expect(find.text('first'), findsOneWidget);
    });

    testWidgets('release after the route was already popped does not crash', (
      tester,
    ) async {
      final (navigator, route) = await pushSecondPage(tester);

      final gesture = IOSBackGestureController(
        route,
        route.testController,
        navigator,
      );
      gesture.dragUpdate(0.4);

      navigator.pop();
      await tester.pumpAndSettle();

      // A leftward fling would normally animate the route back; it must be a
      // no-op (not touch the disposing controller) once the route is gone.
      gesture.dragEnd(-5.0);
      await tester.pumpAndSettle();

      expect(find.text('first'), findsOneWidget);
    });
  });
}

class FirstPage extends StatelessWidget {
  const FirstPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('first'),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  TestPageRoute<void>(pageBuilder: (_) => const SecondPage()),
                );
              },
              child: const Text('open'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

class _ShellFirstPage extends StatelessWidget {
  const _ShellFirstPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('shell')));
  }
}

/// A fully transparent page content, used to prove the route paints an opaque
/// background behind whatever the page builds.
class _OpaqueProbe extends StatelessWidget {
  const _OpaqueProbe();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}

class _DetailsPage extends StatelessWidget {
  const _DetailsPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('details')));
  }
}

class _ReaderPage extends StatelessWidget {
  const _ReaderPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('reader')));
  }
}

/// A [PageRoute] that uses Android's predictive back transitions, mimicking
/// [AppPageRoute] on Android. [applyNavigatorGuard] toggles the fix that stops
/// a covered inner-navigator route from claiming the system back gesture.
class _PredictiveTestRoute extends PageRoute<void> {
  _PredictiveTestRoute({
    required this.builder,
    required this.applyNavigatorGuard,
  });

  final WidgetBuilder builder;

  final bool applyNavigatorGuard;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PredictiveBackPageTransitionsBuilder().buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }

  @override
  bool get popGestureEnabled {
    if (applyNavigatorGuard) {
      final rootNavigator = App.rootNavigatorKey.currentState;
      if (navigator != null &&
          navigator != rootNavigator &&
          (rootNavigator?.canPop() ?? false)) {
        return false;
      }
    }
    return super.popGestureEnabled;
  }

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => true;
}

class SecondPage extends StatelessWidget {
  const SecondPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('second')));
  }
}

/// Minimal [PageRoute] that exposes its animation controller so the tests can
/// drive the interactive back gesture directly.
class TestPageRoute<T> extends PageRoute<T> {
  TestPageRoute({required this.pageBuilder});

  final WidgetBuilder pageBuilder;

  AnimationController get testController => controller!;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return pageBuilder(context);
  }

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => true;
}
