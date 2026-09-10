import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the ordinary user-data archive does not include scan result storage',
    () {
      final source = File('lib/utils/data.dart').readAsStringSync();
      expect(source, contains('zipFile.addFile("history.db"'));
      expect(source, contains('zipFile.addFile("appdata.json"'));
      expect(source, isNot(contains('scan_results.db')));
    },
  );
}
