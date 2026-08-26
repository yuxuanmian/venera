import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/search_page.dart';

void main() {
  testWidgets('search select options stay on one scrollable row and select', (
    tester,
  ) async {
    String? selectedValue;
    final option = SearchOptions(
      LinkedHashMap<String, String>.from({
        'dd': '新到旧',
        'da': '旧到新',
        'ld': '最多喜欢',
        'vd': '最多指名',
      }),
      'Sort',
      'select',
      null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              height: 200,
              child: SearchOptionWidget(
                option: option,
                value: 'dd',
                onChanged: (value) => selectedValue = value,
                sourceKey: 'test',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.byType(OptionChip), findsNWidgets(4));
    expect(tester.takeException(), isNull);

    final chipFinder = find.byType(OptionChip);
    _expectSingleChipRow(tester, chipFinder);
    _expectTitleSharesRow(tester, find.text('Sort'), chipFinder.first);

    final scrollView = find.byType(SingleChildScrollView);
    final viewport = tester.getRect(scrollView);
    expect(viewport.width, greaterThan(180));
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
    expect(selectedValue, 'vd');
    expect(tester.takeException(), isNull);
  });

  testWidgets('search multi-select options keep JSON toggle semantics', (
    tester,
  ) async {
    var selectedValue = jsonEncode(<String>[]);
    final option = SearchOptions(
      LinkedHashMap<String, String>.from({
        'dd': '新到旧',
        'da': '旧到新',
        'ld': '最多喜欢',
        'vd': '最多指名',
      }),
      'Sort',
      'multi-select',
      null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return SearchOptionWidget(
                    option: option,
                    value: selectedValue,
                    onChanged: (value) {
                      setState(() {
                        selectedValue = value;
                      });
                    },
                    sourceKey: 'test',
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    final chipFinder = find.byType(OptionChip);
    expect(chipFinder, findsNWidgets(4));
    expect(tester.takeException(), isNull);
    _expectSingleChipRow(tester, chipFinder);
    _expectTitleSharesRow(tester, find.text('Sort'), chipFinder.first);

    final scrollView = find.byType(SingleChildScrollView);
    final viewport = tester.getRect(scrollView);
    expect(viewport.width, greaterThan(180));
    await tester.drag(scrollView, const Offset(-1000, 0));
    await tester.pumpAndSettle();

    final lastChip = tester.getRect(chipFinder.last);
    expect(lastChip.left, greaterThanOrEqualTo(viewport.left - 0.1));
    expect(lastChip.right, lessThanOrEqualTo(viewport.right + 0.1));
    await tester.tap(chipFinder.last);
    await tester.pumpAndSettle();
    expect(jsonDecode(selectedValue), ['vd']);
    expect(tester.widget<OptionChip>(chipFinder.last).isSelected, isTrue);

    await tester.tap(chipFinder.last);
    await tester.pumpAndSettle();
    expect(jsonDecode(selectedValue), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

void _expectSingleChipRow(WidgetTester tester, Finder chipFinder) {
  final firstChip = tester.getRect(chipFinder.first);
  for (var index = 1; index < chipFinder.evaluate().length; index++) {
    final chip = tester.getRect(chipFinder.at(index));
    expect(chip.top, closeTo(firstChip.top, 0.001));
    expect(chip.bottom, closeTo(firstChip.bottom, 0.001));
  }
}

void _expectTitleSharesRow(
  WidgetTester tester,
  Finder titleFinder,
  Finder firstChipFinder,
) {
  final title = tester.getRect(titleFinder);
  final firstChip = tester.getRect(firstChipFinder);
  expect(title.center.dy, closeTo(firstChip.center.dy, 0.001));
  expect(title.top, lessThan(firstChip.bottom));
  expect(title.bottom, greaterThan(firstChip.top));
}
