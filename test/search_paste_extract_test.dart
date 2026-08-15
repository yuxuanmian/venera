import 'package:flutter/material.dart';
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
  SearchBarController controller,
) async {
  // Mirrors production (main.dart): OverlayWidget sits inside MaterialApp so
  // the toast overlay has Directionality, and showToast's
  // findAncestorStateOfType<OverlayWidgetState> can resolve.
  await tester.pumpWidget(
    MaterialApp(
      home: OverlayWidget(Scaffold(body: AppSearchBar(controller: controller))),
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
}
