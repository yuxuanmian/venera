import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'fakes.dart';

/// A credential-shaped and body-shaped sentinel.
///
/// SC-009 requires that none of these survive into persisted judgment state,
/// into the Debug rendering, or into the copy export.  Judgment writes no
/// runtime log at all (Contract J10.1), so there is no log path to cover.
const String sentinelToken = 'sentinel-token-9e4f1a7c';
const String sentinelCookie = 'sentinel-cookie-3b8d2e5f';
const String sentinelUrl = 'https://secret.example.invalid/leak';
const String sentinelBody =
    '<html>sentinel-structured-response-body-77ac</html>';

/// Builds observation JSON whose *values* carry secrets.
///
/// The scan codec only admits identifiers and validated timestamps into an
/// observation, so a secret can only reach judgment as an identifier-shaped
/// value — which is exactly the path this test exercises.
Map<String, Object?> hostileObservation() => {
  'update': {
    'latestChapterId': sentinelToken,
    'updatedAt': '2026-09-10T00:00:00Z',
  },
  'sourceUnread': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  late Directory tempDirectory;
  late SqliteJudgmentRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-judgment-p-');
    repository = SqliteJudgmentRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}state.db',
    );
    await repository.ensureOpen();
  });

  tearDown(() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  });

  test(
    'persistence keeps secrets out of everything but the source fact',
    () async {
      final observation = jsonEncode(hostileObservation());
      await repository.applyBatch([
        JudgmentState(
          sourceKey: 'src',
          comicId: 'comic-1',
          factJson: observation,
          factObservedAtMs: 1757000000000,
          evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
          lastDecision: JudgmentConclusion.changed,
          lastEvidence: JudgmentEvidence.latestChapterId,
          lastPreviousValue: 'previous-chapter',
          lastCurrentValue: sentinelToken,
          lastReason: JudgmentReason.different,
          decidedAtMs: 1758000000000,
        ),
      ]);

      final raw = repository.database
          .select('SELECT * FROM judgment_state')
          .single;
      final persisted = jsonEncode({
        for (final column in raw.keys) column: raw[column],
      });

      // The fact is the observation itself, so identifier-shaped values do
      // appear there; nothing else may.
      expect(persisted, contains(sentinelToken));
      for (final secret in const [sentinelCookie, sentinelUrl, sentinelBody]) {
        expect(
          persisted,
          isNot(contains(secret)),
          reason: '$secret must never be persisted',
        );
      }
      // No credential-shaped column was invented to hold the source response.
      expect(persisted, isNot(contains('cookie')));
      expect(persisted, isNot(contains('authorization')));
    },
  );

  testWidgets('the Debug page and its copy export stay redacted', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;

    final judgment = InMemoryJudgmentRepository();
    judgment.rows['judged-source\u0000comic-1'] = JudgmentState(
      sourceKey: 'judged-source',
      comicId: 'comic-1',
      factJson: jsonEncode({
        'update': {
          'updatedAt': '2026-09-10T00:00:00Z',
          'latestChapterId': sentinelToken,
        },
        'sourceUnread': true,
      }),
      factObservedAtMs: 1757000000000,
      evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
      lastDecision: JudgmentConclusion.changed,
      lastEvidence: JudgmentEvidence.latestChapterId,
      lastPreviousValue: sentinelUrl,
      lastCurrentValue: sentinelToken,
      lastReason: JudgmentReason.different,
      decidedAtMs: 1758000000000,
    );

    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: ComicDebugPage(
          sourceKey: 'judged-source',
          comicId: 'comic-1',
          scanRepository: InMemoryScanItemStore(),
          judgmentRepository: judgment,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Expand the fact so its rendered text is in the tree, then read every
    // rendered string.
    await tester.tap(find.text('Fact Content'));
    await tester.pumpAndSettle();
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join('\n');
    for (final secret in const [sentinelCookie, sentinelUrl, sentinelBody]) {
      expect(
        rendered,
        isNot(contains(secret)),
        reason: '$secret must never be rendered',
      );
    }

    await tester.tap(find.text('Copy Judgment Data'));
    await tester.pumpAndSettle();
    // Drain the copy-confirmation toast's dismissal timer.
    await tester.pump(const Duration(seconds: 3));
    expect(copied, hasLength(1));
    final export = copied.single;
    expect(export, isNotEmpty);
    for (final secret in const [sentinelCookie, sentinelUrl, sentinelBody]) {
      expect(
        export,
        isNot(contains(secret)),
        reason: '$secret must never be copied',
      );
    }
    // The URL-shaped previous value goes through the same redaction as the
    // existing diagnostics.
    expect(export, contains('[REDACTED_URL]'));
  });
}

class _EmptyCache extends NetworkFavoriteCacheManager {
  _EmptyCache() : super.forTesting();

  @override
  Set<String> getKnownFolderIds(String sourceKey, String comicId) => {};

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => const [];
}
