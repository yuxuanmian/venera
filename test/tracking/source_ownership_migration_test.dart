import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/tracking/legacy_source_identity.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

const _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _SaveProbeStore extends SourceRevisionStore {
  _SaveProbeStore(super.directory, {this.fail = false, this.afterSave});

  bool fail;
  final void Function()? afterSave;

  @override
  Future<void> save(
    ActiveArtifactRegistry registry, {
    bool preserveLastKnownGood = false,
  }) async {
    if (fail) throw FileSystemException('injected registry save failure');
    await super.save(registry, preserveLastKnownGood: preserveLastKnownGood);
    afterSave?.call();
  }
}

void main() {
  test(
    'migration diagnostics survive restart, clear on repair or deletion, and redact errors',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-diagnostics-');
      addTearDown(() => root.delete(recursive: true));
      final file = File(p.join(root.path, 'unknown.js'));
      await file.writeAsString(
        'class Unknown extends ComicSource { key = dynamicKey; }',
      );
      await SourceRevisionStore(root).loadOrMigrate(cloudEnabled: true);
      final restarted = SourceRevisionStore(root);
      expect((await restarted.load())!.migrationDiagnostics.keys, [
        'unknown.js',
      ]);
      await restarted.loadOrMigrate(
        resolveSourceKey: (_) => throw StateError('token=private/path'),
      );
      final diagnostic =
          (await restarted.load())!.migrationDiagnostics['unknown.js']!;
      expect(diagnostic, isNot(contains('private')));
      expect(diagnostic, 'Source identity could not be verified.');
      await file.writeAsString(
        'class Unknown extends ComicSource { key = "known"; }',
      );
      final repaired = await SourceRevisionStore(
        root,
      ).loadOrMigrate(cloudEnabled: true);
      expect(repaired.migrationDiagnostics, isEmpty);
      expect(repaired.find('known', 'unknown.js'), isNotNull);
      final removed = File(p.join(root.path, 'removed.js'));
      await removed.writeAsString('not a class');
      await restarted.loadOrMigrate(cloudEnabled: true);
      await removed.delete();
      expect(
        (await restarted.loadOrMigrate(
          cloudEnabled: true,
        )).migrationDiagnostics,
        isEmpty,
      );
    },
  );

  test(
    'nested templates and encoded dynamic keys cannot register a guessed identity',
    () {
      for (final source in [
        r'class A extends ComicSource { name = `${`nested ${1}`}`; key = "a"; }',
        r'class A extends ComicSource { key = "\u0061"; }',
        'class A extends ComicSource { key = "a"; } class B extends ComicSource { key = "b"; }',
      ]) {
        expect(
          () => LegacySourceIdentity.fromSource(source),
          throwsFormatException,
        );
      }
    },
  );

  test('literal delimiters do not change class depth', () {
    for (final delimiter in ['{', '}', '(', ')', '[', ']']) {
      expect(
        LegacySourceIdentity.fromSource('''
class Example extends ComicSource {
  name = "$delimiter";
  key = "example"
  version = "1.0.0";
}
''').sourceKey,
        'example',
      );
    }
  });

  test('newline does not terminate a continued key initializer', () {
    for (final continuation in [
      '+ "wa"',
      '[0]',
      '(1)',
      '.trim()',
      '? "a" : "b"',
      'in object',
      'instanceof String',
      ', other = "b"',
    ]) {
      expect(
        () => LegacySourceIdentity.fromSource('''
class Example extends ComicSource {
  key = "man"
    $continuation;
}
'''),
        throwsFormatException,
        reason: continuation,
      );
    }
  });

  test(
    'version-1 registry keeps defaults and round-trips ownership fields',
    () {
      final old = ActiveArtifactRegistry.fromJson({
        'schemaVersion': 1,
        'artifacts': [
          {
            'sourceKey': 'legacy',
            'fileName': 'legacy.js',
            'revision': null,
            'relativePath': 'legacy.js',
            'origin': 'custom',
            'sha256': _hashA,
          },
        ],
      });
      expect(old.recoverableArtifacts, isEmpty);
      expect(old.artifacts.single.activationBlocked, isFalse);

      final recovery = old.artifacts.single;
      final next = old.copyWith(
        artifacts: [recovery.copyWith(activationBlocked: true)],
        recoverableArtifacts: [recovery],
      );
      expect(ActiveArtifactRegistry.fromJson(next.toJson()), next);
    },
  );

  test(
    'registry rejects typed errors, duplicate records, and unsafe paths',
    () {
      Map<String, dynamic> artifact({
        String path = 'source.js',
        String hash = _hashA,
      }) => {
        'sourceKey': 'source',
        'fileName': 'source.js',
        'revision': null,
        'relativePath': path,
        'origin': 'custom',
        'sha256': hash,
      };

      expect(
        () => ActiveArtifactRegistry.fromJson({
          'schemaVersion': 1,
          'artifacts': [artifact(), artifact()],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ActiveArtifactRegistry.fromJson({
          'schemaVersion': 1,
          'artifacts': [artifact(path: '../escape.js')],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ActiveArtifactRegistry.fromJson({
          'schemaVersion': 1,
          'artifacts': [artifact()],
          'recoverableArtifacts': 'wrong-type',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ActiveArtifactRegistry.fromJson({
          'schemaVersion': 1,
          'artifacts': [
            {...artifact(), 'activationBlocked': 'true'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'Cloud-on legacy migration proves identity without executing JavaScript',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-ownership-');
      addTearDown(() => root.delete(recursive: true));
      final plain = File('${root.path}${Platform.pathSeparator}plain.js');
      final dynamic = File('${root.path}${Platform.pathSeparator}dynamic.js');
      await plain.writeAsString('''
// key = "fake-comment";
class Plain extends ComicSource {
  key = "exact_plain";
  settings = { key: "nested-not-identity" };
}
''');
      await dynamic.writeAsString('''
globalThis.__shouldNotRun = true;
class Dynamic extends ComicSource {
  key = getKey();
}
''');

      final store = SourceRevisionStore(root);
      final registry = await store.loadOrMigrate(cloudEnabled: true);
      expect(registry.find('exact_plain', 'plain.js'), isNotNull);
      expect(registry.find('dynamic', 'dynamic.js'), isNull);
      expect(store.migrationDiagnostics, hasLength(1));
      expect(await dynamic.exists(), isTrue);
    },
  );

  test(
    'lexer ignores comments and nested fields and rejects ambiguous keys',
    () {
      final identity = LegacySourceIdentity.fromSource('''
// class Fake extends ComicSource { key = "fake"; }
class Real extends ComicSource {
  key = "real_key";
  config = { key: "nested" };
}
''');
      expect(identity.sourceKey, 'real_key');
      expect(
        () => LegacySourceIdentity.fromSource('''
class Real extends ComicSource { key = otherKey; }
'''),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => LegacySourceIdentity.fromSource('''
class Real extends ComicSource { key = "a"; key = "b"; }
'''),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('real maintained Manwa structure is identity-discoverable', () async {
    final maintained = File(
      p.join(Directory.current.path, '..', 'venera-configs', 'manwa.js'),
    );
    expect(await maintained.exists(), isTrue);
    final identity = LegacySourceIdentity.fromBytes(
      await maintained.readAsBytes(),
    );
    expect(identity.sourceKey, 'manwa');
  });

  test(
    'unresolved legacy files are retried after a later parser fix',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera-ownership-retry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File(p.join(root.path, 'retry.js'));
      await source.writeAsString('''
class Retry extends ComicSource {
  key = getKey();
}
''');
      final store = SourceRevisionStore(root);
      final first = await store.loadOrMigrate(cloudEnabled: true);
      expect(first.artifacts, isEmpty);
      expect(store.migrationDiagnostics, hasLength(1));

      await source.writeAsString('''
class Retry extends ComicSource {
  key = "retry";
  request = `https://example.test/\${this.key}`;
  matcher = /retry\\/chapter/;
}
''');
      final second = await store.loadOrMigrate(cloudEnabled: true);
      expect(second.find('retry', 'retry.js'), isNotNull);
      expect(await source.readAsString(), isNot(contains('getKey')));
    },
  );

  test(
    'takeover keeps exact custom bytes and deduplicates recovery versions',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-takeover-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}custom.js');
      final bytes = utf8.encode(
        'class Custom extends ComicSource { key = "custom"; }',
      );
      await source.writeAsBytes(bytes);
      final hash = sha256.convert(bytes).toString();
      final store = SourceRevisionStore(root);
      await store.save(
        ActiveArtifactRegistry(
          artifacts: [
            ActiveArtifact(
              sourceKey: 'custom',
              fileName: 'custom.js',
              revision: null,
              relativePath: 'custom.js',
              origin: ArtifactOrigin.custom,
              sha256: hash,
            ),
          ],
        ),
      );
      final first = await store.prepareForCloudTakeover(
        const TrustedArtifact(sourceKey: 'custom', fileName: 'custom.js'),
      );
      final second = await store.prepareForCloudTakeover(
        const TrustedArtifact(sourceKey: 'custom', fileName: 'custom.js'),
      );
      expect(first.artifacts.single.activationBlocked, isTrue);
      expect(second.recoverableArtifacts, hasLength(1));
      expect(await source.readAsBytes(), bytes);
    },
  );

  test(
    'hash failure blocks the selected custom artifact without accepting new bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera-takeover-fail-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}custom.js');
      final bytes = utf8.encode('changed');
      await source.writeAsBytes(bytes);
      final store = SourceRevisionStore(root);
      await store.save(
        ActiveArtifactRegistry(
          artifacts: [
            ActiveArtifact(
              sourceKey: 'custom',
              fileName: 'custom.js',
              revision: null,
              relativePath: 'custom.js',
              origin: ArtifactOrigin.custom,
              sha256: _hashA,
            ),
          ],
        ),
      );
      await expectLater(
        store.prepareForCloudTakeover(
          const TrustedArtifact(sourceKey: 'custom', fileName: 'custom.js'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect((await store.load())!.artifacts.single.activationBlocked, isTrue);
      expect(await source.readAsBytes(), bytes);
      expect((await store.load())!.recoverableArtifacts, isEmpty);
    },
  );

  test(
    'verified legacy root registration is exact, blocked, and crash durable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera-legacy-registration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File(p.join(root.path, 'legacy.js'));
      final bytes = utf8.encode(
        'class Legacy extends ComicSource { key = "legacy"; }',
      );
      await file.writeAsBytes(bytes);
      final store = SourceRevisionStore(root);
      var current = true;
      void requireCurrent() {
        if (!current) throw StateError('stale registration');
      }

      final registered = await store.registerVerifiedLegacyRoot(
        fileName: 'legacy.js',
        sourceKey: 'legacy',
        expectedBytes: bytes,
        requireCurrent: requireCurrent,
      );
      final active = registered.find('legacy', 'legacy.js');
      expect(active?.activationBlocked, isTrue);
      expect(active?.sha256, sha256.convert(bytes).toString());
      expect(registered.recoverableArtifacts, hasLength(1));
      expect(await file.readAsBytes(), bytes);
      expect((await store.load())!.migrationDiagnostics, isEmpty);

      await expectLater(
        store.registerVerifiedLegacyRoot(
          fileName: 'legacy.js',
          sourceKey: 'legacy',
          expectedBytes: bytes,
          requireCurrent: requireCurrent,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await file.readAsBytes(), bytes);
      expect((await store.load())!.artifacts, hasLength(1));

      final other = File(p.join(root.path, 'legacy_variant.js'));
      await other.writeAsBytes(bytes);
      final variant = await store.registerVerifiedLegacyRoot(
        fileName: 'legacy_variant.js',
        sourceKey: 'legacy',
        expectedBytes: bytes,
        requireCurrent: requireCurrent,
      );
      expect(variant.artifacts, hasLength(2));
      expect(
        variant.recoverableArtifacts
            .where((item) => item.sourceKey == 'legacy')
            .length,
        2,
      );

      final changed = File(p.join(root.path, 'changed.js'));
      final original = utf8.encode('original');
      final replacement = utf8.encode('replacement');
      await changed.writeAsBytes(replacement);
      await expectLater(
        store.registerVerifiedLegacyRoot(
          fileName: 'changed.js',
          sourceKey: 'changed',
          expectedBytes: original,
          requireCurrent: requireCurrent,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await changed.readAsBytes(), replacement);
      expect((await store.load())!.find('changed', 'changed.js'), isNull);

      final failingRoot = await Directory.systemTemp.createTemp(
        'venera-legacy-registration-save-',
      );
      addTearDown(() => failingRoot.delete(recursive: true));
      final failingFile = File(p.join(failingRoot.path, 'failing.js'))
        ..writeAsBytesSync(bytes);
      final failingStore = _SaveProbeStore(failingRoot, fail: true);
      await expectLater(
        failingStore.registerVerifiedLegacyRoot(
          fileName: failingFile.uri.pathSegments.last,
          sourceKey: 'failing',
          expectedBytes: bytes,
          requireCurrent: requireCurrent,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await failingFile.readAsBytes(), bytes);
      expect(await failingStore.load(), isNull);

      final invalidatingRoot = await Directory.systemTemp.createTemp(
        'venera-legacy-registration-stale-',
      );
      addTearDown(() => invalidatingRoot.delete(recursive: true));
      final invalidatingFile = File(p.join(invalidatingRoot.path, 'stale.js'))
        ..writeAsBytesSync(bytes);
      final invalidatingStore = _SaveProbeStore(
        invalidatingRoot,
        afterSave: () => current = false,
      );
      await expectLater(
        invalidatingStore.registerVerifiedLegacyRoot(
          fileName: 'stale.js',
          sourceKey: 'stale',
          expectedBytes: bytes,
          requireCurrent: requireCurrent,
        ),
        throwsStateError,
      );
      final durable = await invalidatingStore.load();
      expect(durable?.find('stale', 'stale.js')?.activationBlocked, isTrue);
      expect(await invalidatingFile.readAsBytes(), bytes);
    },
  );
}
