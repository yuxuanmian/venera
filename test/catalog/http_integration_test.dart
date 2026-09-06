import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

void main() {
  final serverUrl = Platform.environment['VENERA_CATALOG_SERVER_URL'];
  final skipReason = serverUrl == null || serverUrl.trim().isEmpty
      ? 'set VENERA_CATALOG_SERVER_URL to run the live Go integration test'
      : null;

  test('real Go authority speaks the App Catalog protocol', () async {
    if (serverUrl == null || serverUrl.trim().isEmpty) {
      return;
    }

    final client = CatalogHttpClient(transport: const IoCatalogTransport());
    final pointer = await client.getAuthority(serverUrl);
    expect(pointer.catalogId, 'yuxuanmian/venera-configs');
    expect(pointer.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(pointer.indexUrl, contains('/${pointer.revision}/index.json'));

    final authority = await _get(
      Uri.parse(serverUrl).replace(
        path: '${_basePath(Uri.parse(serverUrl).path)}api/catalog/authority',
      ),
    );
    expect(authority.statusCode, 200);
    expect(authority.headers.value('cache-control'), 'no-store');
    final authorityJson = jsonDecode(authority.body) as Map;
    expect(authorityJson['activeRevision'], pointer.revision);
    expect(authorityJson.containsKey('revision'), isFalse);

    final health = await _get(
      Uri.parse(
        serverUrl,
      ).replace(path: '${_basePath(Uri.parse(serverUrl).path)}api/health'),
    );
    expect(health.statusCode, 200);
    expect((jsonDecode(health.body) as Map)['status'], 'ok');

    final retired = await _get(
      Uri.parse(serverUrl).replace(
        path: '${_basePath(Uri.parse(serverUrl).path)}api/tracking/status',
      ),
    );
    expect(retired.statusCode, 404);
  }, skip: skipReason);
}

Future<_BufferedResponse> _get(Uri uri) async {
  final httpClient = HttpClient();
  try {
    final request = await httpClient.getUrl(uri);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return _BufferedResponse(response.statusCode, response.headers, body);
  } finally {
    httpClient.close(force: true);
  }
}

String _basePath(String path) {
  if (path.isEmpty || path == '/') return '/';
  return '${path.replaceFirst(RegExp(r'/+$'), '')}/';
}

class _BufferedResponse {
  _BufferedResponse(this.statusCode, this.headers, this.body);

  final int statusCode;

  final HttpHeaders headers;

  final String body;
}
