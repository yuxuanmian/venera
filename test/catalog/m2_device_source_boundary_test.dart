import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/models.dart';

void main() {
  late Directory root;
  late bool wasInitialized;
  String? oldDataPath;

  setUp(() async {
    wasInitialized = App.isInitialized;
    oldDataPath = wasInitialized ? App.dataPath : null;
    root = await Directory.systemTemp.createTemp('catalog-source-boundary-');
    App.dataPath = root.path;
  });

  tearDown(() async {
    if (wasInitialized) {
      App.dataPath = oldDataPath!;
    } else {
      App.isInitialized = false;
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('missing repository fields independently use M1 defaults', () {
    final target = Appdata.createForTesting(() async => root);

    expect(
      target.settings['catalogRepositoryUrl'],
      CatalogRepositorySource.defaultRepositoryUrl,
    );
    expect(
      target.settings['catalogRepositoryBranch'],
      CatalogRepositorySource.defaultBranch,
    );
  });

  test('atomic persistence failure leaves memory and disk unchanged', () async {
    final target = Appdata.createForTesting(() async => root);
    final oldSource = CatalogRepositorySource(branch: 'old');
    target.settings['catalogRepositoryUrl'] = oldSource.repositoryUrl;
    target.settings['catalogRepositoryBranch'] = oldSource.branch;
    final file = File('${root.path}/appdata.json');
    final original = jsonEncode(target.toJson());
    await file.writeAsString(original, flush: true);
    target.atomicReplace = (_, _) async {
      throw const FileSystemException('injected failure');
    };

    await expectLater(
      target.persistRepositorySource(CatalogRepositorySource(branch: 'next')),
      throwsA(isA<FileSystemException>()),
    );

    expect(target.settings['catalogRepositoryBranch'], 'old');
    expect(await file.readAsString(), original);
  });

  test(
    'export, sync projection, and import exclude device source fields',
    () async {
      final target = Appdata.createForTesting(() async => root);
      target.settings['catalogRepositoryUrl'] =
          'https://github.com/local/local-configs';
      target.settings['catalogRepositoryBranch'] = 'local-branch';
      target.settings['enabledSources'] = ['local_source'];

      final exported = target.toUserDataJson();
      final exportedSettings = exported['settings'] as Map;
      expect(exportedSettings, isNot(contains('catalogRepositoryUrl')));
      expect(exportedSettings, isNot(contains('catalogRepositoryBranch')));
      expect(exportedSettings['enabledSources'], ['local_source']);

      await target.saveData(false);
      final projectedFile =
          jsonDecode(await File('${root.path}/syncdata.json').readAsString())
              as Map;
      final projectedSettings = projectedFile['settings'] as Map;
      expect(projectedSettings, isNot(contains('catalogRepositoryUrl')));
      expect(projectedSettings, isNot(contains('catalogRepositoryBranch')));

      final commit = await target.prepareUserDataCommit({
        'settings': {
          'catalogRepositoryUrl': 'https://github.com/remote/remote-configs',
          'catalogRepositoryBranch': 'remote-branch',
          'enabledSources': ['remote_source'],
        },
      });
      final committedSettings = commit.document['settings'] as Map;
      expect(
        committedSettings['catalogRepositoryUrl'],
        'https://github.com/local/local-configs',
      );
      expect(committedSettings['catalogRepositoryBranch'], 'local-branch');
      expect(committedSettings['enabledSources'], ['remote_source']);
      await commit.discard();
    },
  );
}
