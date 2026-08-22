import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

FavoriteItemWithUpdateInfo _info(
  DateTime now, {
  DateTime? autoHotUntil,
  DateTime? manualHotUntil,
  bool manualHotEnabled = false,
}) => FavoriteItemWithUpdateInfo(
  FavoriteItem(
    id: 'comic',
    name: 'Comic',
    coverPath: '',
    author: '',
    sourceKeyValue: 'source',
    tags: const [],
  ),
  null,
  null,
  false,
  null,
  null,
  autoHotUntil: autoHotUntil,
  manualHotUntil: manualHotUntil,
  manualHotEnabled: manualHotEnabled,
);

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('split button keeps layout and events independent', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 22, 12);
    var favoriteTaps = 0;
    var favoriteLongPresses = 0;
    var hotTaps = 0;

    Future<void> pumpButton({
      FavoriteItemWithUpdateInfo? info,
      bool isLoading = false,
      double? width,
      ThemeData? theme,
    }) async {
      final button = FavoriteHotWindowActionButton(
        isLoading: isLoading,
        onFavorite: () => favoriteTaps++,
        onFavoriteLongPress: () => favoriteLongPresses++,
        info: info ?? _info(now),
        clock: () => now,
        onToggleHotWindow: () => hotTaps++,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? ThemeData(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: button,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpButton();
    final splitSize = tester.getSize(
      find.byKey(const ValueKey('favorite-hot-window-split-button')),
    );
    expect(splitSize.height, 48);
    expect(splitSize.width, lessThanOrEqualTo(180));
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('favorite-hot-window-hot-segment')),
          )
          .width,
      38,
    );
    expect(
      find.byKey(const ValueKey('favorite-hot-window-divider')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('Favorite|收藏')), findsOneWidget);
    expect(
      find.bySemanticsLabel('Enable 14-day hot window'.tl),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-favorite-segment')),
    );
    expect(favoriteTaps, 1);
    expect(hotTaps, 0);
    await tester.longPress(
      find.byKey(const ValueKey('favorite-hot-window-favorite-segment')),
    );
    expect(favoriteLongPresses, 1);
    expect(hotTaps, 0);
    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-hot-segment')),
    );
    expect(hotTaps, 1);
    expect(favoriteTaps, 1);
    await tester.tap(find.byKey(const ValueKey('favorite-hot-window-divider')));
    expect(favoriteTaps, 1);
    expect(hotTaps, 1);

    await pumpButton(isLoading: true);
    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-favorite-segment')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('favorite-hot-window-favorite-segment')),
    );
    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-hot-segment')),
    );
    expect(favoriteTaps, 1);
    expect(favoriteLongPresses, 1);
    expect(hotTaps, 1);
  });

  testWidgets(
    'hot states use distinct deep-orange visuals and fit narrow rows',
    (tester) async {
      final now = DateTime(2026, 8, 22, 12);

      Future<void> pumpState(
        FavoriteItemWithUpdateInfo info, {
        ThemeData? theme,
        double? width,
      }) async {
        final button = FavoriteHotWindowActionButton(
          isLoading: false,
          onFavorite: () {},
          onFavoriteLongPress: () {},
          info: info,
          clock: () => now,
          onToggleHotWindow: () {},
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme ?? ThemeData(),
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: button,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pumpState(_info(now));
      var fire = tester.widget<Icon>(
        find.byKey(const ValueKey('favorite-hot-window-fire-icon')),
      );
      expect(fire.icon, Icons.local_fire_department_outlined);
      expect(fire.color, ThemeData().colorScheme.onSurfaceVariant);

      await pumpState(
        _info(now, autoHotUntil: now.add(const Duration(hours: 1))),
      );
      fire = tester.widget<Icon>(
        find.byKey(const ValueKey('favorite-hot-window-fire-icon')),
      );
      expect(fire.icon, Icons.local_fire_department_outlined);
      expect(fire.color!.r, greaterThan(fire.color!.g));
      expect(
        find.bySemanticsLabel('Enable 14-day hot window'.tl),
        findsOneWidget,
      );

      await pumpState(
        _info(
          now,
          manualHotUntil: now.add(const Duration(hours: 1)),
          manualHotEnabled: true,
        ),
        theme: ThemeData.dark(),
        width: 160,
      );
      fire = tester.widget<Icon>(
        find.byKey(const ValueKey('favorite-hot-window-fire-icon')),
      );
      expect(fire.icon, Icons.local_fire_department);
      expect(fire.color!.r, greaterThan(fire.color!.g));
      expect(fire.color!.r, greaterThan(fire.color!.b));
      expect(
        find.bySemanticsLabel('Disable 14-day hot window'.tl),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await pumpState(_info(now), width: 80);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .maxScrollExtent,
        greaterThan(0),
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('favorite-hot-window-split-button')),
            )
            .width,
        closeTo(137.2, 0.1),
      );
      final favoriteText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(
            const ValueKey('favorite-hot-window-favorite-segment'),
          ),
          matching: find.byType(Text),
        ),
      );
      expect(favoriteText.maxLines, 1);
      expect(favoriteText.overflow, TextOverflow.ellipsis);

      await pumpState(
        _info(
          now,
          autoHotUntil: now.add(const Duration(hours: 1)),
          manualHotUntil: now.add(const Duration(hours: 1)),
          manualHotEnabled: true,
        ),
      );
      fire = tester.widget<Icon>(
        find.byKey(const ValueKey('favorite-hot-window-fire-icon')),
      );
      expect(fire.icon, Icons.local_fire_department);
      expect(fire.color!.r, greaterThan(fire.color!.g));
    },
  );

  test('favorite hot-window action visibility has one valid combination', () {
    for (final enabled in <bool>[false, true]) {
      for (final favorite in <bool>[false, true]) {
        for (final tracked in <bool>[false, true]) {
          expect(
            shouldShowFavoriteHotWindowAction(
              followUpdatesEnabled: enabled,
              isFavorite: favorite,
              hasTrackedInfo: tracked,
            ),
            enabled && favorite && tracked,
          );
        }
      }
    }
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
              final show = shouldShowFavoriteHotWindowAction(
                followUpdatesEnabled: true,
                isFavorite: isFavorite,
                hasTrackedInfo: true,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: show
                    ? FavoriteHotWindowActionButton(
                        isLoading: false,
                        onFavorite: () => setState(() => isFavorite = false),
                        onFavoriteLongPress: () {},
                        info: _info(now),
                        clock: () => now,
                        onToggleHotWindow: () {},
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
    expect(
      find.byKey(const ValueKey('favorite-hot-window-split-button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-favorite-segment')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('favorite-hot-window-split-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('favorite-hot-window-hot-segment')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('ordinary-favorite-button')), findsOne);
  });
}
