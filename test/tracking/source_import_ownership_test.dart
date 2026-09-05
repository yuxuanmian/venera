import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_import_transaction.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart';

String _importFixtureSource(String key, {bool failExplore = false}) =>
    '''
class ImportFixture extends ComicSource {
  name = "Import Fixture";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  ${failExplore ? 'explore = [{}];' : ''}
  comic = {
    loadInfo(id) {
      return {
        title: "Imported",
        cover: "https://example.test/cover.jpg",
        description: "Imported source",
        tags: {},
      };
    },
  };
}
''';

Future<File> _zipSourceTree(Directory root, String name) async {
  final archive = File(p.join(root.parent.path, '$name.venera'));
  final zip = ZipFile.open(archive.path);
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    zip.addFile(
      'comic_source/${p.relative(file.path, from: root.path).replaceAll('\\', '/')}',
      file.path,
    );
  }
  zip.close();
  return archive;
}

Future<ActiveArtifact> _writeSourceRegistry(
  Directory sourceDirectory,
  String key,
  String fileName,
  String source,
) async {
  File(p.join(sourceDirectory.path, fileName)).writeAsStringSync(source);
  final artifact = ActiveArtifact(
    sourceKey: key,
    fileName: fileName,
    revision: null,
    relativePath: fileName,
    origin: ArtifactOrigin.custom,
    sha256: sha256.convert(utf8.encode(source)).toString(),
  );
  await SourceRevisionStore(
    sourceDirectory,
  ).save(ActiveArtifactRegistry(artifacts: [artifact]));
  return artifact;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory cache;
  var jsInitialized = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-source-import-');
    cache = Directory(p.join(root.path, 'cache'))..createSync(recursive: true);
    App.dataPath = root.path;
    App.cachePath = cache.path;
    App.disposeTracking();
    appdata.settings['cloudTrackingEnabled'] = false;
    appdata.settings['cloudTrackingServerUrl'] = '';
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: const ActiveArtifactRegistry(),
      sourceDirectoryPath: p.join(root.path, 'comic_source'),
    );
    jsInitialized = false;
  });

  tearDown(() async {
    SourceImportTransaction.debugBeforeCopy = null;
    App.disposeTracking();
    if (HistoryManager().isInitialized) HistoryManager().close();
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: const ActiveArtifactRegistry(),
      sourceDirectoryPath: null,
    );
    if (jsInitialized) {
      for (final key in const ['legacy', 'manwa', 'custom']) {
        ComicSourceManager().remove(key);
      }
      JsEngine().runCode('ComicSource.sources = {};');
    }
    appdata.settings['cloudTrackingEnabled'] = false;
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // Native SQLite/QuickJS handles can outlive a Windows test turn.
      }
    }
  });

  test(
    'Cloud-on import skips source scripts without replacing active files',
    () async {
      appdata.settings['cloudTrackingEnabled'] = true;
      sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
      final source = File(p.join(root.path, 'payload.js'))
        ..writeAsStringSync('class Imported extends ComicSource {}');
      final archive = File(p.join(root.path, 'payload.venera'));
      final zip = ZipFile.open(archive.path);
      zip.addFile('comic_source/imported.js', source.path);
      zip.close();

      final activeDirectory = Directory(p.join(App.dataPath, 'comic_source'))
        ..createSync(recursive: true);
      final active = File(p.join(activeDirectory.path, 'active.js'))
        ..writeAsStringSync('active');

      final result = await importAppData(archive);

      expect(result.sourceImported, isFalse);
      expect(result.sourceSkipped, isTrue);
      expect(await active.readAsString(), 'active');
      expect(
        await File(p.join(activeDirectory.path, 'imported.js')).exists(),
        isFalse,
      );
    },
  );

  for (final failAt in [1, 2]) {
    for (final failRestore in [false, true]) {
      test(
        'zip replacement failure $failAt preserves backup (restore fails: $failRestore)',
        () async {
          final sources = Directory(p.join(root.path, 'comic_source'))
            ..createSync();
          final original = File(p.join(sources.path, 'original.js'))
            ..writeAsStringSync('original bytes');
          final payload = File(p.join(root.path, 'payload.js'))
            ..writeAsStringSync('new bytes');
          final archive = File(p.join(root.path, 'failure.venera'));
          final zip = ZipFile.open(archive.path);
          zip.addFile('comic_source/a.js', payload.path);
          zip.addFile('comic_source/b.js', payload.path);
          zip.close();
          var copies = 0;
          SourceImportTransaction.debugBeforeCopy = (phase, file) async {
            if (phase == 'replace' && ++copies == failAt ||
                phase == 'restore' && failRestore) {
              throw FileSystemException('injected $phase failure');
            }
          };
          await expectLater(
            importAppData(archive),
            throwsA(isA<FileSystemException>()),
          );
          final transaction = SourceImportTransaction(sources);
          if (failRestore) {
            expect(
              File(
                p.join(transaction.backup.path, 'original.js'),
              ).readAsStringSync(),
              'original bytes',
            );
            expect(transaction.journal.existsSync(), isTrue);
            SourceImportTransaction.debugBeforeCopy = null;
            // A new transaction object represents recovery on the next startup.
            await SourceImportTransaction(sources).recover();
          }
          expect(original.readAsStringSync(), 'original bytes');
          expect(transaction.directory.existsSync(), isFalse);
          expect(sourceRuntimePolicy.admissionReady, isFalse);
        },
      );
    }
  }

  for (final modePhase in ['backup', 'replace']) {
    test('latest Cloud request wins during zip $modePhase copy', () async {
      final sources = Directory(p.join(root.path, 'comic_source'))
        ..createSync();
      final original = File(p.join(sources.path, 'original.js'))
        ..writeAsStringSync('original');
      final payload = File(p.join(root.path, 'payload.js'))
        ..writeAsStringSync('incoming');
      final archive = File(p.join(root.path, 'mode.venera'));
      final zip = ZipFile.open(archive.path);
      zip.addFile('comic_source/new.js', payload.path);
      zip.close();
      Future<void>? modeRequest;
      SourceImportTransaction.debugBeforeCopy = (phase, file) async {
        if (phase == modePhase && modeRequest == null) {
          modeRequest = App.cloudTracking.setCloudEnabled(true);
        }
      };
      await expectLater(importAppData(archive), throwsA(anything));
      await modeRequest;
      expect(App.cloudTracking.operationEpoch, 1);
      expect(appdata.settings['cloudTrackingEnabled'], isTrue);
      expect(sourceRuntimePolicy.cloudEnabled, isTrue);
      expect(original.readAsStringSync(), 'original');
      expect(File(p.join(sources.path, 'new.js')).existsSync(), isFalse);
    });
  }

  test('failed real reload restores the previous source tree', () async {
    final sources = Directory(p.join(root.path, 'comic_source'))..createSync();
    final original = File(p.join(sources.path, 'original.js'))
      ..writeAsStringSync('original');
    final incoming = Directory(p.join(root.path, 'incoming'))..createSync();
    final broken = File(p.join(incoming.path, 'broken.js'))
      ..writeAsStringSync('not valid JavaScript');
    final store = SourceRevisionStore(incoming);
    await store.save(
      ActiveArtifactRegistry(
        artifacts: [
          ActiveArtifact(
            sourceKey: 'broken',
            fileName: 'broken.js',
            revision: null,
            relativePath: 'broken.js',
            origin: ArtifactOrigin.custom,
            sha256: sha256.convert(broken.readAsBytesSync()).toString(),
          ),
        ],
      ),
    );
    final archive = File(p.join(root.path, 'reload.venera'));
    final zip = ZipFile.open(archive.path);
    for (final file in incoming.listSync(recursive: true).whereType<File>()) {
      zip.addFile(
        'comic_source/${p.relative(file.path, from: incoming.path).replaceAll('\\', '/')}',
        file.path,
      );
    }
    zip.close();
    await JsEngine().init();
    jsInitialized = true;
    await expectLater(importAppData(archive), throwsStateError);
    expect(original.readAsStringSync(), 'original');
    expect(SourceImportTransaction(sources).directory.existsSync(), isFalse);
    expect(sourceRuntimePolicy.admissionReady, isFalse);
  });

  for (final failure in const ['model', 'data']) {
    test(
      'real zip reload failure after context admission restores the old tree ($failure)',
      () async {
        final sources = Directory(p.join(root.path, 'comic_source'))
          ..createSync(recursive: true);
        const oldKey = 'import_old_source';
        final oldSource = _importFixtureSource(oldKey);
        final oldArtifact = await _writeSourceRegistry(
          sources,
          oldKey,
          '$oldKey.js',
          oldSource,
        );
        final recoveryBytes = utf8.encode(
          _importFixtureSource(oldKey).replaceFirst('Imported', 'Recovered'),
        );
        final recovery =
            File(p.join(sources.path, '.custom', 'old-recovery.js'))
              ..createSync(recursive: true)
              ..writeAsBytesSync(recoveryBytes);
        final originalRegistry = (await SourceRevisionStore(sources).load())!;
        await SourceRevisionStore(sources).save(
          originalRegistry.copyWith(
            recoverableArtifacts: [
              oldArtifact.copyWith(
                relativePath: '.custom/old-recovery.js',
                sha256: sha256.convert(recoveryBytes).toString(),
              ),
            ],
            migrationDiagnostics: const {
              'unresolved.js': 'Source identity could not be verified.',
            },
          ),
        );
        final beforeRegistryBytes = await SourceRevisionStore(
          sources,
        ).registryFile.readAsBytes();
        final beforeLkgBytes = await SourceRevisionStore(
          sources,
        ).lastKnownGoodFile.readAsBytes();
        final beforeOldBytes = await File(
          p.join(sources.path, '$oldKey.js'),
        ).readAsBytes();
        final beforeRecoveryBytes = await recovery.readAsBytes();

        final incoming = Directory(p.join(root.path, 'incoming-$failure'))
          ..createSync(recursive: true);
        final incomingKey = 'import_fail_$failure';
        final incomingSource = _importFixtureSource(
          incomingKey,
          failExplore: failure == 'model',
        );
        await _writeSourceRegistry(
          incoming,
          incomingKey,
          '$incomingKey.js',
          incomingSource,
        );
        if (failure == 'data') {
          File(
            p.join(incoming.path, '$incomingKey.data'),
          ).writeAsStringSync('{not-json');
        }
        final archive = await _zipSourceTree(incoming, 'mid-reload-$failure');

        await JsEngine().init();
        jsInitialized = true;
        sourceRuntimePolicy.prepare(
          cloudEnabled: false,
          registry: (await SourceRevisionStore(sources).load())!,
          sourceDirectoryPath: sources.path,
        );
        await ComicSourceManager().reload(requiredArtifact: oldArtifact);
        expect(ComicSource.find(oldKey), isNotNull);

        await expectLater(importAppData(archive), throwsA(anything));

        expect(
          await File(p.join(sources.path, '$oldKey.js')).readAsBytes(),
          beforeOldBytes,
        );
        expect(await recovery.readAsBytes(), beforeRecoveryBytes);
        expect(
          await SourceRevisionStore(sources).registryFile.readAsBytes(),
          beforeRegistryBytes,
        );
        expect(
          await SourceRevisionStore(sources).lastKnownGoodFile.readAsBytes(),
          beforeLkgBytes,
        );
        expect(ComicSource.find(incomingKey), isNull);
        expect(sourceRuntimePolicy.admissionReady, isFalse);
        expect(await SourceRevisionStore(sources).load(), isNotNull);
        await archive.delete();
      },
    );
  }

  test(
    'real zip reload failure keeps the only good backup when restore fails',
    () async {
      final sources = Directory(p.join(root.path, 'comic_source'))
        ..createSync(recursive: true);
      const oldKey = 'import_restore_source';
      final oldSource = _importFixtureSource(oldKey);
      final oldArtifact = await _writeSourceRegistry(
        sources,
        oldKey,
        '$oldKey.js',
        oldSource,
      );
      final recovery = File(p.join(sources.path, '.custom', 'restore.js'))
        ..createSync(recursive: true)
        ..writeAsStringSync('recovery bytes');
      final oldRegistry = (await SourceRevisionStore(sources).load())!;
      await SourceRevisionStore(sources).save(
        oldRegistry.copyWith(
          recoverableArtifacts: [
            oldArtifact.copyWith(
              relativePath: '.custom/restore.js',
              sha256: sha256.convert(await recovery.readAsBytes()).toString(),
            ),
          ],
        ),
      );
      final incoming = Directory(p.join(root.path, 'incoming-restore'))
        ..createSync(recursive: true);
      const incomingKey = 'import_restore_failure';
      final incomingSource = _importFixtureSource(
        incomingKey,
        failExplore: true,
      );
      await _writeSourceRegistry(
        incoming,
        incomingKey,
        '$incomingKey.js',
        incomingSource,
      );
      final archive = await _zipSourceTree(incoming, 'restore-failure');

      await JsEngine().init();
      jsInitialized = true;
      sourceRuntimePolicy.prepare(
        cloudEnabled: false,
        registry: (await SourceRevisionStore(sources).load())!,
        sourceDirectoryPath: sources.path,
      );
      await ComicSourceManager().reload(requiredArtifact: oldArtifact);
      var restoreAttempts = 0;
      SourceImportTransaction.debugBeforeCopy = (phase, file) async {
        if (phase == 'restore' && restoreAttempts++ == 0) {
          throw FileSystemException('injected restore failure');
        }
      };

      await expectLater(
        importAppData(archive),
        throwsA(isA<FileSystemException>()),
      );

      final transaction = SourceImportTransaction(sources);
      expect(transaction.journal.existsSync(), isTrue);
      expect(transaction.backup.existsSync(), isTrue);
      final journal = transaction.journal.readAsStringSync();
      expect(
        journal.contains('"phase":"replacing"') ||
            journal.contains('"phase":"replaced"'),
        isTrue,
      );
      SourceImportTransaction.debugBeforeCopy = null;
      await SourceImportTransaction(sources).recover();
      expect(
        File(p.join(sources.path, '$oldKey.js')).readAsStringSync(),
        oldSource,
      );
      expect(recovery.readAsStringSync(), 'recovery bytes');
      expect(transaction.directory.existsSync(), isFalse);
      await archive.delete();
    },
  );

  test('export and import preserve the new managed/custom source tree', () async {
    final revision = List.filled(40, 'a').join();
    final sourceRoot = Directory(p.join(App.dataPath, 'comic_source'))
      ..createSync(recursive: true);
    final legacy = File(p.join(sourceRoot.path, 'legacy.js'))
      ..writeAsStringSync(
        'class Legacy extends ComicSource { name = "Legacy"; key = "legacy"; version = "1.0.0"; minAppVersion = "1.0.0"; }',
      );
    final managed = File(p.join(sourceRoot.path, '.managed', revision, 'manwa.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'class Manwa extends ComicSource { name = "Manwa"; key = "manwa"; version = "1.0.0"; minAppVersion = "1.0.0"; }',
      );
    final currentCustom = File(p.join(sourceRoot.path, '.custom', 'current.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'class Custom extends ComicSource { name = "Custom"; key = "custom"; version = "1.0.0"; minAppVersion = "1.0.0"; }',
      );
    final recovery = File(p.join(sourceRoot.path, '.custom', 'recovery.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'class CustomRecovery extends ComicSource { name = "Custom"; key = "custom"; version = "1.0.0"; minAppVersion = "1.0.0"; }',
      );
    final store = SourceRevisionStore(sourceRoot);
    final managedBytes = await managed.readAsBytes();
    final customBytes = await currentCustom.readAsBytes();
    final recoveryBytes = await recovery.readAsBytes();
    final registry = ActiveArtifactRegistry(
      artifacts: [
        ActiveArtifact(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          revision: revision,
          relativePath: '.managed/$revision/manwa.js',
          origin: ArtifactOrigin.managedCatalog,
          sha256: sha256.convert(managedBytes).toString(),
        ),
        ActiveArtifact(
          sourceKey: 'custom',
          fileName: 'custom.js',
          revision: null,
          relativePath: '.custom/current.js',
          origin: ArtifactOrigin.custom,
          sha256: sha256.convert(customBytes).toString(),
        ),
      ],
      recoverableArtifacts: [
        ActiveArtifact(
          sourceKey: 'custom',
          fileName: 'custom.js',
          revision: null,
          relativePath: '.custom/recovery.js',
          origin: ArtifactOrigin.custom,
          sha256: sha256.convert(recoveryBytes).toString(),
        ),
      ],
    );
    await store.save(registry);
    await store.save(
      registry.copyWith(
        artifacts: [
          registry.artifacts.first.copyWith(activationBlocked: true),
          registry.artifacts.last,
        ],
      ),
    );
    await File(p.join(App.dataPath, 'history.db')).writeAsBytes(const []);
    await File(p.join(App.dataPath, 'cookie.db')).writeAsBytes(const []);
    await HistoryManager().init();
    await File(
      p.join(App.dataPath, 'appdata.json'),
    ).writeAsString(jsonEncode(appdata.toJson()));

    final archive = await exportAppData(false);
    sourceRoot.deleteSync(recursive: true);

    await JsEngine().init();
    jsInitialized = true;
    final result = await importAppData(archive);

    expect(result.sourceImported, isTrue);
    expect(await legacy.readAsString(), contains('key = "legacy"'));
    expect(await managed.readAsString(), contains('key = "manwa"'));
    expect(await currentCustom.readAsString(), contains('key = "custom"'));
    expect(await recovery.readAsString(), contains('key = "custom"'));
    final restored = await SourceRevisionStore(sourceRoot).load();
    expect(restored, isNotNull);
    expect(
      restored!.recoverableArtifacts.single.relativePath,
      '.custom/recovery.js',
    );
    expect(restored.artifacts.first.activationBlocked, isTrue);
    await archive.delete();
  });
}
