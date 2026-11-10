import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

typedef _ResponseHandler =
    FutureOr<CatalogBytesResponse> Function(_TransportRequest request);

class _TransportRequest {
  const _TransportRequest({
    required this.uri,
    required this.timeout,
    required this.maxBytes,
    required this.cancellation,
  });

  final Uri uri;
  final Duration timeout;
  final int maxBytes;
  final CatalogCancellationToken? cancellation;
}

class _RecordingTransport implements CatalogTransport {
  _RecordingTransport(this._handler);

  final _ResponseHandler _handler;
  final requests = <_TransportRequest>[];

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    final request = _TransportRequest(
      uri: uri,
      timeout: timeout,
      maxBytes: maxBytes,
      cancellation: cancellation,
    );
    requests.add(request);
    return _handler(request);
  }
}

CatalogBytesResponse _jsonResponse(Object? value, {int statusCode = 200}) =>
    CatalogBytesResponse(statusCode, utf8.encode(jsonEncode(value)));

CatalogAttempt _attempt({
  String id = 'repository-source',
  Duration duration = const Duration(seconds: 5),
}) => CatalogAttempt(id: id, deadline: DateTime.now().add(duration));

Matcher _catalogError(String code) =>
    isA<CatalogHttpException>().having((error) => error.code, 'code', code);

Matcher _sourceError(String code) => isA<CatalogRepositorySourceException>()
    .having((error) => error.code, 'code', code);

