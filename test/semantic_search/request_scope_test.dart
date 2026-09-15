import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/semantic_search/request_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SemanticSearchRequestScope', () {
    test('cancel cancels every registered token', () {
      final scope = SemanticSearchRequestScope();
      final first = CancelToken();
      final second = CancelToken();
      scope.register(first);
      scope.register(second);
      expect(scope.ownedTokenCount, 2);
      expect(scope.isCanceled, isFalse);

      scope.cancel();

      expect(scope.isCanceled, isTrue);
      expect(first.isCancelled, isTrue);
      expect(second.isCancelled, isTrue);
      // The scope drops ownership once it has canceled them.
      expect(scope.ownedTokenCount, 0);
    });

    test('unregister removes a completed token and is idempotent', () {
      final scope = SemanticSearchRequestScope();
      final token = CancelToken();
      scope.register(token);
      scope.unregister(token);
      scope.unregister(token);
      expect(scope.ownedTokenCount, 0);

      scope.cancel();
      expect(
        token.isCancelled,
        isFalse,
        reason: 'an unregistered completed token must not be canceled',
      );
    });

    test('cancel is idempotent and never double cancels', () async {
      final scope = SemanticSearchRequestScope();
      final reasons = <String>[];
      final token = CancelToken();
      token.whenCancel.then((_) => reasons.add('canceled'));
      scope.register(token);

      scope.cancel('first reason');
      scope.cancel('second reason');
      await Future<void>.delayed(Duration.zero);

      expect(scope.cancelReason, 'first reason');
      expect(reasons, ['canceled']);
    });

    test('a token registered after cancel is canceled immediately', () {
      final scope = SemanticSearchRequestScope();
      scope.cancel();
      final late = CancelToken();
      scope.register(late);

      expect(late.isCancelled, isTrue);
      expect(scope.ownedTokenCount, 0);
    });

    test('two scopes never observe each other\'s tokens', () {
      final first = SemanticSearchRequestScope();
      final second = SemanticSearchRequestScope();
      final firstToken = CancelToken();
      final secondToken = CancelToken();
      first.register(firstToken);
      second.register(secondToken);

      first.cancel();

      expect(firstToken.isCancelled, isTrue);
      expect(secondToken.isCancelled, isFalse);
      expect(second.ownedTokenCount, 1);
    });

    test('run exposes the scope to the zone and drops it afterwards', () async {
      final scope = SemanticSearchRequestScope();
      expect(SemanticSearchRequestScope.current, isNull);
      final inside = await scope.run(
        () async => SemanticSearchRequestScope.current,
      );
      expect(identical(inside, scope), isTrue);
      expect(SemanticSearchRequestScope.current, isNull);
    });
  });

  group('semantic execution lane ownership through the real QuickJS bridge', () {
    late Directory dataDirectory;

    setUpAll(() async {
      dataDirectory = await Directory.systemTemp.createTemp(
        'venera-semantic-scope-',
      );
      App.dataPath = dataDirectory.path;
      await JsEngine().init();
    });

    tearDownAll(() async {
      if (await dataDirectory.exists()) {
        await dataDirectory.delete(recursive: true);
      }
    });

    test(
      'requests created after await and inside Promise.all are all owned',
      () async {
        final adapter = _ProbeAdapter();
        final dio = Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        JsEngine().setDioForTesting(dio);

        const key = 'scope_lane_ownership';
        final source = await ComicSourceParser().parse(
          _probeSource(key),
          '$key.js',
        );
        expect(source.semanticSearchData, isNotNull);
        expect(source.semanticSearchData!.loadNext, isNotNull);

        final otherScope = SemanticSearchRequestScope();
        final scope = SemanticSearchRequestScope();
        final pending = source.semanticSearchData!.loadNext!(
          'opaque value',
          const ['dd'],
          null,
          requestScope: scope,
        );

        await adapter.concurrentStarted.future.timeout(
          const Duration(seconds: 10),
        );

        expect(
          adapter.requests.length,
          3,
          reason:
              'the probe issues one awaited request and two concurrent ones',
        );
        // A lane binds its cancellation group at runtime creation, so even the
        // requests the source creates after its first await belong to it. This
        // is what ambient Zone propagation cannot provide on flutter_qjs.
        expect(
          scope.ownedTokenCount,
          2,
          reason:
              'requests created after an await and inside Promise.all must be '
              'registered in the invocation scope',
        );
        expect(
          otherScope.ownedTokenCount,
          0,
          reason: 'a concurrent scope must not adopt another scope\'s tokens',
        );

        await source.semanticSearchData!.releaseLane!(scope);
        final result = await pending.timeout(const Duration(seconds: 10));
        expect(result.error, isTrue);
        expect(scope.isCanceled, isTrue);
        expect(adapter.canceledRequests, 2);
        expect(scope.ownedTokenCount, 0);
      },
    );

    test('the ordinary source runtime is never owned by a lane', () async {
      final adapter = _ProbeAdapter();
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      JsEngine().setDioForTesting(dio);

      const key = 'scope_lane_isolation';
      final source = await ComicSourceParser().parse(
        _probeSource(key),
        '$key.js',
      );

      final scope = SemanticSearchRequestScope();
      final semantic = source.semanticSearchData!.loadNext!(
        'value',
        const <String>[],
        null,
        requestScope: scope,
      );
      await adapter.concurrentStarted.future.timeout(
        const Duration(seconds: 10),
      );
      expect(scope.ownedTokenCount, 2);
      final semanticRequests = List<RequestOptions>.from(adapter.requests);

      // An ordinary call on the same source runs on the ordinary runtime, which
      // was never given a cancellation group.
      final ordinary = source.searchPageData!.loadNext!(
        'value',
        null,
        const <String>[],
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        adapter.requests.length,
        semanticRequests.length + 1,
        reason: 'the ordinary call must reach the network on its own runtime',
      );

      await source.semanticSearchData!.releaseLane!(scope);
      await semantic.timeout(const Duration(seconds: 10));
      expect(
        adapter.canceledRequests,
        2,
        reason: 'the ordinary request must survive a semantic lane revoke',
      );
      final ordinaryResult = await ordinary.timeout(
        const Duration(seconds: 10),
      );
      expect(ordinaryResult.error, isFalse);
    });
  });
}

