import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/legacy_migration.dart';

void main() {
  test(
    'multi-account data is copied only to the exact multi variant',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-copy-');
      addTearDown(() => root.delete(recursive: true));
      await File(
        '${root.path}/copy_manga.js',
      ).writeAsString('class Main extends ComicSource { key = "copy_manga"; }');
      await File('${root.path}/copy_manga_multi_accounts.js').writeAsString(
        'class Multi extends ComicSource { key = "copy_manga_multi"; }',
      );
      await File('${root.path}/copy_manga.data').writeAsString('{"account":1}');
      final migration = LegacyMigration(root);
      final inventory = await migration.discover();
      final effect = await migration.prepareCopyEffect(inventory: inventory);
      expect(effect, isNotNull);
      expect(await migration.applyCopyEffect(effect!), isTrue);
      expect(
        await File('${root.path}/copy_manga_multi.data').readAsString(),
        '{"account":1}',
      );
      expect(await File('${root.path}/copy_manga.data').exists(), isTrue);
    },
  );

  test('malformed shared data is not promoted to the multi variant', () async {
    final root = await Directory.systemTemp.createTemp('legacy-copy-invalid-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/copy_manga_multi_accounts.js').writeAsString(
      'class Multi extends ComicSource { key = "copy_manga_multi"; }',
    );
    await File('${root.path}/copy_manga.data').writeAsString('{broken');

    final migration = LegacyMigration(root);
    final inventory = await migration.discover();

    expect(await migration.prepareCopyEffect(inventory: inventory), isNull);
    expect(await File('${root.path}/copy_manga_multi.data').exists(), isFalse);
  });
}
