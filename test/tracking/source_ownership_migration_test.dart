import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/catalog/legacy_migration.dart';

void main() {
  test('legacy inspection is static and cleanup preserves user data', () async {
    final root = await Directory.systemTemp.createTemp('venera-legacy-');
    addTearDown(() => root.delete(recursive: true));
    final source = File(p.join(root.path, 'source.js'))
      ..writeAsStringSync(
        'class Source extends ComicSource { key = "source"; }',
      );
    final data = File(p.join(root.path, 'source.data'))
      ..writeAsStringSync('user');
    final unknown = File(p.join(root.path, 'notes.txt'))
      ..writeAsStringSync('keep');

    final migration = LegacyMigration(root);
    final inventory = await migration.discover();
    expect(inventory.matched.keys, contains('source'));
    await migration.cleanupAfterSuccess(inventory);
    expect(await source.exists(), isFalse);
    expect(await data.readAsString(), 'user');
    expect(await unknown.readAsString(), 'keep');
  });
}
