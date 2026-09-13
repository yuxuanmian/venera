import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/failure_sanitizer.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'fakes.dart';

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('details Debug reads and shows the committed raw scan result', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    final repository = FakeScanResultRepository();
    final scope = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-4',
    );
    final item = ScanItemResult.observed(
      attemptId: scanUuidV5(scope.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: scope.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-4',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'chapter-9'),
        sourceUnread: false,
      ),
    );
    await repository.saveItem(ScanIngestionContext(scope: scope), item);
    await repository.finishScope(
      ScanIngestionContext(scope: scope),
      ScanScopeStatus.completed,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ComicDebugPage(
          sourceKey: 'source',
          comicId: 'comic-1',
          scanRepository: repository,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Raw Scan Result'), findsOneWidget);
    expect(find.text('Latest Chapter ID'), findsOneWidget);
    expect(find.text('chapter-9'), findsOneWidget);
    expect(find.text('Definition Revision'), findsOneWidget);
    expect(find.text('rev-4'), findsOneWidget);
    expect(
      find.text('completed'),
      findsNWidgets(2),
      reason:
          'exactly two blocks present the stored scope status: the pre-007 '
          '"Raw Scan Result" raw dump and the 007 "Collection Scope" block, '
          'which Contract D3 renders as a set of fields.  Pinned to a count so '
          'that a third copy cannot appear unnoticed (Contract D1).',
    );
    // 007 replaced the historical follow-up block with the two current-value
    // blocks (Contract D); this page is checked in detail in
    // test/scan_retirement/debug_schedule_fields_test.dart.
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Collection Scope'), findsOneWidget);
  });

  testWidgets('details Debug exposes latest failure without the old success', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    final repository = FakeScanResultRepository();
    final first = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    final firstItem = ScanItemResult.observed(
      attemptId: scanUuidV5(first.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: first.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-1',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'old-chapter'),
      ),
    );
    await repository.saveItem(ScanIngestionContext(scope: first), firstItem);
    await repository.finishScope(
      ScanIngestionContext(scope: first),
      ScanScopeStatus.completed,
    );
    final second = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-2',
    );
    final latest = ScanItemResult.failed(
      attemptId: scanUuidV5(second.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: second.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-2',
      observedAt: '2026-09-10T00:00:01.000Z',
      failure: const ScanFailure(httpStatus: 403, message: 'forbidden'),
    );
    await repository.saveItem(ScanIngestionContext(scope: second), latest);

    await tester.pumpWidget(
      MaterialApp(
        home: ComicDebugPage(
          sourceKey: 'source',
          comicId: 'comic-1',
          scanRepository: repository,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HTTP Status'), findsOneWidget);
    expect(find.text('403'), findsOneWidget);
    expect(find.text('old-chapter'), findsNothing);
    expect(find.text('rev-2'), findsOneWidget);
  });

  testWidgets('Copy Scan Result contains only the persisted safe whitelist', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;

    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final repository = FakeScanResultRepository();
    final first = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    final observed = ScanItemResult.observed(
      attemptId: scanUuidV5(first.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: first.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-1',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'chapter-visible'),
      ),
    );
    await repository.saveItem(ScanIngestionContext(scope: first), observed);
    await repository.finishScope(
      ScanIngestionContext(scope: first),
      ScanScopeStatus.completed,
    );

    final details = ComicDetails.fromJson({
      'title': 'widget-details-secret',
      'description': 'private-body-secret cursor-secret guard-secret',
      'cover': 'https://private.example/cover?token=cover-secret',
      'tags': {
        'secret': ['source-data-secret'],
      },
      'chapters': <String, String>{'1': 'Chapter 1'},
      'sourceKey': 'source',
      'comicId': 'comic-1',
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ComicDebugPage(
          sourceKey: 'source',
          comicId: 'comic-1',
          details: details,
          scanRepository: repository,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Scan Result'.tl));
    await tester.pump();

    expect(copied, hasLength(1));
    final observedJson = jsonDecode(copied.single) as Map<String, dynamic>;
    final observedResult = observedJson['result'] as Map<String, dynamic>;
    expect(observedResult['observation'], isA<Map>());
    expect(observedResult['failure'], isNull);
    expect(copied.single, contains('chapter-visible'));
    for (final secret in [
      'widget-details-secret',
      'private-body-secret',
      'cursor-secret',
      'guard-secret',
      'cover-secret',
      'source-data-secret',
    ]) {
      expect(copied.single, isNot(contains(secret)));
    }

    final second = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-2',
    );
    final failed = ScanItemResult.failed(
      attemptId: scanUuidV5(second.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: second.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-2',
      observedAt: '2026-09-10T00:00:01.000Z',
      failure: FailureSanitizer.sanitize({
        'httpStatus': 403,
        'sourceCode': 'token:source-code-shaped-secret',
        'exceptionType': 'TransportError password=exception-secret',
        'message':
            'diagnostic prefix {"opaque":"json-body-secret"} '
            '<svg><title>markup-body-secret</title></svg>',
      }),
    );
    await repository.saveItem(ScanIngestionContext(scope: second), failed);
    await tester.pumpAndSettle();

    expect(find.text('old-chapter'), findsNothing);
    expect(find.text('403'), findsOneWidget);
    await tester.tap(find.text('Copy Scan Result'.tl));
    await tester.pump();

    expect(copied, hasLength(2));
    final failedJson = jsonDecode(copied.last) as Map<String, dynamic>;
    final failedResult = failedJson['result'] as Map<String, dynamic>;
    expect(failedResult['failure'], isA<Map>());
    expect(failedResult['observation'], isNull);
    for (final secret in [
      'source-code-secret',
      'source-code-shaped-secret',
      'exception-secret',
      'header-secret',
      'session-secret',
      'second-cookie-secret',
      'password-secret',
      'basic-secret',
      'query-secret',
      'response-body-secret',
      'json-body-secret',
      'markup-body-secret',
      'widget-details-secret',
    ]) {
      expect(copied.last, isNot(contains(secret)));
    }
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a replaced scope is reported instead of associating a new one', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    final repository = FakeScanResultRepository();
    final first = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    final item = ScanItemResult.observed(
      attemptId: scanUuidV5(first.scopeAttemptId, 'source\u0000comic-1'),
      scopeAttemptId: first.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic-1',
      producer: ScanProducer.comic,
      definitionRevision: 'rev-1',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'historical-chapter'),
      ),
    );
    await repository.saveItem(ScanIngestionContext(scope: first), item);
    await repository.finishScope(
      ScanIngestionContext(scope: first),
      ScanScopeStatus.completed,
    );
    await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-2',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ComicDebugPage(
          sourceKey: 'source',
          comicId: 'comic-1',
          scanRepository: repository,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('historical-chapter'), findsOneWidget);
    expect(find.text('Associated scope was replaced'.tl), findsOneWidget);
  });
}

class _EmptyCache extends NetworkFavoriteCacheManager {
  _EmptyCache() : super.forTesting();

  @override
  Set<String> getKnownFolderIds(String sourceKey, String comicId) => {};

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => const [];
}
