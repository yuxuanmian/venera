import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets(
      'tab content is not rebuilt and sees no viewInsets while covered by a route',
      (tester) async {
    final probe = _Probe();
    final observer = NaviObserver();
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.pumpAndSettle();

    // Push a route on top (like the search page) so the tab content is covered.
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SizedBox())),
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
    expect(
      probe.lastViewInsetsBottom,
      300 / tester.view.devicePixelRatio,
    );
  });

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
