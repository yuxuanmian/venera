import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

void main() {
  test('Io transport rejects redirects without following them', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var targetRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/target');
        await request.response.close();
      } else {
        targetRequests++;
        request.response.write('unexpected');
        await request.response.close();
      }
    });

    await expectLater(
      const IoCatalogTransport().getBytes(
        Uri.parse('http://127.0.0.1:${server.port}/redirect'),
        timeout: const Duration(seconds: 2),
        maxBytes: 1024,
      ),
      throwsA(
        isA<CatalogHttpException>().having(
          (error) => error.code,
          'code',
          'untrusted_redirect',
        ),
      ),
    );
    expect(targetRequests, 0);
  });

  test('Io transport enforces the response byte limit', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 8;
      request.response.add(List<int>.filled(8, 0x61));
      await request.response.close();
    });

    await expectLater(
      const IoCatalogTransport().getBytes(
        Uri.parse('http://127.0.0.1:${server.port}/large'),
        timeout: const Duration(seconds: 2),
        maxBytes: 4,
      ),
      throwsA(
        isA<CatalogHttpException>().having(
          (error) => error.code,
          'code',
          'response_too_large',
        ),
      ),
    );
  });
}
