import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/legacy_migration.dart';

void main() {
  test(
    'cleanup removes only known execution files and preserves user data',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-clean-');
      addTearDown(() => root.delete(recursive: true));
      final js = File('${root.path}/old.js');
      await js.writeAsString('old');
      final data = File('${root.path}/old.data');
      await data.writeAsString('user');
      final managed = Directory('${root.path}/.managed');
      await managed.create();
      await File('${managed.path}/active-artifacts.json').writeAsString('{}');
      await File('${managed.path}/user-notes.txt').writeAsString('keep');
      final inventory = LegacyInventory(
        matched: {'old': js},
        knownExecutableFiles: [js],
        unknownFiles: const [],
        summary: const [],
      );
      await LegacyMigration(root).cleanupAfterSuccess(inventory);
      expect(await js.exists(), isFalse);
      expect(await data.readAsString(), 'user');
      expect(
        await File('${managed.path}/user-notes.txt').readAsString(),
        'keep',
      );
    },
  );
}
