import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Contract: every user-visible string this feature adds must exist in **both**
/// shipped locales.
///
/// The app renders most strings through `.tl`, which falls back to the key
/// itself.  A missing translation therefore does not crash and does not fail
/// analysis — it silently shows English to a Chinese reader.  This test is the
/// only thing that notices.
///
/// Written against the asset file directly rather than through
/// `AppTranslation`, so it also covers strings that only appear on a code path
/// the widget tests do not reach.
void main() {
  /// Every string feature 006 introduced, grouped by the contract section that
  /// requires it.
  const required = <String, List<String>>{
    // Contract F2.3 / F2.4 — the pre-condition gate.
    'gate': [
      'No source can be followed',
      'Favorites are not fully cached yet',
      'Enable and sign in to at least one source that supports scanning.',
      'Follow-up results need a complete favorite cache for every tracked source.',
      '@c sources still pending',
      '@c sources are not fully cached yet, so they are not followed',
      'This source is not followed yet: its favorites are not fully cached',
      'Cache favorites completely',
      'Caching favorites',
      'Caching is not finished yet',
      'Favorites are fully cached now',
      'Show updates',
    ],
    // Contract F5 — progress and cancellation.
    'progress': [
      '@done/@total tasks',
      'Finding what to check',
      'A check is already in progress',
      'No check is running',
      'Cancel',
    ],
    // Contract F3.4 — the exit's empty and error states.
    'exit': [
      'Update state could not be read',
      'Retry',
      'No updates found',
      'Updates',
    ],
    // Contract F8 — the account-switch explanation.
    'account switch': [
      'Account switched',
      'Follow-up needs a complete favorite cache again after switching accounts.',
    ],
    // Contract F2.6 — the debug-only bypass.
    'debug bypass': [
      'Bypass the follow-up gate (debug)',
      'Shows the list even when the cache is incomplete.',
    ],
    // 007 Contract W — the read-only "recently updated" indicator.  Its tooltip
    // is the only place the exact deadline is available to the reader (W5), so a
    // missing translation would silently hide the explanation in one locale.
    'indicator (007)': [
      'Recently updated',
      'No recent update',
      'Auto hot window until @time',
      'Recently changed at @time',
    ],
    // 007 Contract D — the two in-place Debug blocks.  The defaults are part of
    // the contract (D4: a default MUST be distinguishable from a real value and
    // MUST NOT use an action verb), so they are translated like any other label.
    'debug blocks (007)': [
      'Schedule',
      'Activity Anchor',
      'Auto Hot Window',
      'Auto Hot Until',
      'Schedule Jitter Applied',
      'Collection Scope',
      'Scan Capability',
      'Scan Preferred Method',
      'Scan Capability Invalid',
      'Invalid scan capability',
      'Scope Type',
      'Scope Key',
      'Scope Started',
      'Scope Finished',
      'Scope Items',
      'Scope Failure',
      'No check record',
      'No scan record',
      'No scope record',
      'Not computed yet',
      'Active',
      'Inactive',
      'Not finished',
      'Schedule State Unreadable',
      'Scan State Unreadable',
      'No scan capability',
    ],
  };

  late Map<String, dynamic> translations;

  setUpAll(() {
    final file = File('assets/translation.json');
    expect(file.existsSync(), isTrue, reason: 'translation asset must exist');
    translations = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('both shipped locales are present', () {
    expect(translations.keys.toSet(), containsAll(<String>['zh_CN', 'zh_TW']));
  });

  for (final entry in required.entries) {
    test('every ${entry.key} string exists in both locales', () {
      for (final locale in const ['zh_CN', 'zh_TW']) {
        final table = translations[locale] as Map<String, dynamic>;
        for (final key in entry.value) {
          expect(
            table.containsKey(key),
            isTrue,
            reason: '"$key" is missing from $locale',
          );
          final value = table[key];
          expect(
            value,
            isA<String>(),
            reason: '"$key" in $locale must map to a string',
          );
          expect(
            (value as String).trim(),
            isNotEmpty,
            reason: '"$key" in $locale must not be blank',
          );
        }
      }
    });
  }

  test('a translation in one locale is never left to the other', () {
    // The failure this catches is the realistic one: adding the English key and
    // its zh_CN text, then forgetting zh_TW.
    final zhCn = translations['zh_CN'] as Map<String, dynamic>;
    final zhTw = translations['zh_TW'] as Map<String, dynamic>;
    final onlyInZhCn = <String>[];
    for (final entry in required.entries) {
      for (final key in entry.value) {
        if (zhCn.containsKey(key) && !zhTw.containsKey(key)) {
          onlyInZhCn.add(key);
        }
      }
    }
    expect(onlyInZhCn, isEmpty, reason: 'present in zh_CN but not zh_TW');
  });

  /// The retired manual hot-window wording MUST stay in the asset.
  ///
  /// 007 removed the switch, so nothing renders these strings any more.  Their
  /// keys are kept deliberately: `follow_update_hot_window_widget_test.dart`
  /// asserts they are **not** rendered, and a reverse guard can only work while
  /// the key it guards still exists.  Deleting them would turn "the wording is
  /// gone" into "the key is gone", which passes for the wrong reason.
  test('retired manual hot-window keys survive for the reverse guards', () {
    const retired = <String>[
      'Enable 14-day hot window',
      'Disable 14-day hot window',
    ];
    for (final locale in const ['zh_CN', 'zh_TW']) {
      final table = translations[locale] as Map<String, dynamic>;
      for (final key in retired) {
        expect(
          table.containsKey(key),
          isTrue,
          reason: '"$key" must stay in $locale as the reverse guard anchor',
        );
      }
    }
  });

  test('the two locales do not simply repeat one another', () {
    // A placeholder-filled key whose translations are identical often means the
    // zh_TW entry was copy-pasted from zh_CN, which is a real defect for
    // Simplified/Traditional pairs.  Keys that legitimately match (placeholders
    // and loan words) are excluded.
    // Keys that legitimately match across the pair: placeholders, loan words,
    // and pre-existing entries whose Simplified and Traditional forms happen to
    // be written identically.  `No updates found` and `Updates` are in the
    // last group — they predate this feature and are not this feature's to
    // reword.  The three Debug labels below have no Simplified/Traditional
    // distinction at all (排期 / 生效中 / 未生效), which is why they read the
    // same in both locales.
    const legitimatelyIdentical = <String>{
      'Cancel',
      '@done/@total tasks',
      'No updates found',
      'Updates',
      'Schedule',
      'Active',
      'Inactive',
    };
    final identical = <String>[];
    final zhCn = translations['zh_CN'] as Map<String, dynamic>;
    final zhTw = translations['zh_TW'] as Map<String, dynamic>;
    for (final entry in required.entries) {
      for (final key in entry.value) {
        if (legitimatelyIdentical.contains(key)) continue;
        if (zhCn[key] == zhTw[key]) identical.add(key);
      }
    }
    expect(
      identical,
      isEmpty,
      reason:
          'these read the same in both locales, which usually means one '
          'was copied from the other',
    );
  });
}