String _probeSource(String key) =>
    '''
class ScopeProbeSource extends ComicSource {
  name = "Scope probe";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    loadNext: async (keyword, options, next) => {
      await Network.post("https://probe.invalid/ordinary", {}, "{}");
      return {comics: [], next: null};
    },
    tagSearch: {
      loadNext: async (value, options, next) => {
        await Network.post("https://probe.invalid/awaited", {}, "{}");
        const results = await Promise.all([
          Network.post("https://probe.invalid/concurrent-a", {}, "{}"),
          Network.post("https://probe.invalid/concurrent-b", {}, "{}"),
        ]);
        return {comics: [], next: "cursor-" + results.length};
      },
    },
  };
}
''';

/// Completes the awaited request immediately and keeps the two concurrent ones
/// in flight, so the test observes exactly the requests created after `await`
/// and inside `Promise.all`.
class _ProbeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final Completer<void> concurrentStarted = Completer<void>();
  int canceledRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!options.uri.toString().contains('concurrent')) {
      return ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final concurrent = requests
        .where((request) => request.uri.toString().contains('concurrent'))
        .length;
    if (concurrent >= 2 && !concurrentStarted.isCompleted) {
      concurrentStarted.complete();
    }
    final result = Completer<ResponseBody>();
    cancelFuture?.then((_) {
      canceledRequests++;
      if (!result.isCompleted) {
        result.completeError(
          DioException.requestCancelled(
            requestOptions: options,
            reason: 'canceled',
          ),
        );
      }
    });
    return result.future;
  }

  @override
  void close({bool force = false}) {}
}
