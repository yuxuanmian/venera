import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';

void main() {
  test(
    'a fixed collection identity space stays latest-only after replay',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-scan-bounds-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      addTearDown(() async {
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      await repository.ensureOpen();
      final first = await repository.beginScope(
        sourceKey: 'manwa',
        producer: ScanProducer.collection,
        scopeKey: 'default',
        definitionRevision: '1.0.7',
      );
      await _writeCollection(repository, first, revision: '1.0.7');
      await repository.finishScope(
        ScanIngestionContext(scope: first),
        ScanScopeStatus.completed,
      );

      expect(
        repository.database
            .select('SELECT COUNT(*) AS count FROM scan_item_state')
            .single['count'],
        700,
      );
      expect(
        (await repository.readLatestScope(
          'manwa',
          ScanProducer.collection,
          'default',
        ))!.itemCount,
        700,
      );

      final replay = await repository.beginScope(
        sourceKey: 'manwa',
        producer: ScanProducer.collection,
        scopeKey: 'default',
        definitionRevision: '1.0.7',
      );
      await _writeCollection(repository, replay, revision: '1.0.7');
      await repository.finishScope(
        ScanIngestionContext(scope: replay),
        ScanScopeStatus.completed,
      );

      expect(
        repository.database
            .select('SELECT COUNT(*) AS count FROM scan_item_state')
            .single['count'],
        700,
      );
      expect(
        (await repository.readLatestScope(
          'manwa',
          ScanProducer.collection,
          'default',
        ))!.itemCount,
        700,
      );
    },
  );
}

Future<void> _writeCollection(
  SqliteScanResultRepository repository,
  ScanScopeHandle scope, {
  required String revision,
}) async {
  final context = ScanIngestionContext(scope: scope);
  final observedAt = DateTime.utc(2026, 9, 10).toIso8601String();
  for (var index = 0; index < 700; index++) {
    final comicId = 'comic-$index';
    await repository.saveItem(
      context,
      ScanItemResult.observed(
        attemptId: scanUuidV5(scope.scopeAttemptId, comicId),
        scopeAttemptId: scope.scopeAttemptId,
        sourceKey: scope.sourceKey,
        comicId: comicId,
        producer: ScanProducer.collection,
        definitionRevision: revision,
        observedAt: observedAt,
        observation: ScanObservation(
          update: UpdateDescriptor(latestChapterId: 'chapter-$index'),
        ),
      ),
      committedAt: DateTime.utc(2026, 9, 10),
    );
  }
}
