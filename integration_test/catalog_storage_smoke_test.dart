import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/models.dart';

const _revision = '0123456789012345678901234567890123456789';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('appdata atomic commits preserve bytes on replacement failure', (
    _,
  ) async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'venera-catalog-storage-smoke-',
    );
    final oldDataPath = App.isInitialized ? App.dataPath : null;
    final oldRuntime = appdata.catalogRuntime;
    final oldEnabled = appdata.settings['enabledSources'];
    App.dataPath = temporaryRoot.path;
    final pointer = CatalogPointer(
      catalogId: 'venera-app/venera-configs',
      revision: _revision,
      indexUrl:
          'https://raw.githubusercontent.com/venera-app/venera-configs/'
          '$_revision/index.json',
    );
    final state = AppCatalogState(active: pointer);
    try {
      appdata.catalogRuntime = null;
      appdata.settings['enabledSources'] = <String>['copy_manga'];
      final create = await appdata.prepareCatalogCommit(
        nextState: state,
        nextEnabled: <String>['copy_manga'],
        nextServerUrl: 'http://127.0.0.1:8080/',
      );
      await create.replace();
      create.installMemorySilently();
      create.release();

      final appdataFile = File(p.join(temporaryRoot.path, 'appdata.json'));
      final firstBytes = await appdataFile.readAsBytes();
      final firstDocument = jsonDecode(utf8.decode(firstBytes)) as Map;
      expect(firstDocument['catalogRuntime'], isNotNull);
      expect((firstDocument['settings'] as Map)['enabledSources'], [
        'copy_manga',
      ]);

      appdata.atomicReplace = (source, target) async {
        throw const FileSystemException('injected replacement failure');
      };
      final failed = await appdata.prepareCatalogCommit(
        nextState: AppCatalogState(active: pointer, lkg: pointer),
        nextEnabled: <String>[],
      );
      await expectLater(failed.replace(), throwsA(isA<FileSystemException>()));
      await failed.discard();
      expect(await appdataFile.readAsBytes(), firstBytes);
      expect(appdata.catalogRuntime, state.toJson());
      expect(appdata.settings['enabledSources'], ['copy_manga']);
    } finally {
      appdata.atomicReplace = null;
      appdata.catalogRuntime = oldRuntime;
      appdata.settings['enabledSources'] = oldEnabled;
      if (oldDataPath != null) App.dataPath = oldDataPath;
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    }
  });
}
