import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Contract W (007): the details-page right segment is a **read-only
/// indicator**, not a switch.
///
/// Three separate claims are asserted here, because each fails for a different
/// reason:
///
/// 1. **No interaction**: no `InkWell`, no `Focus` and no tap semantics inside
///    the segment, so tap, long-press, keyboard traversal and screen-reader
///    activation all have nothing to trigger (W6 / FR-003).
/// 2. **No action wording**: the retired `Enable/Disable 14-day hot window`
///    strings are `findsNothing` while their translation keys stay in the asset
///    (reverse guard, so the retirement cannot silently come back).
/// 3. **Correct reading of the data**: the lit/unlit state is decided by the
///    stored automatic hot window alone, and the tooltip reports the stored
///    deadline (W3 / W5).
FavoriteHotWindowIndicator _indicator({DateTime? autoHotUntil}) =>
    FavoriteHotWindowIndicator(autoHotUntil: autoHotUntil);

/// The indicator's own time format, mirrored here so the expected tooltip text
/// is built the same way the widget builds it.
String _indicatorTime(DateTime time) =>
    time.toLocal().toString().substring(0, 19);

const hotSegment = ValueKey('favorite-hot-window-hot-segment');
const splitButton = ValueKey('favorite-hot-window-split-button');
const favoriteSegment = ValueKey('favorite-hot-window-favorite-segment');
const fireIcon = ValueKey('favorite-hot-window-fire-icon');

/// Every focus node reachable from the root scope, so "can this be reached by
/// the keyboard?" is answered by the same tree the framework walks.
List<FocusNode> _reachableFocusNodes() {
  final nodes = <FocusNode>[];
  void collect(FocusNode node) {
    nodes.add(node);
    for (final child in node.children) {
      collect(child);
    }
  }

  collect(FocusManager.instance.rootScope);
  return nodes;
}

