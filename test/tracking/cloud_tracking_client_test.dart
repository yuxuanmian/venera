import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';

class _FakeTransport implements TrackingHttpTransport {
  final List<TrackingHttpResponse> responses;
  final requests =
      <
        ({
          String method,
          String path,
          Map<String, String> headers,
          String? body,
        })
      >[];

  _FakeTransport(this.responses);

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add((
      method: method,
      path: path,
      headers: Map.from(headers),
      body: body,
    ));
    if (responses.isEmpty) throw StateError('no fake response');
    return responses.removeAt(0);
  }
}

TrackingHttpResponse _response(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => TrackingHttpResponse(
  statusCode: status,
  headers: headers,
  body: jsonEncode(body),
);

Map<String, dynamic> _authority() => {
  'catalogId': 'yuxuanmian/venera-configs',
  'activeRevision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'artifacts': [
    {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
  ],
};

Map<String, dynamic> _observation(String comicId) => {
  'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'artifact': {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
  'comicId': comicId,
  'observedAt': '2026-09-02T08:15:30.000Z',
  'validUntil': '2099-09-02T08:15:30.000Z',
  'favoriteUpdate': {
    'state': {'latestChapterId': 'chapter-$comicId'},
    'sourceUnread': true,
  },
};

void main() {
  test('loads authority, puts complete state, and sends bearer auth', () async {
    final transport = _FakeTransport([
      _response({'data': _authority()}),
      _response({
        'data': {
          'cloudEnabled': true,
          'interests': [],
          'stateRevision': 1,
          'updatedAt': '2026-09-02T08:15:30.000Z',
        },
      }),
    ]);
    final client = CloudTrackingClient(
      server: Uri.parse('https://tracking.invalid/'),
      accessToken: 'secret-token',
      transport: transport,
    );
    final authority = await client.getAuthority();
    expect(
      authority.activeRevision,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    final state = await client.putClientState(
      cloudEnabled: true,
      interests: const [],
    );
    expect(state.stateRevision, 1);
    expect(
      transport.requests[0].headers['Authorization'],
      'Bearer secret-token',
    );
    expect(transport.requests[1].path, '/api/tracking/client-state');
    expect(jsonDecode(transport.requests[1].body!)['interests'], isEmpty);
  });

  test('handles conditional observations and stable 304 cache', () async {
    final snapshot = {
      'authority': _authority(),
      'generatedAt': '2026-09-02T08:45:30.000Z',
      'observations': [_observation('42')],
    };
    final transport = _FakeTransport([
      _response({'data': snapshot}, headers: {'etag': '"etag-1"'}),
      const TrackingHttpResponse(
        statusCode: 304,
        headers: {'etag': '"etag-1"'},
        body: '',
      ),
    ]);
    final client = CloudTrackingClient(
      server: Uri.parse('https://tracking.invalid'),
      transport: transport,
    );
    final first = await client.getObservations();
    expect(first.notModified, isFalse);
    expect(first.snapshot!.observations.single.comicId, '42');
    final second = await client.getObservations();
    expect(second.notModified, isTrue);
    expect(second.snapshot, same(first.snapshot));
    expect(transport.requests[1].headers['If-None-Match'], '"etag-1"');
  });

  test(
    'rejects authority mismatch, malformed/stale shape, and overflow',
    () async {
      final wrongAuthority = {
        'data': {
          'catalogId': 'untrusted/catalog',
          'activeRevision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'artifacts': [],
        },
      };
      final mismatchClient = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _FakeTransport([_response(wrongAuthority)]),
      );
      await expectLater(
        mismatchClient.getAuthority(),
        throwsA(isA<CloudTrackingException>()),
      );

      final duplicateAuthority = _authority();
      duplicateAuthority['artifacts'] = [
        {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
        {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
      ];
      final duplicateClient = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _FakeTransport([
          _response({'data': duplicateAuthority}),
        ]),
      );
      await expectLater(
        duplicateClient.getAuthority(),
        throwsA(isA<FormatException>()),
      );

      final malformedClient = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _FakeTransport([
          _response({
            'data': {
              'authority': _authority(),
              'generatedAt': '2026-09-02T08:45:30.000Z',
              'observations': [_observation('x')..['revision'] = 'short'],
            },
          }),
        ]),
      );
      await expectLater(
        malformedClient.getObservations(),
        throwsA(isA<FormatException>()),
      );

      final tooMany = List.generate(10001, (index) => _observation('$index'));
      final overflowClient = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _FakeTransport([
          _response({
            'data': {
              'authority': _authority(),
              'generatedAt': '2026-09-02T08:45:30.000Z',
              'observations': tooMany,
            },
          }),
        ]),
      );
      await expectLater(
        overflowClient.getObservations(),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
