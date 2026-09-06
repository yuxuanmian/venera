import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

class FakeTransport implements CatalogTransport {
  FakeTransport(this.response);
  final CatalogBytesResponse response;
  Uri? requested;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    requested = uri;
    return response;
  }
}

void main() {
  test('normalizes a server base URL and decodes authority', () async {
    final transport = FakeTransport(
      CatalogBytesResponse(
        200,
        utf8.encode(
          jsonEncode({
            'catalogId': 'owner/repo',
            'activeRevision': 'a' * 40,
            'indexUrl':
                'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
          }),
        ),
      ),
    );
    final client = CatalogHttpClient(transport: transport);
    final pointer = await client.getAuthority(' https://server.example/base ');
    expect(pointer.catalogId, 'owner/repo');
    expect(
      transport.requested.toString(),
      'https://server.example/base/api/catalog/authority',
    );
  });

  test('rejects raw/index/API paths and credentials', () {
    for (final value in [
      'https://u:p@server.example',
      'https://server.example/api/catalog/authority',
      'https://raw.githubusercontent.com/owner/repo/a/index.json',
    ]) {
      expect(
        () => CatalogServerUrl.parse(value),
        throwsA(isA<CatalogHttpException>()),
      );
    }
  });
}