bool _isInside(WidgetTester tester, BuildContext? context, Finder ancestor) {
  if (context is! Element) return false;
  final element = context;
  final target = tester.element(ancestor);
  if (identical(element, target)) return true;
  var found = false;
  element.visitAncestorElements((candidate) {
    if (identical(candidate, target)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(scrollDirection: Axis.horizontal, child: child),
  ),
);

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('the right segment has no interactive surface at all', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);
    var favoriteTaps = 0;
    var favoriteLongPresses = 0;

    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _host(
        FavoriteHotWindowActionButton(
          isLoading: false,
          onFavorite: () => favoriteTaps++,
          onFavoriteLongPress: () => favoriteLongPresses++,
          indicator: _indicator(
            autoHotUntil: now.add(const Duration(hours: 1)),
          ),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();

    // Layout is unchanged: same size, same divider, same split.
    final size = tester.getSize(find.byKey(splitButton));
    expect(size.height, 48);
    expect(size.width, lessThanOrEqualTo(180));
    expect(tester.getSize(find.byKey(hotSegment)).width, 38);
    expect(
      find.byKey(const ValueKey('favorite-hot-window-divider')),
      findsOneWidget,
    );

    // Exactly one interactive surface in the whole button — the favorite
    // segment.  If the indicator segment ever regains an InkWell this count
    // becomes two.
    expect(
      find.descendant(
        of: find.byKey(splitButton),
        matching: find.byType(InkWell),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(favoriteSegment),
        matching: find.byType(InkWell),
      ),
      findsNothing,
      reason: 'the key is on the favorite segment InkWell itself',
    );
    expect(tester.widget(find.byKey(favoriteSegment)), isA<InkWell>());
    expect(
      find.descendant(
        of: find.byKey(hotSegment),
        matching: find.byType(InkWell),
      ),
      findsNothing,
      reason: 'the indicator is a status, not a control',
    );
    // The key is on the segment widget itself, so this is the direct form of
    // the same claim: the segment must not *be* an InkWell.
    expect(tester.widget(find.byKey(hotSegment)), isNot(isA<InkWell>()));
    // No focus node ⇒ it cannot be reached by keyboard traversal either.
    expect(
      find.descendant(of: find.byKey(hotSegment), matching: find.byType(Focus)),
      findsNothing,
    );

    // Tapping and long-pressing the segment produces nothing: not the favorite
    // action crossing over, and not any hot-window write.
    await tester.tap(find.byKey(hotSegment));
    await tester.longPress(find.byKey(hotSegment));
    await tester.pump();
    expect(favoriteTaps, 0);
    expect(favoriteLongPresses, 0);

    // Screen-reader activation is impossible: the node carries no tap action.
    final data = tester.getSemantics(find.byKey(hotSegment)).getSemanticsData();
    expect(
      data.hasAction(SemanticsAction.tap),
      isFalse,
      reason: 'a tap action here would make it activatable by a screen reader',
    );
    expect(data.label, 'Recently updated'.tl);

    // The favorite segment still works, and its own action never crosses over.
    await tester.tap(find.byKey(favoriteSegment));
    await tester.longPress(find.byKey(favoriteSegment));
    expect(favoriteTaps, 1);
    expect(favoriteLongPresses, 1);
    semantics.dispose();
  });

  testWidgets('the keyboard cannot reach the indicator', (tester) async {
    final now = DateTime(2026, 8, 22, 12);

    await tester.pumpWidget(
      _host(
        FavoriteHotWindowActionButton(
          isLoading: false,
          onFavorite: () {},
          onFavoriteLongPress: () {},
          indicator: _indicator(
            autoHotUntil: now.add(const Duration(hours: 1)),
          ),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();

    final nodes = _reachableFocusNodes();
    // Not vacuous: the favorite segment's focus node is in the walk.
    expect(
      nodes.any(
        (node) => _isInside(tester, node.context, find.byKey(favoriteSegment)),
      ),
      isTrue,
      reason:
          'the favorite segment must be reachable, or this test proves '
          'nothing about the indicator',
    );
    for (final node in nodes) {
      expect(
        _isInside(tester, node.context, find.byKey(hotSegment)),
        isFalse,
        reason: 'no focusable node may live inside the read-only indicator',
      );
    }
  });

  testWidgets('retired action wording is gone while its keys survive', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);

    Future<void> pump({DateTime? autoHotUntil}) async {
      await tester.pumpWidget(
        _host(
          FavoriteHotWindowActionButton(
            isLoading: false,
            onFavorite: () {},
            onFavoriteLongPress: () {},
            indicator: _indicator(autoHotUntil: autoHotUntil),
            clock: () => now,
          ),
        ),
      );
      await tester.pump();
    }

    await pump();
    expect(find.text('Enable 14-day hot window'.tl), findsNothing);
    expect(find.text('Disable 14-day hot window'.tl), findsNothing);
    expect(find.bySemanticsLabel('Enable 14-day hot window'.tl), findsNothing);
    expect(find.bySemanticsLabel('Disable 14-day hot window'.tl), findsNothing);
    expect(find.bySemanticsLabel('No recent update'.tl), findsOneWidget);

    await pump(autoHotUntil: now.add(const Duration(hours: 1)));
    expect(find.text('Enable 14-day hot window'.tl), findsNothing);
    expect(find.text('Disable 14-day hot window'.tl), findsNothing);
    expect(find.bySemanticsLabel('Recently updated'.tl), findsOneWidget);
  });

  testWidgets('the tooltip explains the stored deadline, not an action', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);
    final until = now.add(const Duration(days: 3));

    await tester.pumpWidget(
      _host(
        FavoriteHotWindowActionButton(
          isLoading: false,
          onFavorite: () {},
          onFavoriteLongPress: () {},
          indicator: _indicator(autoHotUntil: until),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    const format = _indicatorTime;
    // The stored deadline is the authoritative value (W5) and must appear.
    expect(
      tooltip.message,
      contains('Auto hot window until @time'.tlParams({'time': format(until)})),
    );
    // The derived "changed at" moment is auxiliary context only.
    expect(
      tooltip.message,
      contains(
        'Recently changed at @time'.tlParams({
          'time': format(until.subtract(kFollowUpdateHotWindow)),
        }),
      ),
    );
    expect(tooltip.message, isNot(contains('Enable')));
    expect(tooltip.message, isNot(contains('Disable')));
    expect(tooltip.message, isNot(contains('启用')));
    expect(tooltip.message, isNot(contains('禁用')));
  });

  testWidgets('lit and unlit use distinct visuals for the same segment', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);

    Future<void> pump({
      DateTime? autoHotUntil,
      ThemeData? theme,
      double? width,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? ThemeData(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: FavoriteHotWindowActionButton(
                  isLoading: false,
                  onFavorite: () {},
                  onFavoriteLongPress: () {},
                  indicator: _indicator(autoHotUntil: autoHotUntil),
                  clock: () => now,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pump();
    var fire = tester.widget<Icon>(find.byKey(fireIcon));
    expect(fire.icon, Icons.local_fire_department_outlined);
    expect(fire.color, ThemeData().colorScheme.onSurfaceVariant);

    await pump(autoHotUntil: now.add(const Duration(hours: 1)));
    fire = tester.widget<Icon>(find.byKey(fireIcon));
    expect(fire.icon, Icons.local_fire_department);
    expect(fire.color!.r, greaterThan(fire.color!.g));

    // An already-expired deadline is unlit: the indicator answers "recently
    // changed", and the window closing is a time-driven change (W7).
    await pump(autoHotUntil: now.subtract(const Duration(seconds: 1)));
    fire = tester.widget<Icon>(find.byKey(fireIcon));
    expect(fire.icon, Icons.local_fire_department_outlined);

    await pump(theme: ThemeData.dark(), width: 160);
    expect(tester.takeException(), isNull);

    // Narrow rows still scroll rather than overflow.
    await pump(width: 80);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.getSize(find.byKey(splitButton)).width, closeTo(137.2, 0.1));
    final favoriteText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(favoriteSegment),
        matching: find.byType(Text),
      ),
    );
    expect(favoriteText.maxLines, 1);
    expect(favoriteText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the favorite segment reports a loading state and stays inert', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);
    var favoriteTaps = 0;

    await tester.pumpWidget(
      _host(
        FavoriteHotWindowActionButton(
          isLoading: true,
          onFavorite: () => favoriteTaps++,
          onFavoriteLongPress: () {},
          indicator: _indicator(
            autoHotUntil: now.add(const Duration(hours: 1)),
          ),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(favoriteSegment));
    await tester.longPress(find.byKey(favoriteSegment));
    expect(favoriteTaps, 0);
    // The indicator is unaffected by the favorite request in flight.
    expect(find.byKey(fireIcon), findsOneWidget);
  });

  test('indicator visibility needs follow-up on, a favorite, and a record', () {
    for (final enabled in <bool>[false, true]) {
      for (final favorite in <bool>[false, true]) {
        for (final hasRecord in <bool>[false, true]) {
          expect(
            shouldShowFavoriteHotWindowIndicator(
              followUpdatesEnabled: enabled,
              isFavorite: favorite,
              hasCheckRecord: hasRecord,
            ),
            enabled && favorite && hasRecord,
            reason:
                'visible ⇔ 追更开启 ∧ 是收藏 ∧ 已有检查记录; it MUST NOT depend '
                'on whether the source currently has a scan capability',
          );
        }
      }
    }
  });

  test('the indicator reads only the automatic hot window', () {
    final now = DateTime(2026, 8, 22, 12);

    expect(_indicator().isActiveAt(now), isFalse);
    expect(_indicator().recentlyChangedAt(), isNull);

    final open = _indicator(autoHotUntil: now.add(const Duration(hours: 1)));
    expect(open.isActiveAt(now), isTrue);
    expect(
      open.recentlyChangedAt(),
      now.add(const Duration(hours: 1)).subtract(kFollowUpdateHotWindow),
    );

    final closed = _indicator(
      autoHotUntil: now.subtract(const Duration(hours: 1)),
    );
    expect(closed.isActiveAt(now), isFalse);
  });

  testWidgets('unfavoriting replaces the split button on rebuild', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);
    var isFavorite = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              final show = shouldShowFavoriteHotWindowIndicator(
                followUpdatesEnabled: true,
                isFavorite: isFavorite,
                hasCheckRecord: true,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: show
                    ? FavoriteHotWindowActionButton(
                        isLoading: false,
                        onFavorite: () => setState(() => isFavorite = false),
                        onFavoriteLongPress: () {},
                        indicator: _indicator(
                          autoHotUntil: now.add(const Duration(hours: 1)),
                        ),
                        clock: () => now,
                      )
                    : const SizedBox(
                        key: ValueKey('ordinary-favorite-button'),
                        width: 120,
                      ),
              );
            },
          ),
        ),
      ),
    );
    expect(find.byKey(splitButton), findsOneWidget);
    await tester.tap(find.byKey(favoriteSegment));
    await tester.pump();
    expect(find.byKey(splitButton), findsNothing);
    expect(find.byKey(hotSegment), findsNothing);
    expect(find.byKey(const ValueKey('ordinary-favorite-button')), findsOne);
  });
}
