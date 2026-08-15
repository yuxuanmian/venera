import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cache.dart';

Map<String, List<String>> _headers(Map<String, String> values) => values
    .map((key, value) => MapEntry(key, <String>[value]));

void main() {
  group('NetworkCacheManager.isHeadProbeValid', () {
    test('accepts a matching fingerprint with agreeing headers', () {
      final cached = _headers({
        'etag': '"abc123"',
        'content-type': 'text/html; charset=UTF-8',
        'server': 'cloudflare',
        'date': 'old-date',
        'x-varnish': '1',
      });
      final head = _headers({
        'etag': '"abc123"',
        'content-type': 'text/html; charset=UTF-8',
        'server': 'cloudflare',
        'date': 'new-date',
        'x-varnish': '2',
      });
      expect(NetworkCacheManager.isHeadProbeValid(cached, head), isTrue);
    });

    test('rejects a dynamic page without any fingerprint header', () {
      // Favorites/search pages carry no ETag / Last-Modified / Content-Length:
      // a 200 HEAD with identical remaining headers must NOT validate the
      // cached copy, otherwise content changes are never observed.
      final cached = _headers({
        'content-type': 'text/html; charset=UTF-8',
        'server': 'cloudflare',
        'cache-control': 'no-cache',
        'date': 'old-date',
        'x-varnish': '1',
      });
      final head = _headers({
        'content-type': 'text/html; charset=UTF-8',
        'server': 'cloudflare',
        'cache-control': 'no-cache',
        'date': 'new-date',
        'x-varnish': '2',
      });
      expect(NetworkCacheManager.isHeadProbeValid(cached, head), isFalse);
    });

    test('rejects a changed fingerprint', () {
      final cached = _headers({
        'etag': '"old"',
        'content-type': 'text/html',
      });
      final head = _headers({
        'etag': '"new"',
        'content-type': 'text/html',
      });
      expect(NetworkCacheManager.isHeadProbeValid(cached, head), isFalse);
    });

    test('rejects an agreeing fingerprint with changed content type', () {
      final cached = _headers({
        'etag': '"same"',
        'content-type': 'text/html',
      });
      final head = _headers({
        'etag': '"same"',
        'content-type': 'application/json',
      });
      expect(NetworkCacheManager.isHeadProbeValid(cached, head), isFalse);
    });

    test('treats an empty fingerprint header as absent', () {
      final cached = _headers({
        'etag': '"same"',
        'content-type': 'text/html',
      });
      final head = _headers({
        'etag': '',
        'content-type': 'text/html',
      });
      expect(NetworkCacheManager.isHeadProbeValid(cached, head), isFalse);
    });
  });
}
