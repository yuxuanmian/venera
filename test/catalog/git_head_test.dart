import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/setup_failure.dart';
import 'package:venera/network/app_dio.dart';

const _source = CatalogRepositorySource.defaults;
final _revision = 'a' * 40;

String _packet(String text) =>
    '${(utf8.encode(text).length + 4).toRadixString(16).padLeft(4, '0')}$text';

final _advertisement = CatalogBytesResponse(
  200,
  utf8.encode(
    '${_packet('# service=git-upload-pack\n')}0000'
    '${_packet('version 2\n')}${_packet('ls-refs=unborn\n')}'
    '${_packet('object-format=sha1\n')}0000',
  ),
  contentType: 'application/x-git-upload-pack-advertisement',
);

CatalogBytesResponse _refs(Iterable<String> lines) => CatalogBytesResponse(
  200,
  utf8.encode('${lines.map((line) => _packet('$line\n')).join()}0000'),
  contentType: 'application/x-git-upload-pack-result',
);

CatalogBytesResponse _restSuccess() => CatalogBytesResponse(
  200,
  utf8.encode(
    jsonEncode({
      'ref': 'refs/heads/${_source.branch}',
      'object': {'type': 'commit', 'sha': _revision},
    }),
  ),
);

class _Transport implements CatalogGitTransport {
  _Transport(this.git, {CatalogBytesResponse Function()? rest})
    : rest = rest ?? _restSuccess;

  final FutureOr<CatalogBytesResponse> Function(
    Uint8List? body,
    CatalogCancellationToken cancellation,
  )
  git;
  final CatalogBytesResponse Function() rest;
  final gitRequests = <({Uri uri, Uint8List? body, Duration timeout})>[];
  final restTimeouts = <Duration>[];

  @override
  Future<CatalogBytesResponse> requestGit(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    required CatalogCancellationToken cancellation,
    Uint8List? body,
  }) async {
    expect(maxBytes, catalogMaxGitRefBytes);
    gitRequests.add((uri: uri, body: body, timeout: timeout));
    return git(body, cancellation);
  }

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    expect(uri.host, 'api.github.com');
    restTimeouts.add(timeout);
    return rest();
  }
}

