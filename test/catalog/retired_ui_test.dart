import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retired source-management controls are absent from production UI', () {
    final sourcePage = File(
      'lib/pages/comic_source_page.dart',
    ).readAsStringSync();
    final appSettings = File('lib/pages/settings/app.dart').readAsStringSync();
    final debugSettings = File(
      'lib/pages/settings/debug.dart',
    ).readAsStringSync();
    for (final source in [sourcePage, appSettings, debugSettings]) {
      expect(source, isNot(contains('Reload Configs')));
      expect(source, isNot(contains('Repo URL')));
      expect(source, isNot(contains('cloudTracking')));
    }
  });
}
