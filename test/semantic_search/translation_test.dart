import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/translations.dart';

/// Feature 008 / T061 — localization contract for the Tag semantic search page.
///
/// `lib/pages/semantic_search_page.dart` renders the keys below through `.tl`
/// and `.tlParams`. `.tl` falls back to the English key when the current locale
/// block has no entry, so an incomplete block does not crash, does not fail
/// `flutter analyze`, and does not fail a widget test that only asserts the
/// English text — it silently shows English to a Chinese reader. This test is
/// what notices.
///
/// The locale blocks are *discovered* from the asset instead of being
/// hard-coded, so a block added later without these keys fails here rather than
/// shipping half-translated. The tables are read back from
/// [AppTranslation.translations] after `AppTranslation.init()`, so the test
/// asserts against what the app actually ships, not against a private re-parse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The six T061 keys, in the order the scope lists them.
  const requiredKeys = <String>[
    // 1. The fixed page title; `@a` carries the source-produced opaque value.
    'Tag: @a',
    // 2. Terminal unsupported state: the source declared no Tag search.
    'This comic source cannot search by tag',
    // 3. The ordinary-fallback notice: compatibility mode never claims exact
    //    Tag semantics.
    'This source has no exact tag search; results are not guaranteed to be exact.',
    // 4. The waiting-for-continue footer: the current range is empty but the
    //    source still has more candidates to scan.
    'No matches in the current range. Continue scrolling to search further.',
    // 5. The finished footer.
    'Finished',
    // 6. The generic error fallback.
    'Network Error',
    // 7. Host-generated errors surfaced by the full-page and footer error
    //    states. A source's own passthrough error text is never translated.
    'Semantic search failed',
    'Semantic source cursor did not advance',
    'This source does not support semantic search',
    'Semantic source pagination form changed',
    'Semantic source declared an invalid maxPage',
    'Semantic source declared an invalid cursor',
  ];

  /// Keys the page also uses that already existed before this feature. They are
  /// verified, never added or reworded.
  const preExistingKeys = <String>['Retry', 'Settings', 'Confirm'];

  const titleKey = 'Tag: @a';
  const titlePlaceholder = '@a';

  /// What `AppTranslation.init()` loaded — the tables the app renders from.
  late Map<String, Map<String, String>> loaded;

  /// What the asset declares at its top level.
  late Set<String> declaredLocales;

  setUpAll(() async {
    await AppTranslation.init();
    loaded = AppTranslation.translations;

    // Read the asset independently of `init()` so the declared block list is
    // authoritative: a block that never reaches `loaded` must not be able to
    // hide a missing key behind a short discovery list.
    final file = File('assets/translation.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'assets/translation.json must exist',
    );
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    declaredLocales = raw.keys.toSet();
  });

  test('every declared locale block is loaded, and none is missing', () {
    expect(
      declaredLocales,
      isNotEmpty,
      reason: 'assets/translation.json must declare at least one locale block',
    );
    expect(
      loaded.keys.toSet(),
      declaredLocales,
      reason:
          'AppTranslation.init() must load exactly the blocks the asset '
          'declares; a mismatch means this test inspects the wrong table',
    );
  });

  test(
    'every locale block defines all six page keys with a non-empty value',
    () {
      for (final locale in declaredLocales) {
        expect(
          loaded.containsKey(locale),
          isTrue,
          reason: '$locale must be loaded by AppTranslation.init()',
        );
        final table = loaded[locale] ?? const <String, String>{};
        for (final key in requiredKeys) {
          expect(
            table.containsKey(key),
            isTrue,
            reason: '"$key" is missing from the $locale block',
          );
          expect(
            (table[key] ?? '').trim(),
            isNotEmpty,
            reason: '"$key" in $locale must not be blank',
          );
        }
      }
    },
  );

  test('every locale keeps the @a placeholder verbatim in the page title', () {
    // The value is an opaque source token: it is never trimmed, re-cased or
    // reparsed. A block that drops or rewrites `@a` renders a title with no
    // Tag value at all, and `.tlParams` cannot recover from it.
    for (final locale in declaredLocales) {
      final value = loaded[locale]?[titleKey] ?? '';
      expect(
        value.contains(titlePlaceholder),
        isTrue,
        reason:
            '"$titleKey" in $locale must keep the $titlePlaceholder '
            'placeholder; got "$value"',
      );
    }
  });

  test('the six keys are uniformly present across every locale block', () {
    // The realistic defect is adding a key to one block and forgetting another.
    // Presence is therefore compared per key: a key defined by some blocks but
    // not all is a failure, whichever block it is.
    final locales = declaredLocales.toList()..sort();
    final problems = <String>[];
    for (final key in requiredKeys) {
      final defining = locales
          .where((locale) => loaded[locale]?.containsKey(key) ?? false)
          .toSet();
      if (defining.isEmpty) {
        problems.add('"$key" is defined by no locale block');
        continue;
      }
      for (final locale in locales) {
        if (!defining.contains(locale)) {
          problems.add(
            '"$key" is defined by ${defining.length} of ${locales.length} '
            'blocks but not by $locale',
          );
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the pre-existing keys the page reuses stay available', () {
    for (final locale in declaredLocales) {
      final table = loaded[locale] ?? const <String, String>{};
      for (final key in preExistingKeys) {
        expect(
          table.containsKey(key),
          isTrue,
          reason: '"$key" is missing from the $locale block',
        );
        expect(
          (table[key] ?? '').trim(),
          isNotEmpty,
          reason: '"$key" in $locale must not be blank',
        );
      }
    }
  });
}
