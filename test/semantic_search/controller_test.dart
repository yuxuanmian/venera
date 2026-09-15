import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/semantic_search/controller.dart';
import 'package:venera/foundation/semantic_search/models.dart';

import 'fixtures.dart';

SemanticQuery _query({List<String>? options}) => SemanticQuery(
  sourceKey: 'fixture_source',
  value: 'opaque value',
  options: options ?? const ['dd'],
);

SemanticSearchController _controller(
  FakeSemanticResolver resolver, {
  List<String>? options,
}) => SemanticSearchController(
  query: _query(options: options),
  resolver: resolver,
);

void main() {
  group('immutable models', () {
    test('a query freezes its options snapshot', () {
      final options = <String>['dd'];
      final query = SemanticQuery(sourceKey: 's', value: 'v', options: options);
      options[0] = 'changed';
      options.add('extra');
      expect(query.options, ['dd']);

      final snapshot = SemanticInvocationSnapshot(
        query: query,
        inputContinuation: null,
        generation: 3,
      );
      options[0] = 'changed again';
      expect(snapshot.query.options, ['dd']);
    });

    test('page and cursor continuations are distinguishable', () {
      const page = PageContinuation(4, 42);
      const cursor = CursorContinuation('4');
      expect(page.sameAs(page), isTrue);
      expect(page.sameAs(const PageContinuation(4, 99)), isTrue);
      expect(page.sameAs(const PageContinuation(5, 42)), isFalse);
      expect(cursor.sameAs(const CursorContinuation('4')), isTrue);
      expect(cursor.sameAs(const CursorContinuation('5')), isFalse);
      expect(page.sameAs(cursor), isFalse);
      expect(cursor.sameAs(null), isFalse);
    });

    test('a failed invocation keeps its exact input continuation', () {
      final replayed = SemanticFailedInvocation(
        query: _query(),
        inputContinuation: const CursorContinuation('c1'),
        generation: 7,
      ).toSnapshot();
      expect(replayed.inputContinuation, const CursorContinuation('c1'));
      expect(replayed.generation, 7);
      expect(replayed.query.value, 'opaque value');
    });

    test('comic identity is (sourceKey, id)', () {
      final a = fixtureComic(1);
      final sameIdOtherSource = fixtureComic(1, sourceKey: 'other');
      expect(ComicIdentity.of(a), ComicIdentity.of(fixtureComic(1)));
      expect(
        ComicIdentity.of(a) == ComicIdentity.of(sameIdOtherSource),
        isFalse,
      );
    });
  });

  group('bounded single-cycle controller', () {
    for (final testCase in <({int count, SemanticContinuation? next})>[
      (count: 0, next: null),
      (count: 7, next: cursorContinuation('c1')),
      (count: 20, next: cursorContinuation('c1')),
      (count: 21, next: cursorContinuation('c1')),
      (count: 53, next: null),
    ]) {
      test(
        '${testCase.count} new results with ${testCase.next} next',
        () async {
          final resolver = FakeSemanticResolver();
          resolver.onLoad = (invocation) async =>
              semanticSuccess(fixtureComics(testCase.count), testCase.next);
          final controller = _controller(resolver);
          addTearDown(controller.dispose);

          await controller.start();

          switch (testCase.count) {
            case 0:
              expect(controller.status, SemanticSearchStatus.finished);
              expect(controller.visible, isEmpty);
              expect(resolver.requestCount, 1);
            case 7:
              expect(controller.status, SemanticSearchStatus.idle);
              expect(controller.visible, hasLength(7));
              expect(controller.pending, isEmpty);
              expect(resolver.requestCount, 1);
            case 20:
              expect(controller.status, SemanticSearchStatus.idle);
              expect(controller.visible, hasLength(20));
              expect(resolver.requestCount, 1);
            case 21:
              expect(controller.status, SemanticSearchStatus.idle);
              expect(controller.visible, hasLength(20));
              expect(controller.pending, hasLength(1));

              // The next intent consumes pending with zero source calls.
              await controller.continueWithUserIntent();
              expect(controller.visible, hasLength(21));
              expect(controller.pending, isEmpty);
              expect(controller.status, SemanticSearchStatus.idle);
              expect(controller.hasMore, isTrue);
              expect(resolver.requestCount, 1);
            case 53:
              expect(controller.visible, hasLength(20));
              expect(controller.pending, hasLength(33));

              await controller.continueWithUserIntent();
              expect(controller.visible, hasLength(40));
              expect(controller.pending, hasLength(13));
              expect(controller.status, SemanticSearchStatus.idle);

              await controller.continueWithUserIntent();
              expect(controller.visible, hasLength(53));
              expect(controller.pending, isEmpty);
              expect(controller.status, SemanticSearchStatus.finished);
              expect(
                resolver.requestCount,
                1,
                reason: 'pending consumption never calls the source',
              );
          }
        },
      );
    }

    test('7 new results with a continuation never fill the page', () async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(7), pageContinuation(2, 9));
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible, hasLength(7));
      expect(controller.status, SemanticSearchStatus.idle);
      expect(resolver.requestCount, 1);
    });

    test('near-end alone never starts work; only a new intent does', () async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(3), pageContinuation(2, 9));
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(resolver.requestCount, 1);

      // No gesture happened, so nothing may run even though the source has more.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(resolver.requestCount, 1);

      await controller.continueWithUserIntent();
      expect(resolver.requestCount, 2);
    });
  });

  group('sparse windows, dedupe and protocol errors', () {
    test('an empty window costs at most one extra call per cycle', () async {
      final resolver = FakeSemanticResolver();
      var cursor = 0;
      resolver.onLoad = (invocation) async {
        cursor++;
        return semanticSuccess(const [], cursorContinuation('c$cursor'));
      };
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(
        resolver.requestCount,
        2,
        reason: '1 + emptyRetryBudget(1) invocations in one cycle',
      );
      expect(controller.status, SemanticSearchStatus.waitingForContinue);
      expect(controller.visible, isEmpty);

      // The next intent reopens exactly one cycle.
      await controller.continueWithUserIntent();
      expect(resolver.requestCount, 4);
      expect(controller.status, SemanticSearchStatus.waitingForContinue);
    });

    test('duplicates-only counts as an empty window', () async {
      final resolver = FakeSemanticResolver();
      var cursor = 0;
      resolver.onLoad = (invocation) async {
        cursor++;
        // The first window introduces comic 1 and ends the cycle; every later
        // window repeats only identities the controller has already seen.
        final comics = cursor == 1
            ? [fixtureComic(1)]
            : [fixtureComic(1), fixtureComic(1)];
        return semanticSuccess(comics, cursorContinuation('c$cursor'));
      };
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible, hasLength(1));
      expect(controller.status, SemanticSearchStatus.idle);

      await controller.continueWithUserIntent();
      expect(
        controller.status,
        SemanticSearchStatus.waitingForContinue,
        reason: 'both windows of the second cycle were duplicates-only',
      );
      expect(controller.visible, hasLength(1));
      expect(resolver.requestCount, 3);
    });

    test('a non-advancing cursor is a protocol error, not a loop', () async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(2), cursorContinuation('c1'));
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible, hasLength(2));
      expect(controller.status, SemanticSearchStatus.idle);

      await controller.continueWithUserIntent();
      expect(controller.status, SemanticSearchStatus.error);
      expect(controller.errorMessage, isNotNull);
      expect(
        resolver.requestCount,
        2,
        reason: 'the identical cursor must not be retried automatically',
      );
      // The failed input cursor is preserved for Retry.
      expect(
        controller.failedInvocation!.inputContinuation,
        const CursorContinuation('c1'),
      );
    });

    test('stable cross-window dedupe keeps the first position', () async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 1) {
          return semanticSuccess([
            fixtureComic(1),
            fixtureComic(2),
          ], pageContinuation(2, null));
        }
        return semanticSuccess([
          fixtureComic(2),
          fixtureComic(3),
        ], pageContinuation(3, null));
      };
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible.map((c) => c.id), ['id-1', 'id-2']);

      await controller.continueWithUserIntent();
      expect(controller.visible.map((c) => c.id), [
        'id-1',
        'id-2',
        'id-3',
      ], reason: 'the duplicate index 2 must not move or repeat');
    });

    test('a different source with the same id is not a duplicate', () async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 1) {
          return semanticSuccess([fixtureComic(1)], pageContinuation(2, null));
        }
        return semanticSuccess([
          fixtureComic(1, sourceKey: 'other_source'),
        ], pageContinuation(3, null));
      };
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      await controller.continueWithUserIntent();
      expect(controller.visible, hasLength(2));
    });
  });

  group('errors, Retry and reset', () {
    test('a first-page error is a full error and does not advance', () async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async => Res.error('boom');
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.status, SemanticSearchStatus.error);
      expect(controller.visible, isEmpty);
      expect(controller.errorMessage, 'boom');
      expect(controller.failedInvocation!.inputContinuation, isNull);
    });

    test('a later error keeps the visible list and a footer error', () async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 1) {
          return semanticSuccess(fixtureComics(5), pageContinuation(2, null));
        }
        return Res.error('boom');
      };
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible, hasLength(5));

      await controller.continueWithUserIntent();
      expect(controller.status, SemanticSearchStatus.error);
      expect(controller.visible, hasLength(5));
      expect(
        controller.continuation,
        pageContinuation(2, null),
        reason: 'a failed invocation must not advance the cursor',
      );
    });

    test('Retry replays the exact failed logical input', () async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 2) return Res.error('boom');
        if (call == 1) {
          return semanticSuccess(fixtureComics(2), cursorContinuation('c1'));
        }
        return semanticSuccess(const [], null);
      };
      final controller = _controller(resolver, options: const ['dd', 'extra']);
      addTearDown(controller.dispose);

      await controller.start();
      await controller.continueWithUserIntent();
      expect(controller.status, SemanticSearchStatus.error);

      final failed = controller.failedInvocation!;
      await controller.retry();

      expect(resolver.requestCount, 3);
      final replay = resolver.invocations.last;
      expect(replay.query.value, failed.query.value);
      expect(replay.query.options, failed.query.options);
      expect(replay.inputContinuation, failed.inputContinuation);
      expect(replay.generation, failed.generation);
    });

    test(
      'refresh keeps the query and options but clears from the start',
      () async {
        final resolver = FakeSemanticResolver();
        var call = 0;
        resolver.onLoad = (invocation) async {
          call++;
          return semanticSuccess(
            fixtureComics(call == 1 ? 5 : 2),
            call == 1 ? cursorContinuation('c1') : null,
          );
        };
        final controller = _controller(resolver, options: const ['dd', 'x']);
        addTearDown(controller.dispose);

        await controller.start();
        final oldScope = controller.queryScope;
        final oldGeneration = controller.generation;

        await controller.refresh();

        expect(oldScope.isCanceled, isTrue);
        expect(resolver.releasedScopes, contains(oldScope));
        expect(controller.generation, greaterThan(oldGeneration));
        expect(controller.query.options, ['dd', 'x']);
        expect(controller.visible, hasLength(2));
        expect(controller.status, SemanticSearchStatus.finished);
      },
    );

    test('options change replaces the snapshot and restarts', () async {
      final resolver = FakeSemanticResolver();
      final seen = <List<String>>[];
      resolver.onLoad = (invocation) async {
        seen.add(invocation.query.options);
        return semanticSuccess(const [], null);
      };
      final controller = _controller(resolver, options: const ['dd']);
      addTearDown(controller.dispose);

      await controller.start();
      final mutation = <String>['ld'];
      final pendingUpdate = controller.updateOptions(mutation);
      // The caller keeps mutating its own list after handing it over; the
      // frozen snapshot must not observe that.
      mutation[0] = 'mutated-later';
      await pendingUpdate;

      expect(controller.query.options, ['ld']);
      expect(seen.last, ['ld']);
      expect(resolver.requestCount, 2);
    });

    test('a late success after refresh never commits', () async {
      final resolver = FakeSemanticResolver();
      final gate = Completer<void>();
      resolver.gate = gate;
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      final started = controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.status, SemanticSearchStatus.loading);

      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(4), null);
      resolver.gate = null;
      await controller.refresh();
      expect(controller.visible, hasLength(4));

      // The first invocation finally completes on a retired scope.
      gate.complete();
      await started;
      expect(
        controller.visible,
        hasLength(4),
        reason: 'the late result of a retired attempt must be dropped',
      );
      expect(controller.status, SemanticSearchStatus.finished);
    });

    test('a cancel-wrapped error is dropped silently', () async {
      final resolver = FakeSemanticResolver();
      final gate = Completer<void>();
      resolver.gate = gate;
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      final started = controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.dispose();
      gate.complete();
      await started;
      expect(controller.status, SemanticSearchStatus.disposed);
      expect(controller.errorMessage, isNull);
    });

    test('dispose cancels the attempt and rejects further intents', () async {
      final resolver = FakeSemanticResolver();
      resolver.gate = Completer<void>();
      final controller = _controller(resolver);
      final started = controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final scope = controller.queryScope;

      controller.dispose();
      expect(scope.isCanceled, isTrue);
      expect(resolver.releasedScopes, contains(scope));

      await controller.continueWithUserIntent();
      expect(resolver.requestCount, 1);
      (resolver.gate as Completer<void>).complete();
      await started;
    });

    test('a source assembly revision change cancels the old attempt', () async {
      final resolver = FakeSemanticResolver(
        mode: SemanticCapabilityMode.exactTag,
      );
      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(2), cursorContinuation('c1'));
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.visible, hasLength(2));
      final scope = controller.queryScope;
      final generation = controller.generation;

      resolver.bumpRevision();

      expect(scope.isCanceled, isTrue);
      expect(resolver.releasedScopes, contains(scope));
      expect(controller.generation, greaterThan(generation));
    });

    test('unsupported is a terminal state with no requests', () async {
      final resolver = FakeSemanticResolver(
        mode: SemanticCapabilityMode.unsupported,
      );
      final controller = _controller(resolver);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.status, SemanticSearchStatus.unsupported);
      await controller.continueWithUserIntent();
      await controller.retry();
      expect(resolver.requestCount, 0);
    });
  });
}
