import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'picacg-category-layout-test';
const _categoryKey = 'picacg-category-layout-test-key';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  testWidgets('PicACG category options stay on one scrollable row', (
    tester,
  ) async {
    final loadedOptions = <List<String>>[];
    final previousDisplayMode = appdata.settings['comicListDisplayMode'];
    appdata.settings['comicListDisplayMode'] = 'paging';
    addTearDown(() {
      appdata.settings['comicListDisplayMode'] = previousDisplayMode;
      ComicSourceManager().remove(_sourceKey);
    });
    ComicSourceManager().add(_picAcgSource(loadedOptions));
    await tester.binding.setSurfaceSize(const Size(260, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: CategoryComicsPage(category: 'All', categoryKey: _categoryKey),
      ),
    );
    await tester.pumpAndSettle();

    final chipFinder = find.byType(OptionChip);
    expect(chipFinder, findsNWidgets(4));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);

    final firstChip = tester.getRect(chipFinder.first);
    for (var index = 1; index < chipFinder.evaluate().length; index++) {
      final chip = tester.getRect(chipFinder.at(index));
      expect(chip.top, closeTo(firstChip.top, 0.001));
      expect(chip.bottom, closeTo(firstChip.bottom, 0.001));
    }

    final label = tester.getRect(find.text('排序'));
    expect(label.bottom, lessThanOrEqualTo(firstChip.top));

    final scrollView = find.byType(SingleChildScrollView);
    final viewport = tester.getRect(scrollView);
    await tester.drag(scrollView, const Offset(-1000, 0));
    await tester.pumpAndSettle();

    final lastChip = tester.getRect(chipFinder.last);
    expect(lastChip.left, greaterThanOrEqualTo(viewport.left - 0.1));
    expect(lastChip.right, lessThanOrEqualTo(viewport.right + 0.1));
    expect(
      tester
          .state<ScrollableState>(
            find.descendant(of: scrollView, matching: find.byType(Scrollable)),
          )
          .position
          .pixels,
      greaterThan(0),
    );

    await tester.tap(chipFinder.last);
    await tester.pumpAndSettle();
    expect(tester.widget<OptionChip>(chipFinder.last).isSelected, isTrue);
    expect(loadedOptions.last, ['vd']);
    expect(tester.takeException(), isNull);
  });
}

ComicSource _picAcgSource(List<List<String>> loadedOptions) {
  return ComicSource(
    'PicACG layout test source',
    _sourceKey,
    null,
    const CategoryData(
      title: 'Categories',
      categories: [],
      enableRankingPage: false,
      key: _categoryKey,
    ),
    CategoryComicsData(
      options: [
        CategoryComicsOptions(
          '排序',
          LinkedHashMap<String, String>.from({
            'dd': '新到旧',
            'da': '旧到新',
            'ld': '最多喜欢',
            'vd': '最多指名',
          }),
          const [],
          null,
        ),
      ],
      load: (category, param, options, page) async {
        loadedOptions.add(List<String>.from(options));
        return const Res(<Comic>[], subData: 1);
      },
    ),
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