class _GitAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<int>? postBytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = BytesBuilder();
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.add(chunk);
      }
      postBytes = bytes.takeBytes();
    }
    final response = options.method == 'GET'
        ? _advertisement
        : _refs(['$_revision refs/heads/${_source.branch}']);
    return ResponseBody.fromBytes(
      response.bytes,
      response.statusCode,
      headers: {
        'content-type': [response.contentType!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Matcher _errorCode(String code) =>
    isA<CatalogHttpException>().having((error) => error.code, 'code', code);

void main() {
  test('Git looks up one exact branch and pins the returned SHA', () async {
    final source = CatalogRepositorySource(branch: 'Team/分支');
    const ref = 'refs/heads/Team/分支';
    final transport = _Transport(
      (body, _) => body == null
          ? _advertisement
          : _refs(['${'b' * 40} $ref-old', '$_revision $ref']),
    );

    final pointer = await CatalogHttpClient(
      transport: transport,
    ).resolveRepositoryHead(source);
    expect(pointer, source.pointerForRevision(_revision));
    expect(transport.restTimeouts, isEmpty);
    expect(transport.gitRequests.map((request) => request.uri.toString()), [
      '${source.repositoryUrl}.git/info/refs?service=git-upload-pack',
      '${source.repositoryUrl}.git/git-upload-pack',
    ]);
    expect(transport.gitRequests.first.body, isNull);
    expect(
      utf8.decode(transport.gitRequests.last.body!),
      '${_packet('command=ls-refs\n')}0001${_packet('ref-prefix $ref\n')}0000',
    );
  });

  test(
    'AppDio sends the Git packets as bytes with existing network limits',
    () async {
      final adapter = _GitAdapter();
      final dio = AppDio()..httpClientAdapter = adapter;
      final client = CatalogHttpClient(
        transport: AppDioCatalogTransport(dio: dio),
      );
      final pointer = await client.resolveRepositoryHead(_source);

      expect(pointer.revision, _revision);
      expect(adapter.requests.map((request) => request.method), [
        'GET',
        'POST',
      ]);
      for (final request in adapter.requests) {
        expect(request.headers['Git-Protocol'], 'version=2');
        expect(request.extra['catalogLiveRef'], isTrue);
        expect(request.extra['catalogNoRedirect'], isTrue);
        expect(request.extra['catalogMaxBytes'], catalogMaxGitRefBytes);
      }
      expect(
        adapter.requests.last.contentType,
        'application/x-git-upload-pack-request',
      );
      expect(
        utf8.decode(adapter.postBytes!),
        contains('ref-prefix refs/heads/${_source.branch}\n'),
      );
    },
  );

  test(
    'a valid ref list without the branch is reported without REST',
    () async {
      final transport = _Transport(
        (body, _) => body == null
            ? _advertisement
            : _refs(['$_revision refs/heads/${_source.branch}-old']),
      );
      await expectLater(
        CatalogHttpClient(transport: transport).resolveRepositoryHead(_source),
        throwsA(_errorCode('branch_not_found')),
      );
      expect(transport.restTimeouts, isEmpty);
    },
  );

  test(
    'malformed Git data falls back to REST using the remaining budget',
    () async {
      final transport = _Transport((body, _) async {
        if (body == null) return _advertisement;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return CatalogBytesResponse(
          200,
          utf8.encode('FFFFshort'),
          contentType: 'application/x-git-upload-pack-result',
        );
      });
      final result = await CatalogHttpClient(
        transport: transport,
      ).resolveRepositoryHead(_source);
      expect(result.revision, _revision);
      expect(
        transport.restTimeouts.single,
        lessThan(transport.gitRequests.last.timeout),
      );
    },
  );

  test(
    'REST 403 pauses fallback until reset while Git remains usable',
    () async {
      var gitAvailable = false;
      final resetSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
      final reset = DateTime.fromMillisecondsSinceEpoch(
        resetSeconds * 1000,
        isUtc: true,
      );
      final transport = _Transport(
        (body, _) {
          if (!gitAvailable) return const CatalogBytesResponse(503, []);
          return body == null
              ? _advertisement
              : _refs(['$_revision refs/heads/${_source.branch}']);
        },
        rest: () => CatalogBytesResponse(
          403,
          [],
          headers: {
            'x-ratelimit-remaining': ['0'],
            'x-ratelimit-reset': ['$resetSeconds'],
          },
        ),
      );
      final client = CatalogHttpClient(transport: transport);
      Matcher limited = isA<CatalogHeadRateLimitException>()
          .having((error) => error.retryAt, 'retryAt', reset)
          .having(
            (error) => CatalogSetupFailure.fromError(
              error,
              CatalogSetupStage.repositoryHead,
            )?.kind,
            'classification',
            CatalogSetupFailureKind.repositoryRateLimited,
          );
      await expectLater(
        client.resolveRepositoryHead(_source),
        throwsA(limited),
      );
      await expectLater(
        client.resolveRepositoryHead(_source),
        throwsA(limited),
      );
      expect(transport.restTimeouts, hasLength(1));

      gitAvailable = true;
      expect((await client.resolveRepositoryHead(_source)).revision, _revision);
      expect(transport.restTimeouts, hasLength(1));
    },
  );

  test('closing the parent attempt cancels Git without falling back', () async {
    final started = Completer<void>();
    final transport = _Transport((_, cancellation) async {
      started.complete();
      await cancellation.whenCancelled;
      return _advertisement;
    });
    final attempt = CatalogAttempt(
      id: 'cancel-git',
      deadline: DateTime.now().add(const Duration(seconds: 10)),
    );
    final result = CatalogHttpClient(
      transport: transport,
    ).resolveRepositoryHead(_source, attempt: attempt);
    final rejected = expectLater(result, throwsA(_errorCode('cancelled')));
    await started.future;
    attempt.close();
    await rejected;
    expect(transport.gitRequests, hasLength(1));
    expect(transport.restTimeouts, isEmpty);
  });
}
