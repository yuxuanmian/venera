import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/legacy_migration.dart';

void main() {
  test(
    'legacy discovery reads registry/root text without evaluating JS',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/copy_manga.js').writeAsString('''
      globalThis.sideEffect = true;
      class Copy extends ComicSource { key = "copy_manga"; }
    ''');
      await File(
        '${root.path}/unknown.js',
      ).writeAsString('globalThis.sideEffect = true;');
      final inventory = await LegacyMigration(root).discover();
      expect(inventory.matched.keys, contains('copy_manga'));
      expect(inventory.unknownFiles.single.path, endsWith('unknown.js'));
    },
  );

  test(
    'a valid registry LKG supplies identity when the active registry is bad',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-lkg-');
      addTearDown(() => root.delete(recursive: true));
      await File(
        '${root.path}/example.js',
      ).writeAsString('globalThis.sideEffect = true;');
      await Directory('${root.path}/.managed').create(recursive: true);
      await File(
        '${root.path}/.managed/active-artifacts.json',
      ).writeAsString('{"schemaVersion":1,"artifacts":"bad"}');
      await File(
        '${root.path}/.managed/active-artifacts.json.lkg',
      ).writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'artifacts': [
            {'sourceKey': 'example', 'fileName': 'example.js'},
          ],
          'recoverableArtifacts': [
            {'sourceKey': 'ignored', 'fileName': 'ignored.js'},
          ],
        }),
      );

      final inventory = await LegacyMigration(root).discover();
      expect(inventory.matched.keys, contains('example'));
      expect(inventory.matched.keys, isNot(contains('ignored')));
    },
  );
}
