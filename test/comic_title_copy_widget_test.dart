import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  late String? copiedText;

  setUp(() {
    copiedText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('candidate dialog previews choices and copies the selected one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showComicTitleCopyMenu(
                context,
                title: '[作者] 原名 [Chinese]',
                subtitle: '副标题',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a title to copy'.tl), findsOneWidget);
    expect(find.text('原名'), findsOneWidget);
    expect(find.text('[作者] 原名 [Chinese]'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('comic-title-copy-candidate-原名')),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(copiedText, '原名');
    expect(find.text('Choose a title to copy'.tl), findsNothing);
  });

  testWidgets('candidate dialog remains scrollable on a small viewport', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showComicTitleCopyMenu(
                context,
                title: List.filled(30, '很长的漫画标题').join(' '),
                subtitle: '日本語タイトル',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a title to copy'.tl), findsOneWidget);
    expect(find.byType(Scrollable), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection-overlay context falls back to the root navigator', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) {
          return Column(
            children: [
              TextButton(
                onPressed: () {
                  expect(Navigator.maybeOf(context), isNull);
                  showComicTitleCopyMenu(context, title: '原名', subtitle: '副标题');
                },
                child: const Text('open-from-overlay'),
              ),
              if (child != null) Expanded(child: child),
            ],
          );
        },
        home: const SizedBox.shrink(),
      ),
    );

    await tester.tap(find.text('open-from-overlay'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a title to copy'.tl), findsOneWidget);
  });

  testWidgets('card menu exposes smart copy without removing raw copy', (
    tester,
  ) async {
    final comic = Comic(
      '[作者] 原名 [Chinese]',
      'file://${File('assets/app_icon.png').absolute.path}',
      'id',
      '副标题',
      null,
      '',
      'test-source',
      null,
      null,
    );
    final tile = ComicTile(comic: comic);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => tile.showMenu(const Offset(40, 40), context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(find.text('Copy Original Title'.tl), findsOneWidget);
    expect(find.text('Copy Title'.tl), findsOneWidget);
    final menuLabels = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .toList();
    expect(
      menuLabels.indexOf('Copy Title'.tl),
      lessThan(menuLabels.indexOf('Copy Original Title'.tl)),
    );

    await tester.tap(find.text('Copy Original Title'.tl));
    await tester.pumpAndSettle();
    expect(find.text('Choose a title to copy'.tl), findsOneWidget);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.tap(find.text('Copy Title'.tl));
    await tester.pump();
    expect(copiedText, comic.title);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('default card long press opens the smart-copy entry', (
    tester,
  ) async {
    final comic = Comic(
      '[作者] 原名 [Chinese]',
      'file://${File('assets/app_icon.png').absolute.path}',
      'id',
      '副标题',
      null,
      '',
      'test-source',
      null,
      null,
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ComicTile(comic: comic),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byType(ComicTile));
    await tester.pump();

    expect(find.text('Copy Original Title'.tl), findsOneWidget);
    expect(find.text('Copy Title'.tl), findsOneWidget);
    final longPressMenuLabels = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .toList();
    expect(
      longPressMenuLabels.indexOf('Copy Title'.tl),
      lessThan(longPressMenuLabels.indexOf('Copy Original Title'.tl)),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('detail title uses native selection and copy actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: ComicTitleSelectableText(text: '原名')),
      ),
    );

    expect(find.byType(SelectableText), findsOneWidget);
    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();

    final editableState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    expect(editableState.currentTextEditingValue.selection.isValid, isTrue);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copy Original Title'.tl), findsNothing);
  });

  testWidgets('tapping outside a selected title clears its selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const ComicTitleSelectableText(text: '原名'),
              const SizedBox(
                key: ValueKey('title-selection-outside'),
                height: 400,
                width: double.infinity,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();
    final editableState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    expect(editableState.widget.focusNode.hasFocus, isTrue);
    expect(editableState.currentTextEditingValue.selection.isValid, isTrue);

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();

    final clearedState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    expect(clearedState.widget.focusNode.hasFocus, isFalse);
    expect(clearedState.currentTextEditingValue.selection.isCollapsed, isTrue);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('detail title button opens the title candidate menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(
          body: SizedBox(
            width: 160,
            child: ComicTitleCopyButton(
              title: '[作者] 原名 [Chinese]',
              subtitle: '副标题',
              knownAuthors: ['作者'],
            ),
          ),
        ),
      ),
    );

    final buttonFinder = find.byKey(const ValueKey('comic-title-copy-button'));
    final buttonRect = tester.getRect(buttonFinder);
    expect(buttonRect.height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Copy Original Title'.tl), findsOneWidget);
    expect(find.text('Copy Original Title'.tl), findsNothing);
    expect(tester.widget<IconButton>(buttonFinder).iconSize, 14);
    expect(tester.takeException(), isNull);

    await tester.tap(buttonFinder);
    await tester.pumpAndSettle();
    expect(find.text('Choose a title to copy'.tl), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
  });
}
