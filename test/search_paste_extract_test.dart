import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

// AppTranslation.translations is a `late final` static: init() can only run
// once per test process, so guard it.
bool _translationsReady = false;

Future<void> _ensureTranslations() async {
  if (!_translationsReady) {
    _translationsReady = true;
    await AppTranslation.init();
  }
}

Future<void> _pumpSearchBar(
  WidgetTester tester,
  SearchBarController controller, {
  bool sliver = false,
}) async {
  // Mirrors production (main.dart): OverlayWidget sits inside MaterialApp so
  // the toast overlay has Directionality, and showToast's
  // findAncestorStateOfType<OverlayWidgetState> can resolve.
  await tester.pumpWidget(
    MaterialApp(
      home: OverlayWidget(
        Scaffold(
          body: sliver
              ? CustomScrollView(
                  slivers: [SliverSearchBar(controller: controller)],
                )
              : AppSearchBar(controller: controller),
        ),
      ),
    ),
  );
}

/// Paste [text] into the search field and pump until the recognition toast
/// (if any) is built.
Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump();
}

Future<void> _pasteWithShortcut(WidgetTester tester) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

void main() {
  group('insertedText', () {
    test('insert at end', () {
      expect(insertedText('abc', 'abc12345'), '12345');
    });

    test('insert at cursor in the middle', () {
      expect(insertedText('abXc', 'ab123Xc'), '123');
    });

    test('insert into empty text', () {
      expect(insertedText('', 'abc'), 'abc');
    });

    test('replace selection', () {
      expect(insertedText('abcd', 'ab12345'), '12345');
    });

    test('no insertion returns null', () {
      expect(insertedText('abc', 'abc'), isNull);
      expect(insertedText('abc', 'ab'), isNull);
      expect(insertedText('abc', 'axc'), isNull);
    });
  });

  group('extractIdFromText', () {
    test('concatenates all digits in order', () {
      expect(extractIdFromText('abc12345def'), '12345');
      expect(extractIdFromText('123 45678'), '12345678');
      expect(extractIdFromText('12ab34cd5e'), '12345');
      expect(extractIdFromText('12 34 5'), '12345');
      expect(extractIdFromText('https://a.com/123/p/456?x=789'), '123456789');
    });

    test('pure number returns null (nothing to extract)', () {
      expect(extractIdFromText('12345'), isNull);
      expect(extractIdFromText('12345678'), isNull);
    });

    test('too few digits returns null', () {
      expect(extractIdFromText('1234'), isNull);
      expect(extractIdFromText('abc'), isNull);
      expect(extractIdFromText(''), isNull);
    });

    test('minDigits parameter boundary', () {
      expect(extractIdFromText('a1234b', minDigits: 4), '1234');
      expect(extractIdFromText('a123456b', minDigits: 6), '123456');
      expect(extractIdFromText('a12345b', minDigits: 6), isNull);
    });

    test('trailing whitespace around pure number still extracts', () {
      expect(extractIdFromText('12345 '), '12345');
    });
  });

  group('search bar paste extraction', () {
    const toastMessage = 'Detected number 12345 in pasted text';

    testWidgets(
      'extract fills the search box and hides the toast immediately',
      (tester) async {
        await _ensureTranslations();
        var controller = SearchBarController();
        await _pumpSearchBar(tester, controller);

        await _paste(tester, 'abc12345');
        expect(find.text(toastMessage), findsOneWidget);

        await tester.tap(find.text('Extract'));
        await tester.pump();

        expect(controller.text, '12345');
        expect(find.text(toastMessage), findsNothing);
      },
    );

    testWidgets('pasting the same text again after deleting re-triggers', (
      tester,
    ) async {
      await _ensureTranslations();
      var controller = SearchBarController();
      await _pumpSearchBar(tester, controller);

      await _paste(tester, 'abc12345');
      expect(find.text(toastMessage), findsOneWidget);

      await tester.tap(find.text('Extract'));
      await tester.pump();
      expect(controller.text, '12345');

      // Delete the extracted number, then paste the same content again.
      await _paste(tester, '');
      await _paste(tester, 'abc12345');

      expect(find.text(toastMessage), findsOneWidget);
    });
  });

  test('recognizes complete JM numbers without losing leading zeros', () {
    expect(parseJmComicId('JM123456'), '123456');
    expect(parseJmComicId(' jm012345 '), '012345');
    expect(parseJmComicId('Jm123456'), '123456');
    expect(parseJmComicId('123456'), isNull);
    expect(parseJmComicId('123456', requirePrefix: false), '123456');
    expect(parseJmComicId('JM123456 extra'), isNull);
    expect(parseJmComicId('prefix JM123456'), isNull);
  });

  group('search title paste', () {
    late String? clipboardText;
    var clipboardReads = 0;

    setUp(() {
      clipboardText = null;
      clipboardReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.hasStrings') {
              return {'value': clipboardText?.isNotEmpty ?? false};
            }
            if (call.method == 'Clipboard.getData') {
              clipboardReads++;
              return clipboardText == null ? null : {'text': clipboardText};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
      'keyboard paste replaces only the selection and leaves search unsubmitted',
      (tester) async {
        await _ensureTranslations();
        clipboardText = '[某某汉化] 漫画标题 [DL版]';
        var submitted = false;
        final controller = SearchBarController(
          onSearch: (_) => submitted = true,
        );
        await _pumpSearchBar(tester, controller, sliver: true);

        final field = find.byType(TextField);
        await tester.enterText(field, 'prefix old suffix');
        final editing = tester.widget<TextField>(field).controller!;
        editing.selection = const TextSelection(
          baseOffset: 10,
          extentOffset: 7,
        );
        await tester.pump();
        await _pasteWithShortcut(tester);

        expect(find.byType(AlertDialog), findsOneWidget);
        final title = find.widgetWithText(FilterChip, '漫画标题');
        expect(tester.widget<FilterChip>(title).selected, isTrue);
        await tester.tap(find.widgetWithText(FilterChip, '[DL版]'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Paste'.tl));
        await tester.pumpAndSettle();

        expect(controller.currentText, 'prefix 漫画标题 [DL版] suffix');
        expect(
          editing.selection,
          TextSelection.collapsed(offset: 'prefix 漫画标题 [DL版]'.length),
        );
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(submitted, isFalse);
        expect(clipboardReads, 1);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );

    testWidgets(
      'long-press paste can insert the original text when all parts are selected',
      (tester) async {
        await _ensureTranslations();
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 480);
        clipboardText = '[某某汉化]  漫画标题 [DL版]';
        final controller = SearchBarController();
        await _pumpSearchBar(tester, controller);
        final field = find.byType(TextField);
        await tester.longPress(field);
        await tester.pumpAndSettle();
        final pasteLabel = MaterialLocalizations.of(
          tester.element(field),
        ).pasteButtonLabel;
        await tester.tap(find.text(pasteLabel));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          tester.getRect(find.widgetWithText(FilledButton, 'Paste'.tl)).bottom,
          lessThan(tester.getRect(find.byType(AlertDialog)).bottom),
        );
        for (final tag in ['[某某汉化]', '[DL版]']) {
          await tester.tap(find.widgetWithText(FilterChip, tag));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Paste'.tl));
        await tester.pumpAndSettle();

        expect(controller.currentText, clipboardText);
        expect(clipboardReads, 1);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'cancelling title paste keeps the text and selection',
      (tester) async {
        await _ensureTranslations();
        clipboardText = '漫画标题 [DL版]';
        final controller = SearchBarController();
        await _pumpSearchBar(tester, controller);
        final field = find.byType(TextField);
        await tester.enterText(field, 'original');
        final editing = tester.widget<TextField>(field).controller!;
        editing.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
        final previous = editing.value;
        await tester.pump();
        await _pasteWithShortcut(tester);
        expect(find.byType(AlertDialog), findsOneWidget);

        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(editing.value, previous);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );

    testWidgets('a selection dialog cannot overwrite a changed query', (
      tester,
    ) async {
      await _ensureTranslations();
      clipboardText = '漫画标题 [DL版]';
      final controller = SearchBarController();
      await _pumpSearchBar(tester, controller);
      await tester.enterText(find.byType(TextField), 'original');
      await _pasteWithShortcut(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      controller.setText('new query');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Paste'.tl));
      await tester.pumpAndSettle();

      expect(controller.text, 'new query');
    });

    testWidgets('input-method clipboard paste uses the submitted text', (
      tester,
    ) async {
      await _ensureTranslations();
      clipboardText = 'unrelated current clipboard text';
      final controller = SearchBarController();
      await _pumpSearchBar(tester, controller, sliver: true);
      final field = find.byType(TextField);
      const oldText = 'A a long selected query to replace Z';
      const imeText = '[某某汉化] 漫画标题 [DL版]';
      await tester.enterText(field, oldText);
      final editing = tester.widget<TextField>(field).controller!;
      editing.selection = TextSelection(
        baseOffset: oldText.length - 2,
        extentOffset: 2,
      );
      final before = editing.value;
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: 'A $imeText Z',
          selection: TextSelection.collapsed(offset: 2 + imeText.length),
        ),
      );
      await tester.pumpAndSettle();

      expect(editing.value, before);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '[某某汉化]'), findsOneWidget);
      final paste = find.widgetWithText(FilledButton, 'Paste'.tl);
      await tester.tap(paste);
      await tester.pumpAndSettle();

      expect(controller.currentText, 'A 漫画标题 Z');
      expect(editing.selection, const TextSelection.collapsed(offset: 6));
      expect(clipboardReads, 0);
    });

    testWidgets('cancelling an input-method paste keeps the existing query', (
      tester,
    ) async {
      await _ensureTranslations();
      final controller = SearchBarController();
      await _pumpSearchBar(tester, controller);
      final field = find.byType(TextField);
      await tester.enterText(field, 'A Z');
      final editing = tester.widget<TextField>(field).controller!;
      editing.selection = const TextSelection.collapsed(offset: 2);
      final before = editing.value;
      await tester.pump();

      const inserted = '漫画标题 [DL版]';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: 'A ${inserted}Z',
          selection: TextSelection.collapsed(offset: 2 + inserted.length),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(editing.value, before);
      expect(clipboardReads, 0);
    });

    testWidgets('composing and committing text in an IME leaves it intact', (
      tester,
    ) async {
      await _ensureTranslations();
      final controller = SearchBarController();
      await _pumpSearchBar(tester, controller);
      await tester.showKeyboard(find.byType(TextField));
      const text = '漫画标题 [DL版]';
      final composing = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.currentText, text);
    });

    testWidgets(
      'plain paste inserts at the cursor and keeps number extraction',
      (tester) async {
        await _ensureTranslations();
        clipboardText = 'abc12345';
        final controller = SearchBarController();
        await _pumpSearchBar(tester, controller);
        final field = find.byType(TextField);
        await tester.enterText(field, '()');
        final editing = tester.widget<TextField>(field).controller!;
        editing.selection = const TextSelection.collapsed(offset: 1);
        await tester.pump();
        await _pasteWithShortcut(tester);

        expect(find.byType(AlertDialog), findsNothing);
        expect(controller.currentText, '(abc12345)');
        expect(editing.selection, const TextSelection.collapsed(offset: 9));
        expect(
          find.text('Detected number 12345 in pasted text'),
          findsOneWidget,
        );
      },
    );
  });
}
