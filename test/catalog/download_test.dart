import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

class _DownloadTransport implements CatalogTransport {
  _DownloadTransport(this.responses);
  final Map<String, CatalogBytesResponse> responses;
  var inFlight = 0;
  var maximumInFlight = 0;
  final requests = <Uri>[];

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    requests.add(uri);
    inFlight++;
    maximumInFlight = inFlight > maximumInFlight ? inFlight : maximumInFlight;
    try {
      final response = responses[uri.toString()];
      if (response == null && uri.path.endsWith('/catalog.json')) {
        return const CatalogBytesResponse(404, []);
      }
      if (response == null) throw StateError('missing fake response $uri');
      return response;
    } finally {
      inFlight--;
    }
  }
}

void main() {
  test(
    'pinned catalog gate uses prerelease order and ignores builds',
    () async {
      final previous = App.packageVersion;
      addTearDown(() => App.packageVersion = previous);
      final pointer = CatalogRepositorySource.defaults.pointerForRevision(
        'a' * 40,
      );
      final uri = Uri.parse(pointer.indexUrl).resolve('catalog.json');
      final transport = _DownloadTransport({
        uri.toString(): CatalogBytesResponse(
          200,
          utf8.encode('{"minAppVersion":"2.0.0-beta.8+172"}'),
        ),
      });
      final client = CatalogHttpClient(transport: transport);
      for (final (version, compatible) in [
        (null, false),
        ('2.0.0-beta.7+999', false),
        ('2.0.0-beta.8+1', true),
        ('2.0.0-beta.10', true),
        ('2.0.0', true),
      ]) {
        App.packageVersion = version;
        final attempt = CatalogAttempt(
          id: 'check',
          deadline: DateTime.now().add(const Duration(seconds: 3)),
        );
        final check = client.checkCompatibility(pointer, attempt: attempt);
        if (compatible) {
          expect(await check, '2.0.0-beta.8+172');
        } else {
          await expectLater(check, throwsA(isA<CatalogAppVersionException>()));
        }
        expect(transport.requests.last, uri);
        attempt.finish();
      }
    },
  );

  test('only a missing manifest permits legacy download', () async {
    final pointer = CatalogRepositorySource.defaults.pointerForRevision(
      'a' * 40,
    );
    final uri = Uri.parse(pointer.indexUrl).resolve('catalog.json');
    final root = await Directory.systemTemp.createTemp(
      'catalog-invalid-metadata-',
    );
    addTearDown(() => root.delete(recursive: true));
    for (final (status, body, errorCode) in [
      (200, '{', 'invalid_catalog_metadata'),
      (200, '{}', 'invalid_catalog_metadata'),
      (200, '{"minAppVersion":"2.0.0-beta.08"}', 'invalid_catalog_metadata'),
      (503, '', 'catalog_metadata_query_failed'),
    ]) {
      final transport = _DownloadTransport({
        uri.toString(): CatalogBytesResponse(status, utf8.encode(body)),
      });
      final attempt = CatalogAttempt(
        id: 'invalid',
        deadline: DateTime.now().add(const Duration(seconds: 3)),
      );
      await expectLater(
        CatalogHttpClient(transport: transport).downloadSnapshot(
          pointer,
          store: CatalogStore(root),
          attempt: attempt,
        ),
        throwsA(
          isA<CatalogHttpException>().having(
            (error) => error.code,
            'code',
            errorCode,
          ),
        ),
      );
      expect(transport.requests, [uri]);
      attempt.close();
    }
  });

  test(
    'downloads every index entry, including disabled candidates, at most four at once',
    () async {
      final pointer = CatalogPointer(
        catalogId: 'owner/repo',
        revision: 'a' * 40,
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
      );
      final index = List.generate(
        6,
        (i) => {
          'name': 'Source$i',
          'key': 'source_$i',
          'fileName': 'source_$i.js',
          'version': '1',
        },
      );
      final responses = <String, CatalogBytesResponse>{
        pointer.indexUrl: CatalogBytesResponse(
          200,
          utf8.encode(jsonEncode(index)),
        ),
      };
      for (var i = 0; i < 6; i++) {
        responses['https://raw.githubusercontent.com/owner/repo/${'a' * 40}/source_$i.js'] =
            CatalogBytesResponse(200, utf8.encode('source $i'));
      }
      final transport = _DownloadTransport(responses);
      final client = CatalogHttpClient(transport: transport);
      final root = await Directory.systemTemp.createTemp('catalog-download-');
      addTearDown(() => root.delete(recursive: true));
      final attempt = CatalogAttempt(
        id: 'download',
        deadline: DateTime.now().add(const Duration(seconds: 3)),
      );
      final candidate = await client.downloadSnapshot(
        pointer,
        store: CatalogStore(root),
        attempt: attempt,
      );
      expect(candidate.manifest.files, hasLength(6));
      expect(transport.maximumInFlight, lessThanOrEqualTo(4));
    },
  );
}
