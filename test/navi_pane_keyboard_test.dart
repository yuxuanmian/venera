import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('tab contents cross-fade in place for 300 milliseconds', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          paneItems: [
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
            PaneItemEntry(
              label: 'Favorites',
              icon: Icons.bookmark_outline,
              activeIcon: Icons.bookmark,
            ),
          ],
          paneActions: const [],
          pageBuilder: (index) => Center(child: Text('Page $index')),
          observer: NaviObserver(),
          navigatorKey: GlobalKey(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final home = find.text('Page 0');
    final favorites = find.text('Page 1');
    double opacity(Finder page) => tester
        .widget<PageCrossFade>(
          find.ancestor(of: page, matching: find.byType(PageCrossFade)),
        )
        .opacity;
    final homePosition = tester.getTopLeft(home);

    await tester.tap(find.byIcon(Icons.bookmark_outline).hitTestable());
    await tester.pump();
    final favoritesPosition = tester.getTopLeft(favorites);
    await tester.pump(const Duration(milliseconds: 150));
    expect(opacity(home), closeTo(.5, .01));
    expect(opacity(favorites), closeTo(.5, .01));
    expect(tester.getTopLeft(home), homePosition);
    expect(tester.getTopLeft(favorites), favoritesPosition);
    expect(home.hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 90));
    expect(home, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    expect(home, findsNothing);
    expect(opacity(favorites), 1);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.home_outlined).hitTestable());
    await tester.pump();
    expect(favorites, findsNothing);
    expect(opacity(home), 1);
  });

  testWidgets('quick tab changes keep the last tab and restore home scroll', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    final observer = NaviObserver();
    final navigatorKey = GlobalKey<NavigatorState>();
    final homeKey = GlobalKey();
    final tabs = [
      PaneItemEntry(
        label: 'Home',
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
      ),
      PaneItemEntry(
        label: 'Favorites',
        icon: Icons.bookmark_outline,
        activeIcon: Icons.bookmark,
      ),
      PaneItemEntry(
        label: 'Categories',
        icon: Icons.category_outlined,
        activeIcon: Icons.category,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          paneItems: tabs,
          paneActions: const [],
          pageBuilder: (index) => index == 0
              ? ListView.builder(
                  key: homeKey,
                  itemExtent: 56,
                  itemCount: 100,
                  itemBuilder: (context, index) => Text('Home item $index'),
                )
              : Center(child: Text('Content $index')),
          observer: observer,
          navigatorKey: navigatorKey,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byKey(homeKey),
      matching: find.byType(Scrollable),
    );
    await tester.drag(scrollable, const Offset(0, -420));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(200));
    final before = position.pixels;

    final favorites = find.byIcon(Icons.bookmark_outline).hitTestable();
    final tapSurface = tester.widget<InkWell>(
      find.ancestor(of: favorites, matching: find.byType(InkWell)).first,
    );
    expect(tapSurface.highlightColor, Colors.transparent);
    expect(tapSurface.hoverColor, Colors.transparent);
    expect(tapSurface.splashFactory, NoSplash.splashFactory);
    await tester.tap(favorites);
    await tester.pump(const Duration(milliseconds: 32));
    await tester.tap(find.byIcon(Icons.category_outlined).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Content 2'), findsOneWidget);
    expect(find.text('Content 1'), findsNothing);

    await tester.tap(find.byIcon(Icons.home_outlined).hitTestable());
    await tester.pumpAndSettle();
    final restored = tester.state<ScrollableState>(scrollable).position;
    expect(restored, same(position));
    expect(restored.pixels, before);
  });

  testWidgets(
    'tab content is not rebuilt and sees no viewInsets while covered by a route',
    (tester) async {
      final probe = _Probe();
      final observer = NaviObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => probe,
            observer: observer,
            navigatorKey: navigatorKey,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Push a route on top (like the search page) so the tab content is covered.
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();

      final buildsBefore = probe.builds;
      // Simulate the keyboard insets animation (per-frame viewInsets changes).
      tester.view.viewInsets = FakeViewPadding(bottom: 300);
      await tester.pump();

      // The hidden tab content must not rebuild frame by frame and must not see
      // the keyboard insets while covered.
      expect(probe.builds, buildsBefore);
      expect(probe.lastViewInsetsBottom, 0);

      // Pop the covering route: the tabs are the top-most route again, so they
      // must see the real viewInsets (e.g. the favorites tab inline search
      // field still resizes with the keyboard).
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      tester.view.viewInsets = FakeViewPadding(bottom: 300);
      await tester.pump();
      // FlutterView insets are in physical pixels; MediaQuery reports logical.
      expect(probe.lastViewInsetsBottom, 300 / tester.view.devicePixelRatio);
    },
  );

  testWidgets('tab content keeps the app bar top inset removed', (
    tester,
  ) async {
    final probe = _Probe();
    final observer = NaviObserver();
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            padding: EdgeInsets.only(top: 24),
            viewPadding: EdgeInsets.only(top: 24),
          ),
          child: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Favorites',
                icon: Icons.favorite_border,
                activeIcon: Icons.favorite,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => probe,
            observer: observer,
            navigatorKey: navigatorKey,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(probe.lastPaddingTop, 0);
  });
}

/// Page content probe: records how often it builds and the bottom viewInsets
/// it observes. The same instance is reused by [NaviPane]'s pageBuilder, so a
/// rebuild can only come from a real rebuild of its subtree (a rebuild of the
/// pane or an unfiltered MediaQuery change), not from widget re-creation.
class _Probe extends StatefulWidget {
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) {
    _ProbeStats.builds++;
    _ProbeStats.lastInsets = MediaQuery.of(context).viewInsets.bottom;
    _ProbeStats.lastPaddingTop = MediaQuery.of(context).padding.top;
    return const SizedBox.expand();
  }
}

extension on _Probe {
  int get builds => _ProbeStats.builds;

  double get lastViewInsetsBottom => _ProbeStats.lastInsets;

  double get lastPaddingTop => _ProbeStats.lastPaddingTop;
}

abstract final class _ProbeStats {
  static int builds = 0;

  static double lastInsets = 0;

  static double lastPaddingTop = 0;
}
