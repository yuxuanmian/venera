import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/js_source_adapter.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'three cached comics become latest-only SQLite rows and replay safely',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera-comic-');
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      addTearDown(() async {
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      final source = makeScanTestSource('picacg');
      final requestedIds = <String>[];
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (comicId, _) async {
          requestedIds.add(comicId);
          return {
            'observation': {
              'update': {'updatedAt': '2026-09-10T12:30:45.123Z'},
              'sourceUnread': comicId == 'comic-2',
            },
          };
        },
      );
      final snapshot = ScanTargetSnapshot(
        works: [
          for (final id in const ['comic-1', 'comic-2', 'comic-3'])
            ScanWorkSpec.comic(source: source, adapter: adapter, comicId: id),
        ],
        cacheGeneration: 4,
      );
      final planned = const FullScanPlanner().plan(snapshot);
      expect(planned.map((work) => work.comicId), [
        'comic-1',
        'comic-2',
        'comic-3',
      ]);

      final executor = ScanExecutor(repository: repository);
      final consumer = ScanEmissionConsumer(repository: repository);

      Future<void> runOnce() async {
        for (final spec in planned) {
          final outcome = await executor.execute(
            spec.toWork(
              ScanExecutionGuard(
                sourceKey: source.key,
                sourceInstance: source,
                cacheGeneration: snapshot.cacheGeneration,
              ),
            ),
            emit: (emission, context) => consumer.consume(emission, context),
          );
          expect(outcome.status, ScanWorkOutcomeStatus.completed);
          expect(outcome.persistedItems, 1);
        }
      }

      await runOnce();
      expect(requestedIds, ['comic-1', 'comic-2', 'comic-3']);
      expect(
        repository.database
            .select('SELECT COUNT(*) AS count FROM scan_item_state')
            .single['count'],
        3,
      );
      expect(
        (await repository.readLatestItem(
          'picacg',
          'comic-2',
        ))!.result.observation!.sourceUnread,
        isTrue,
      );

      await runOnce();
      expect(requestedIds, [
        'comic-1',
        'comic-2',
        'comic-3',
        'comic-1',
        'comic-2',
        'comic-3',
      ]);
      expect(
        repository.database
            .select('SELECT COUNT(*) AS count FROM scan_item_state')
            .single['count'],
        3,
      );
      expect(
        repository.database
            .select('SELECT COUNT(*) AS count FROM scan_scope_state')
            .single['count'],
        3,
      );
    },
  );

  test(
    'a real QuickJS comic source feeds the SQLite ingestion barrier',
    () async {
      if (!_quickJsAvailable) return;
      await JsEngine().init();
      ComicSource? source;
      final directory = await Directory.systemTemp.createTemp('venera-comic-');
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      try {
        source = await ComicSourceParser().parse(
          '''
class RealComicIngestionSource extends ComicSource {
  name = "Real comic ingestion";
  key = "real_comic_ingestion";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "comic",
    comic: {
      fieldSource: {latestChapterId: "comic.id"},
      load: async (id, request) => {
        const response = await request({
          method: "GET",
          url: "https://example.invalid/" + id,
        });
        return {observation: {update: {latestChapterId: response.body}}};
      },
    },
  };
}
''',
          'real_comic_ingestion.js',
          loadData: false,
          scheduleInit: false,
        );
        ComicSourceManager().add(source);
        final adapter = JsScanSourceAdapter(
          sourceKey: source.key,
          definitionRevision: source.version,
          capabilities: source.scan!,
          requestFactory: (lease) =>
              (request) async => const {
                'ok': true,
                'response': {
                  'status': 200,
                  'headers': <String, String>{},
                  'body': 'sqlite-bridge-chapter',
                },
              },
        );
        final guard = ScanExecutionGuard(
          sourceKey: source.key,
          sourceInstance: source,
          cacheGeneration: 0,
        );
        final spec = ScanWorkSpec.comic(
          source: source,
          adapter: adapter,
          comicId: 'comic-1',
        );
        final executor = ScanExecutor(repository: repository);
        final consumer = ScanEmissionConsumer(repository: repository);

        final outcome = await executor.execute(
          spec.toWork(guard),
          emit: (emission, context) => consumer.consume(emission, context),
        );

        expect(outcome.status, ScanWorkOutcomeStatus.completed);
        expect(outcome.persistedItems, 1);
        final stored = await repository.readLatestItem(source.key, 'comic-1');
        expect(
          stored!.result.observation!.update!.latestChapterId,
          'sqlite-bridge-chapter',
        );
      } finally {
        if (source != null) ComicSourceManager().remove(source.key);
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
        JsEngine().dispose();
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );
}

final bool _quickJsAvailable = _canLoadQuickJs();

bool _canLoadQuickJs() {
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}
