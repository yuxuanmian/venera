import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-appdata-recovery-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<Appdata> createAppdata(Map<String, dynamic> document) async {
    final file = File('${root.path}${Platform.pathSeparator}appdata.json');
    await file.writeAsString(jsonEncode(document));
    return Appdata.createForTesting(() async => root);
  }

  test(
    'sparse fields keep defaults and explicit empty source selection',
    () async {
      final data = await createAppdata({
        'settings': {'deviceId': 'device', 'enabledSources': []},
        'searchHistory': null,
      });

      await data.init();

      expect(data.loadError, isNull);
      expect(data.settings['enabledSources'], isEmpty);
      expect(data.settings['comicDisplayMode'], 'detailed');
      expect(data.searchHistory, isEmpty);
    },
  );

  test('malformed JSON is retained for recovery instead of deleted', () async {
    final file = File('${root.path}${Platform.pathSeparator}appdata.json');
    const original = '{not-json';
    await file.writeAsString(original);
    final data = Appdata.createForTesting(() async => root);

    await data.init();

    expect(data.loadError, isNotNull);
    expect(await file.readAsString(), original);
  });

  test(
    'bad Catalog runtime remains recoverable without losing user settings',
    () async {
      final data = await createAppdata({
        'settings': {'deviceId': 'device', 'enabledSources': []},
        'catalogRuntime': 'not-an-object',
      });

      await data.init();

      expect(data.loadError, isNull);
      expect(data.settings['enabledSources'], isEmpty);
      expect(data.settings['comicDisplayMode'], 'detailed');
      expect(() => data.readCatalogState(), throwsA(isA<Exception>()));
    },
  );

  test(
    'a sync projection failure does not roll back the primary document',
    () async {
      final data = await createAppdata({
        'settings': {'deviceId': 'device', 'enabledSources': []},
      });
      String? previousDataPath;
      var hadDataPath = false;
      try {
        previousDataPath = App.dataPath;
        hadDataPath = true;
      } catch (_) {}
      App.dataPath = root.path;
      addTearDown(() {
        if (hadDataPath) App.dataPath = previousDataPath!;
      });
      await data.init();
      await Directory(
        '${root.path}${Platform.pathSeparator}syncdata.json',
      ).create();

      await data.persistEnabledSources(['demo']);

      expect(data.settings['enabledSources'], ['demo']);
      final persisted =
          jsonDecode(
                await File(
                  '${root.path}${Platform.pathSeparator}appdata.json',
                ).readAsString(),
              )
              as Map;
      expect(persisted['settings']['enabledSources'], ['demo']);
    },
  );
}
