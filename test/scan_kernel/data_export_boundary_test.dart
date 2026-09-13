import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the ordinary user-data archive does not include scan result storage',
    () {
      final source = File('lib/utils/data.dart').readAsStringSync();
      // The archive's declared contents: the two SQLite databases — carried as
      // consistent snapshots rather than read as live files — and appdata.json.
      expect(source, contains("const ['history.db', 'cookie.db']"));
      expect(source, contains('writeSqliteBackupSnapshot('));
      expect(source, contains('zipFile.addFile(name, snapshotPath)'));
      expect(source, contains('zipFile.addFile("appdata.json"'));
      expect(source, isNot(contains('scan_results.db')));
    },
  );
}