void main() {
  group('CatalogRepositorySource', () {
    test(
      'uses the default source and normalizes owner and repository case',
      () {
        expect(
          CatalogRepositorySource.defaults.repositoryUrl,
          CatalogRepositorySource.defaultRepositoryUrl,
        );
        expect(CatalogRepositorySource.defaults.branch, 'yxm');

        final source = CatalogRepositorySource.parse(
          ' https://github.com/YuxuanMian/VENERA-Configs ',
          branch: 'Feature/Release',
        );
        expect(
          source.repositoryUrl,
          'https://github.com/yuxuanmian/venera-configs',
        );
        expect(source.catalogId, 'yuxuanmian/venera-configs');
        expect(source.branch, 'Feature/Release');
        expect(
          source,
          CatalogRepositorySource.parse(
            source.repositoryUrl,
            branch: 'Feature/Release',
          ),
        );
      },
    );

    test('rejects non-canonical or ambiguous GitHub repository URLs', () {
      final values = [
        'http://github.com/owner/repo',
        'https://gitlab.com/owner/repo',
        'https://user:secret@github.com/owner/repo',
        'https://github.com:443/owner/repo',
        'https://github.com:/owner/repo',
        'https://github.com/owner/repo?ref=main',
        'https://github.com/owner/repo?',
        'https://github.com/owner/repo#readme',
        'https://github.com/owner/repo#',
        'https://github.com/owner',
        'https://github.com/owner/repo/',
        'https://github.com/owner/repo/extra',
        'https://github.com/owner//repo',
        'https://github.com/owner/../repo',
        'https://github.com/owner/a/../repo',
        'https://github.com/owner/./repo',
        'https://github.com/owner%2Frepo',
        'https://github.com/owner/repo.git',
      ];
      for (final value in values) {
        expect(
          () => CatalogRepositorySource.parse(value),
          throwsA(_sourceError('invalid_repository_url')),
          reason: value,
        );
      }
    });

    test('accepts slash-separated refs and rejects invalid Git refs', () {
      for (final branch in ['main', 'feature/release-2026', 'Topic/ümlaut']) {
        expect(
          CatalogRepositorySource(branch: branch).branch,
          branch,
          reason: branch,
        );
      }

      for (final branch in [
        '',
        '@',
        '-main',
        '/main',
        'main/',
        'main.',
        'main..next',
        'main@{1}',
        'main~1',
        'main^1',
        'main:next',
        'main?next',
        'main*next',
        'main[next',
        r'main\next',
        'main//next',
        'feature/.hidden',
        'feature/topic.lock',
        'main next',
        'main\nnext',
      ]) {
        expect(
          () => CatalogRepositorySource(branch: branch),
          throwsA(_sourceError('invalid_branch')),
          reason: branch,
        );
      }
    });
  });

  group('resolveRepositoryHead', () {
    test('resolves a slash-separated branch into a pinned pointer', () async {
      final revision = 'a' * 40;
      final transport = _RecordingTransport(
        (_) => _jsonResponse({
          'ref': 'refs/heads/Feature/Release',
          'object': {'type': 'commit', 'sha': revision},
        }),
      );
      final source = CatalogRepositorySource(
        repositoryUrl: 'https://github.com/YuxuanMian/VENERA-Configs',
        branch: 'Feature/Release',
      );
      final pointer = await CatalogHttpClient(
        transport: transport,
      ).resolveRepositoryHead(source, attempt: _attempt());

      expect(
        transport.requests.single.uri.toString(),
        'https://api.github.com/repos/yuxuanmian/venera-configs/git/ref/heads/Feature/Release',
      );
      expect(transport.requests.single.maxBytes, catalogMaxGitRefBytes);
      expect(
        transport.requests.single.timeout,
        lessThanOrEqualTo(catalogHeadTimeout),
      );
      expect(pointer.catalogId, 'yuxuanmian/venera-configs');
      expect(pointer.revision, revision);
      expect(
        pointer.indexUrl,
        'https://raw.githubusercontent.com/yuxuanmian/venera-configs/$revision/index.json',
      );
    });

    test('encodes branch path segments without allowing URL injection', () async {
      final revision = 'b' * 40;
      final transport = _RecordingTransport(
        (_) => _jsonResponse({
          'ref': 'refs/heads/Feature/#Release',
          'object': {'type': 'commit', 'sha': revision},
        }),
      );
      final source = CatalogRepositorySource(branch: 'Feature/#Release');
      final pointer = await CatalogHttpClient(
        transport: transport,
      ).resolveRepositoryHead(source);

      expect(
        transport.requests.single.uri.toString(),
        'https://api.github.com/repos/yuxuanmian/venera-configs/git/ref/heads/Feature/%23Release',
      );
      expect(transport.requests.single.uri.hasQuery, isFalse);
      expect(transport.requests.single.uri.hasFragment, isFalse);
      expect(pointer.revision, revision);
    });

    test('rejects malformed, mismatched, and non-commit responses', () async {
      final revision = 'a' * 40;
      final values = <Object?>[
        [],
        {},
        {
          'ref': 'refs/heads/other',
          'object': {'type': 'commit', 'sha': revision},
        },
        {
          'ref': 'refs/heads/yxm',
          'object': {'type': 'tree', 'sha': revision},
        },
        {
          'ref': 'refs/heads/yxm',
          'object': {'type': 'commit', 'sha': 'a' * 39},
        },
        {
          'ref': 'refs/heads/yxm',
          'object': {'type': 'commit', 'sha': 'A' * 40},
        },
        {
          'ref': 'refs/heads/yxm',
          'object': {'type': 'commit', 'sha': '${'a' * 39}g'},
        },
      ];
      for (final value in values) {
        final client = CatalogHttpClient(
          transport: _RecordingTransport((_) => _jsonResponse(value)),
        );
        await expectLater(
          client.resolveRepositoryHead(
            CatalogRepositorySource.defaults,
            attempt: _attempt(),
          ),
          throwsA(_catalogError('invalid_head_response')),
          reason: jsonEncode(value),
        );
      }

      final malformed = CatalogHttpClient(
        transport: _RecordingTransport(
          (_) => CatalogBytesResponse(200, utf8.encode('{')),
        ),
      );
      await expectLater(
        malformed.resolveRepositoryHead(CatalogRepositorySource.defaults),
        throwsA(_catalogError('invalid_head_response')),
      );
    });

    test(
      'enforces response size and does not expose error response bodies',
      () async {
        final oversized = CatalogHttpClient(
          transport: _RecordingTransport(
            (_) => CatalogBytesResponse(
              200,
              List<int>.filled(catalogMaxGitRefBytes + 1, 0),
            ),
          ),
        );
        await expectLater(
          oversized.resolveRepositoryHead(CatalogRepositorySource.defaults),
          throwsA(_catalogError('response_too_large')),
        );

        const secret = 'must-not-appear-in-error';
        final failed = CatalogHttpClient(
          transport: _RecordingTransport(
            (_) => _jsonResponse({'message': secret}, statusCode: 403),
          ),
        );
        await expectLater(
          failed.resolveRepositoryHead(CatalogRepositorySource.defaults),
          throwsA(
            isA<CatalogHttpException>()
                .having((error) => error.code, 'code', 'head_query_failed')
                .having(
                  (error) => error.toString().contains(secret),
                  'contains response body',
                  isFalse,
                ),
          ),
        );
      },
    );

    test('honors attempt cancellation and deadline', () async {
      final cancelledTransport = _RecordingTransport((request) async {
        await request.cancellation!.whenCancelled;
        throw const CatalogHttpException('cancelled', 'cancelled');
      });
      final cancelledAttempt = _attempt();
      final cancelled = CatalogHttpClient(transport: cancelledTransport)
          .resolveRepositoryHead(
            CatalogRepositorySource.defaults,
            attempt: cancelledAttempt,
          );
      await Future<void>.delayed(Duration.zero);
      expect(cancelledTransport.requests, hasLength(1));
      cancelledAttempt.close();
      await expectLater(cancelled, throwsA(_catalogError('cancelled')));

      final pending = Completer<CatalogBytesResponse>();
      final timed =
          CatalogHttpClient(
            transport: _RecordingTransport((_) => pending.future),
          ).resolveRepositoryHead(
            CatalogRepositorySource.defaults,
            attempt: _attempt(
              id: 'short-head',
              duration: const Duration(milliseconds: 10),
            ),
          );
      await expectLater(timed, throwsA(_catalogError('timeout')));
    });

    test(
      'rejects a successful head response that arrives after cancellation',
      () async {
        final pending = Completer<CatalogBytesResponse>();
        final transport = _RecordingTransport((_) => pending.future);
        final attempt = _attempt();
        final result = CatalogHttpClient(transport: transport)
            .resolveRepositoryHead(
              CatalogRepositorySource.defaults,
              attempt: attempt,
            );
        final rejected = expectLater(
          result,
          throwsA(_catalogError('cancelled')),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.requests, hasLength(1));

        attempt.close();
        pending.complete(
          _jsonResponse({
            'ref': 'refs/heads/yxm',
            'object': {'type': 'commit', 'sha': 'e' * 40},
          }),
        );
        await rejected;
      },
    );
  });

  group('readIndex', () {
    test('reads and validates only the pinned index', () async {
      final pointer = CatalogRepositorySource.defaults.pointerForRevision(
        'b' * 40,
      );
      final transport = _RecordingTransport(
        (_) => _jsonResponse([
          {
            'name': 'Disabled',
            'key': 'disabled_source',
            'fileName': 'disabled.js',
            'version': '1',
            'enabled': false,
          },
          {
            'name': 'Enabled',
            'key': 'EnabledSource',
            'fileName': 'enabled.js',
            'version': '1',
            'enabled': true,
          },
        ]),
      );
      final index = await CatalogHttpClient(
        transport: transport,
      ).readIndex(pointer, attempt: _attempt());

      expect(index.entries, hasLength(2));
      expect(transport.requests.single.uri, Uri.parse(pointer.indexUrl));
      expect(transport.requests.single.maxBytes, catalogMaxIndexBytes);
      expect(
        transport.requests.single.timeout,
        lessThanOrEqualTo(catalogFileRequestTimeout),
      );
    });

    test(
      'classifies invalid pointers, HTTP failures, and invalid indexes',
      () async {
        final attempt = _attempt();
        final invalidPointerClient = CatalogHttpClient(
          transport: _RecordingTransport((_) => throw StateError('unexpected')),
        );
        await expectLater(
          invalidPointerClient.readIndex(
            const CatalogPointer(
              catalogId: 'owner/repo',
              revision: 'short',
              indexUrl:
                  'https://raw.githubusercontent.com/owner/repo/short/index.json',
            ),
            attempt: attempt,
          ),
          throwsA(_catalogError('invalid_pointer')),
        );

        final pointer = CatalogRepositorySource.defaults.pointerForRevision(
          'c' * 40,
        );
        final failed = CatalogHttpClient(
          transport: _RecordingTransport(
            (_) => CatalogBytesResponse(500, utf8.encode('failure body')),
          ),
        );
        await expectLater(
          failed.readIndex(pointer, attempt: _attempt()),
          throwsA(_catalogError('index_query_failed')),
        );

        final invalid = CatalogHttpClient(
          transport: _RecordingTransport(
            (_) => _jsonResponse([
              {
                'name': 'Unsafe',
                'key': 'unsafe_source',
                'fileName': '../unsafe.js',
                'version': '1',
              },
            ]),
          ),
        );
        await expectLater(
          invalid.readIndex(pointer, attempt: _attempt()),
          throwsA(_catalogError('invalid_index')),
        );

        final oversized = CatalogHttpClient(
          transport: _RecordingTransport(
            (_) => CatalogBytesResponse(
              200,
              List<int>.filled(catalogMaxIndexBytes + 1, 0),
            ),
          ),
        );
        await expectLater(
          oversized.readIndex(pointer, attempt: _attempt()),
          throwsA(_catalogError('response_too_large')),
        );
      },
    );

    test(
      'rejects a successful index response that arrives after cancellation',
      () async {
        final pointer = CatalogRepositorySource.defaults.pointerForRevision(
          'f' * 40,
        );
        final pending = Completer<CatalogBytesResponse>();
        final transport = _RecordingTransport((_) => pending.future);
        final attempt = _attempt();
        final result = CatalogHttpClient(
          transport: transport,
        ).readIndex(pointer, attempt: attempt);
        final rejected = expectLater(
          result,
          throwsA(_catalogError('cancelled')),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.requests, hasLength(1));

        attempt.close();
        pending.complete(
          _jsonResponse([
            {
              'name': 'Late',
              'key': 'late_source',
              'fileName': 'late.js',
              'version': '1',
            },
          ]),
        );
        await rejected;
      },
    );
  });

  test(
    'downloads the pinned index and every declared source, including disabled entries',
    () async {
      final revision = 'd' * 40;
      final source = CatalogRepositorySource.defaults;
      final pointer = source.pointerForRevision(revision);
      final headUrl =
          'https://api.github.com/repos/yuxuanmian/venera-configs/git/ref/heads/yxm';
      final sourceUrls = {
        'https://raw.githubusercontent.com/yuxuanmian/venera-configs/$revision/first.js',
        'https://raw.githubusercontent.com/yuxuanmian/venera-configs/$revision/second.js',
      };
      final transport = _RecordingTransport((request) {
        if (request.uri.toString() == headUrl) {
          return _jsonResponse({
            'ref': 'refs/heads/yxm',
            'object': {'type': 'commit', 'sha': revision},
          });
        }
        if (request.uri == Uri.parse(pointer.indexUrl)) {
          return _jsonResponse([
            {
              'name': 'First',
              'key': 'first_source',
              'fileName': 'first.js',
              'version': '1',
              'enabled': false,
            },
            {
              'name': 'Second',
              'key': 'second_source',
              'fileName': 'second.js',
              'version': '1',
              'enabled': true,
            },
          ]);
        }
        if (sourceUrls.contains(request.uri.toString())) {
          return CatalogBytesResponse(
            200,
            utf8.encode('source for ${request.uri.pathSegments.last}'),
          );
        }
        throw StateError('unexpected request ${request.uri}');
      });
      final client = CatalogHttpClient(transport: transport);
      final attempt = _attempt(
        id: 'pinned-download',
        duration: const Duration(seconds: 10),
      );
      final resolved = await client.resolveRepositoryHead(
        source,
        attempt: attempt,
      );
      final root = await Directory.systemTemp.createTemp(
        'catalog-repository-download-',
      );
      addTearDown(() => root.delete(recursive: true));
      final candidate = await client.downloadSnapshot(
        resolved,
        store: CatalogStore(root),
        attempt: attempt,
      );

      expect(candidate.pointer, pointer);
      expect(candidate.index.entries, hasLength(2));
      expect(candidate.manifest.files, hasLength(2));
      expect(
        transport.requests.map((request) => request.uri.toString()),
        containsAll([headUrl, pointer.indexUrl, ...sourceUrls]),
      );
      expect(
        transport.requests.where(
          (request) => sourceUrls.contains(request.uri.toString()),
        ),
        hasLength(2),
      );
    },
  );
}
