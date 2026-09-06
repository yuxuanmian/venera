import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

class _DownloadTransport implements CatalogTransport {
  _DownloadTransport(this.responses);
  final Map<String, CatalogBytesResponse> responses;
  var inFlight = 0;
  var maximumInFlight = 0;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    inFlight++;
    maximumInFlight = inFlight > maximumInFlight ? inFlight : maximumInFlight;
    try {
      final response = responses[uri.toString()];
      if (response == null) throw StateError('missing fake response $uri');
      return response;
    } finally {
      inFlight--;
    }
  }
}

void main() {
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
