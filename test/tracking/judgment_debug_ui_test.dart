import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'fakes.dart';

/// One persisted judgment state per conclusion class, plus the surrounding
/// identity needed by the Debug page.
JudgmentState judgmentRow({
  required String comicId,
  required JudgmentConclusion conclusion,
  required JudgmentReason reason,
  JudgmentEvidence? evidence,
  String? previousValue = 'chapter-41',
  String? currentValue = 'chapter-43',
  String? factJson = '{"update":{"latestChapterId":"chapter-43"}}',
  int? factObservedAtMs = 1757000000000,
  String? evidenceSchema = '{"latestchapterid":"last_chapter.id"}',
  int decidedAtMs = 1758000000000,
  int noCommonStreak = 0,
  bool hasNewUpdate = false,
}) => JudgmentState(
  sourceKey: 'judged-source',
  comicId: comicId,
  factJson: factJson,
  factObservedAtMs: factObservedAtMs,
  evidenceSchema: evidenceSchema,
  lastDecision: conclusion,
  lastEvidence: evidence,
  lastPreviousValue: previousValue,
  lastCurrentValue: currentValue,
  lastReason: reason,
  decidedAtMs: decidedAtMs,
  noCommonStreak: noCommonStreak,
  hasNewUpdate: hasNewUpdate,
  processedAttemptId: 'attempt-$comicId',
);

