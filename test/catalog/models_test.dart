import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture =
        jsonDecode(
              File('test/fixtures/catalog-contract.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
  });

  test('round trips the pinned pointer wire format', () {
    final pointer = CatalogPointer.fromJson({
      'catalogId': 'owner/repo',
      'revision': 'a' * 40,
      'indexUrl':
          'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
    });
    expect(pointer.revision, 'a' * 40);
    expect(pointer.toJson()['revision'], 'a' * 40);
  });

  test('rejects pointer identity and URL mismatch', () {
    expect(
      () => CatalogPointer.fromJson({
        'catalogId': 'owner/repo',
        'revision': 'a' * 40,
        'indexUrl':
            'https://raw.githubusercontent.com/other/repo/${'a' * 40}/index.json',
      }),
      throwsA(isA<CatalogFormatException>()),
    );
  });

  test('preserves source key case and accepts an empty index', () {
    final value = fixture['indexCases'].firstWhere(
      (item) => item['id'] == 'index-two-entries',
    )['value'];
    final index = CatalogIndex.fromJson(value);
    expect(index.entries.map((entry) => entry.key), [
      'example_source',
      'Komiic',
    ]);
    expect(CatalogIndex.fromJson([]).entries, isEmpty);
  });

  test(
    'rejects duplicate keys, case-insensitive filenames, and unsafe paths',
    () {
      for (final id in [
        'duplicate-key',
        'duplicate-filename-case-insensitive',
        'traversal-file',
        'wrong-description-type',
      ]) {
        final value = fixture['indexCases'].firstWhere(
          (item) => item['id'] == id,
        )['value'];
        expect(
          () => CatalogIndex.fromJson(value),
          throwsA(isA<CatalogFormatException>()),
          reason: id,
        );
      }
    },
  );

  test('round trips app state and snapshot manifest', () {
    final pointer = CatalogPointer(
      catalogId: 'yuxuanmian/venera-configs',
      revision: 'a' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/yuxuanmian/venera-configs/${'a' * 40}/index.json',
    );
    final state = AppCatalogState(active: pointer);
    expect(AppCatalogState.fromJson(state.toJson()).active, pointer);
    final manifest = CatalogSnapshotManifest(
      pointer: pointer,
      indexSha256: '0' * 64,
      files: [
        CatalogSnapshotFile(
          sourceKey: 'example_source',
          fileName: 'example_source.js',
          size: 1,
          sha256: '1' * 64,
        ),
      ],
    );
    expect(
      CatalogSnapshotManifest.fromJson(manifest.toJson()).files.single.fileName,
      'example_source.js',
    );
  });
}
