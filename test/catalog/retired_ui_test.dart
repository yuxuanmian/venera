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
    final repositorySettings = File(
      'lib/pages/settings/repository.dart',
    ).readAsStringSync();
    final diagnostics = File(
      'lib/pages/settings/catalog_diagnostics.dart',
    ).readAsStringSync();
    final comicDebug = File(
      'lib/pages/comic_details_page/debug.dart',
    ).readAsStringSync();
    final mainPage = File('lib/pages/main_page.dart').readAsStringSync();
    for (final source in [
      sourcePage,
      appSettings,
      debugSettings,
      repositorySettings,
      diagnostics,
      comicDebug,
    ]) {
      expect(source, isNot(contains('Reload Configs')));
      expect(source, isNot(contains('Repo URL')));
      expect(source, isNot(contains('cloudTracking')));
      expect(source, isNot(contains('Venera Server')));
      expect(source, isNot(contains("settings['serverUrl']")));
      expect(source, isNot(contains('getAuthority')));
    }
    expect(mainPage, contains('SettingsPage(controller: catalogController)'));
    expect(mainPage, isNot(contains('CatalogController.current')));
    expect(appSettings, contains('配置仓库'));

    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      expect(source, isNot(contains('getAuthority')), reason: file.path);
      expect(source, isNot(contains('CatalogServerUrl')), reason: file.path);
      expect(source, isNot(contains('ServerSettings')), reason: file.path);
      expect(source, isNot(contains('Venera Server')), reason: file.path);
    }
  });
}