Future<void> pumpDebugPage(
  WidgetTester tester, {
  required String comicId,
  required InMemoryJudgmentRepository judgment,
  InMemoryScanItemStore? scans,
}) async {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: ComicDebugPage(
        sourceKey: 'judged-source',
        comicId: comicId,
        scanRepository: scans ?? InMemoryScanItemStore(),
        judgmentRepository: judgment,
        favoriteCache: _EmptyCache(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _EmptyCache extends NetworkFavoriteCacheManager {
  _EmptyCache() : super.forTesting();

  @override
  Set<String> getKnownFolderIds(String sourceKey, String comicId) => {};

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  testWidgets('shows each conclusion class with its reason', (tester) async {
    final judgment = InMemoryJudgmentRepository();
    judgment.rows['judged-source\u0000changed'] = judgmentRow(
      comicId: 'changed',
      conclusion: JudgmentConclusion.changed,
      reason: JudgmentReason.later,
      evidence: JudgmentEvidence.updatedAt,
    );
    judgment.rows['judged-source\u0000unchanged'] = judgmentRow(
      comicId: 'unchanged',
      conclusion: JudgmentConclusion.unchanged,
      reason: JudgmentReason.equal,
      evidence: JudgmentEvidence.latestChapterId,
    );
    judgment.rows['judged-source\u0000rebaseline'] = judgmentRow(
      comicId: 'rebaseline',
      conclusion: JudgmentConclusion.rebaseline,
      reason: JudgmentReason.labelChanged,
      evidence: JudgmentEvidence.latestChapterId,
    );
    judgment.rows['judged-source\u0000unknown'] = judgmentRow(
      comicId: 'unknown',
      conclusion: JudgmentConclusion.unknown,
      reason: JudgmentReason.noCommonEvidence,
      previousValue: null,
      currentValue: null,
      noCommonStreak: 3,
    );

    for (final entry in const {
      'changed': ('changed', 'later'),
      'unchanged': ('unchanged', 'equal'),
      'rebaseline': ('rebaseline', 'labelChanged'),
      'unknown': ('unknown', 'noCommonEvidence'),
    }.entries) {
      await pumpDebugPage(tester, comicId: entry.key, judgment: judgment);
      expect(find.text('Judgment'), findsOneWidget);
      expect(find.text('Conclusion'), findsOneWidget);
      expect(find.text(entry.value.$1), findsOneWidget, reason: entry.key);
      expect(find.text(entry.value.$2), findsOneWidget, reason: entry.key);
    }
  });

  testWidgets('shows previous and current values side by side', (tester) async {
    final judgment = InMemoryJudgmentRepository();
    judgment.rows['judged-source\u0000comic-1'] = judgmentRow(
      comicId: 'comic-1',
      conclusion: JudgmentConclusion.changed,
      reason: JudgmentReason.different,
      evidence: JudgmentEvidence.latestChapterId,
      previousValue: 'chapter-41',
      currentValue: 'chapter-43',
    );

    await pumpDebugPage(tester, comicId: 'comic-1', judgment: judgment);

    expect(find.text('Previous Value'), findsOneWidget);
    expect(find.text('chapter-41'), findsOneWidget);
    expect(find.text('Current Value'), findsOneWidget);
    expect(find.text('chapter-43'), findsOneWidget);
    expect(find.text('Selected Evidence'), findsOneWidget);
    expect(find.text('latestChapterId'), findsOneWidget);
  });

  testWidgets('the raw fact JSON is available in an expandable tile', (
    tester,
  ) async {
    final judgment = InMemoryJudgmentRepository();
    judgment.rows['judged-source\u0000comic-1'] = judgmentRow(
      comicId: 'comic-1',
      conclusion: JudgmentConclusion.changed,
      reason: JudgmentReason.later,
    );

    await pumpDebugPage(tester, comicId: 'comic-1', judgment: judgment);

    expect(find.text('Fact Content'), findsOneWidget);
    await tester.tap(find.text('Fact Content'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('chapter-43'),
      findsWidgets,
      reason: 'the fact JSON must be readable after expanding',
    );
    expect(find.text('Comparable Label'), findsOneWidget);
    expect(find.text('{"latestchapterid":"last_chapter.id"}'), findsOneWidget);
  });

  testWidgets('an absent record says so instead of showing a blank area', (
    tester,
  ) async {
    await pumpDebugPage(
      tester,
      comicId: 'never-judged',
      judgment: InMemoryJudgmentRepository(),
    );

    expect(find.text('Judgment'), findsOneWidget);
    expect(find.text('No Judgment Record'), findsOneWidget);
    expect(find.text('Conclusion'), findsNothing);
  });

  testWidgets('missing, failed and unusable evidence are distinguished', (
    tester,
  ) async {
    // No scan evidence at all.
    await pumpDebugPage(
      tester,
      comicId: 'comic-1',
      judgment: InMemoryJudgmentRepository(
        initial: {
          'judged-source\u0000comic-1': judgmentRow(
            comicId: 'comic-1',
            conclusion: JudgmentConclusion.unknown,
            reason: JudgmentReason.noUsableEvidence,
            previousValue: null,
            currentValue: null,
          ),
        },
      ),
    );
    expect(find.text('No Scan Evidence'), findsOneWidget);
    expect(find.text('No Usable Evidence'), findsOneWidget);

    // A failed scan item.
    await pumpDebugPage(
      tester,
      comicId: 'comic-2',
      judgment: InMemoryJudgmentRepository(
        initial: {
          'judged-source\u0000comic-2': judgmentRow(
            comicId: 'comic-2',
            conclusion: JudgmentConclusion.unknown,
            reason: JudgmentReason.noUsableEvidence,
            previousValue: null,
            currentValue: null,
          ),
        },
      ),
      scans: InMemoryScanItemStore(
        items: [
          ObservationSpec.failureItem(
            sourceKey: 'judged-source',
            comicId: 'comic-2',
          ),
        ],
      ),
    );
    expect(find.text('Scan Failed For This Comic'), findsOneWidget);
  });

  testWidgets('an unreadable store is reported, not shown as empty', (
    tester,
  ) async {
    await pumpDebugPage(
      tester,
      comicId: 'comic-1',
      judgment: _ThrowingJudgmentRepository(),
    );

    expect(find.text('Judgment State Unreadable'), findsOneWidget);
    expect(find.text('No Judgment Record'), findsNothing);
  });

  testWidgets(
    'the existing Raw Scan Result and history sections stay readable',
    (tester) async {
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(updatedAt: '2026-09-10').toStoredItem(
            sourceKey: 'judged-source',
            comicId: 'comic-1',
            evidenceSchema: '{"updatedat":"updated_at@day"}',
          ),
        ],
      );
      await pumpDebugPage(
        tester,
        comicId: 'comic-1',
        judgment: InMemoryJudgmentRepository(),
        scans: scans,
      );

      expect(find.text('Raw Scan Result'), findsOneWidget);
      // 007 (Contract D5) removed the historical disclaimer and the two
      // historical blocks; the same two positions now show current values.
      expect(find.text('Displayed scan state is historical'), findsNothing);
      expect(find.text('Follow-up State'), findsNothing);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Collection Scope'), findsOneWidget);
      expect(find.text('2026-09-10'), findsOneWidget);
    },
  );

  testWidgets('judgment translations exist for both shipped locales', (
    tester,
  ) async {
    const keys = [
      'Judgment',
      'Conclusion',
      'Selected Evidence',
      'Previous Value',
      'Current Value',
      'Reason',
      'Fact Content',
      'Fact Observed At',
      'Comparable Label',
      'Has New Update',
      'Decided At',
      'No Common Field Streak',
      'No Judgment Record',
      'No Previous Fact',
      'No Usable Evidence',
      'Scan Failed For This Comic',
      'No Scan Evidence',
      'Judgment State Unreadable',
      'Copy Judgment Data',
    ];
    for (final locale in ['zh_CN', 'zh_TW']) {
      final values = AppTranslation.translations[locale]!;
      for (final key in keys) {
        expect(values[key], isNotNull, reason: '$locale is missing $key');
      }
    }

    final previousLanguage = appdata.settings['language'];
    addTearDown(() => appdata.settings['language'] = previousLanguage);
    appdata.settings['language'] = 'en-US';
    expect('Judgment'.tl, 'Judgment');
    appdata.settings['language'] = 'zh-CN';
    expect('Judgment'.tl, '判定');
    expect('No Judgment Record'.tl, '尚无判定记录');
    appdata.settings['language'] = 'zh-TW';
    expect('No Judgment Record'.tl, '尚無判定記錄');
  });
}

/// A store that always fails, standing in for a corrupt database file.
class _ThrowingJudgmentRepository extends InMemoryJudgmentRepository {
  @override
  Future<JudgmentState?> readFor(String sourceKey, String comicId) async {
    throw const JudgmentStorageException('synthetic unreadable store');
  }
}
