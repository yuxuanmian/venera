import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/scan/due_filter.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/scan/target_provider.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-v1.md` S4.
///
/// `now` never appears in this file: the caller has already turned it into the
/// `expiredComicIds` / `futureScheduledComicIds` split.  That is the point of
/// the split — the same stored data must yield the same answer at any moment,
/// so no function under test may read a clock.
void main() {
  group('the four due conditions are a disjunction (S4)', () {
    Set<String> dueOf({
      required Set<String> all,
      Set<String> observed = const {},
      Set<String> expired = const {},
      Set<String> future = const {},
    }) => computeDueComicIds(
      allComicIds: all,
      observedComicIds: observed,
      expiredComicIds: expired,
      futureScheduledComicIds: future,
    ).dueComicIds;

    test('condition 1: no observation is due', () {
      expect(dueOf(all: {'a'}), {'a'});
    });

    test('condition 2: no schedule record is due', () {
      expect(dueOf(all: {'a'}, observed: {'a'}), {'a'});
    });

    test('condition 3 or 4: an expired schedule row is due', () {
      expect(dueOf(all: {'a'}, observed: {'a'}, expired: {'a'}), {
        'a',
      }, reason: 'readExpired covers both "next_at null" and "next_at <= now"');
    });

    test('not due only when all four fail', () {
      expect(dueOf(all: {'a'}, observed: {'a'}, future: {'a'}), isEmpty);
    });

    test('each condition holds on its own, with the other three failing', () {
      // 1 alone.
      expect(dueOf(all: {'a'}, observed: {}, expired: {}, future: {}), {'a'});
      // 2 alone: observed, and no schedule row in either bucket.
      expect(dueOf(all: {'b'}, observed: {'b'}), {'b'});
      // 3/4 alone: observed and scheduled, but the row is expired.
      expect(dueOf(all: {'c'}, observed: {'c'}, expired: {'c'}), {'c'});
    });

    test('a mixed population yields exactly the expected members', () {
      final due = dueOf(
        all: {'fresh', 'stale', 'unseen', 'unscheduled', 'out-of-scope'},
        // `out-of-scope` is scheduled and observed but not in the domain, so it
        // must not appear: the domain is the round's candidate list.
        observed: {'fresh', 'stale', 'unscheduled', 'out-of-scope'},
        expired: {'stale'},
        future: {'fresh', 'out-of-scope'},
      );
      expect(due, {'stale', 'unseen', 'unscheduled'});
    });

    test('"no observation" outranks a schedule row claiming not due', () {
      // The scenario that makes S4's second corollary matter: the observation
      // store was deleted or rebuilt while schedule rows survived.  Those
      // identities have no evidence left, so they must come back into scope
      // rather than being suppressed by stale schedule data forever.
      final due = dueOf(
        all: {'gone-1', 'gone-2'},
        observed: const <String>{},
        expired: const <String>{},
        future: {'gone-1', 'gone-2'},
      );
      expect(due, {'gone-1', 'gone-2'});
    });

    test('the tempting simplification fails this suite', () {
      // `due = expired` is the shape S4 explicitly warns against.  Writing the
      // wrong answer out makes the difference visible: it silently drops every
      // identity that has no observation yet, i.e. the whole first round.
      const all = {'a', 'b'};
      const expired = <String>{};
      final naive = expired;
      final complete = dueOf(all: all);
      expect(naive, isEmpty);
      expect(complete, all, reason: 'a first round has nothing observed yet');
    });
  });

  group('a collection-type source needs no special case (S4 corollary 1)', () {
    test('its comics stay due because no schedule row is ever written', () {
      // The exclusion is a data consequence, not a branch: an identity with no
      // schedule record satisfies condition 2 forever.
      final first = computeDueComicIds(
        allComicIds: const {'c1', 'c2'},
        observedComicIds: const {'c1', 'c2'},
        expiredComicIds: const <String>{},
        futureScheduledComicIds: const <String>{},
      );
      expect(first.dueComicIds, {'c1', 'c2'});
      expect(first.scheduledComicIds, isEmpty);

      // Even after many rounds, nothing about them is scheduled.
      final later = computeDueComicIds(
        allComicIds: const {'c1', 'c2'},
        observedComicIds: const {'c1', 'c2'},
        expiredComicIds: const <String>{},
        futureScheduledComicIds: const <String>{},
      );
      expect(later.dueComicIds, {'c1', 'c2'});
    });
  });

  group('due filtering is a pure narrowing of the target snapshot', () {
    test('keeps only the due per-comic work items', () {
      final snapshot = ScanTargetSnapshot(
        works: [
          _work('src', comicId: 'due'),
          _work('src', comicId: 'not-due-yet'),
          _work('src', comicId: 'also-due'),
        ],
        cacheGeneration: 7,
      );

      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: {
          'src': {'due', 'also-due'},
        },
      );

      expect(filtered.works.map((w) => w.comicId), ['due', 'also-due']);
      expect(
        filtered.cacheGeneration,
        7,
        reason: 'filtering must not disturb the frozen cache generation',
      );
    });

    test(
      'a work item without a comic id is always kept, not special-cased',
      () {
        // Collection work has no `(source, comic)` identity to schedule, so a
        // per-comic due set cannot express it.  The filter therefore has no
        // producer branch at all -- it simply has nothing to test.
        final snapshot = ScanTargetSnapshot(
          works: [
            _work('src', collectionKey: 'default'),
            _work('src', comicId: 'not-due-yet'),
          ],
          cacheGeneration: 3,
        );
        final filtered = filterTargetsByDue(
          snapshot: snapshot,
          dueComicIdsBySource: const {},
        );
        expect(filtered.works, hasLength(1));
        expect(filtered.works.single.producer, ScanProducer.collection);
      },
    );

    test('the filter contains no producer comparison', () {
      // Expressed structurally rather than by reading the source: a collection
      // work item and a comic work item are treated by the same rule, so
      // removing the producer distinction changes nothing observable.
      final comic = _work('src', comicId: 'x');
      final collection = _work('src', collectionKey: 'x');
      expect(comic.producer, isNot(collection.producer));

      final withComic = filterTargetsByDue(
        snapshot: ScanTargetSnapshot(works: [comic], cacheGeneration: 0),
        dueComicIdsBySource: const {},
      );
      final withCollection = filterTargetsByDue(
        snapshot: ScanTargetSnapshot(works: [collection], cacheGeneration: 0),
        dueComicIdsBySource: const {},
      );
      // Same input identity, different producer: the only difference in outcome
      // is the one the data itself dictates (a comic id can be in a due set, a
      // collection key cannot).
      expect(withComic.works, isEmpty);
      expect(withCollection.works, hasLength(1));
    });

    test('a source with no due set contributes nothing', () {
      final snapshot = ScanTargetSnapshot(
        works: [
          _work('src', comicId: 'a'),
          _work('other', comicId: 'b'),
        ],
        cacheGeneration: 1,
      );
      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: {
          'src': {'a'},
        },
      );
      expect(filtered.works.map((w) => w.sourceKey), ['src']);
    });

    test('never adds work that was not in the snapshot', () {
      final snapshot = ScanTargetSnapshot(
        works: [_work('src', comicId: 'a')],
        cacheGeneration: 1,
      );
      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: {
          'src': {'a', 'an-id-the-provider-never-produced'},
        },
      );
      expect(filtered.works, hasLength(1));
    });

    test('an empty due set removes every per-comic item', () {
      final snapshot = ScanTargetSnapshot(
        works: [
          _work('src', comicId: 'a'),
          _work('src', comicId: 'b'),
        ],
        cacheGeneration: 1,
      );
      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: const {},
      );
      expect(filtered.works, isEmpty);
    });

    test('skipped sources are preserved for diagnostics', () {
      final snapshot = ScanTargetSnapshot(
        works: [_work('src', comicId: 'a')],
        cacheGeneration: 1,
        skippedSources: const [
          ScanSourceSkip(
            sourceKey: 'off',
            reason: ScanSourceSkipReason.disabled,
          ),
        ],
      );
      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: const {},
      );
      expect(filtered.skippedSources, hasLength(1));
    });

    test('a round with nothing due produces an empty work list', () {
      // The performance goal in one assertion: with every identity scheduled
      // into the future, the round issues no source requests at all.
      final snapshot = ScanTargetSnapshot(
        works: [for (var i = 0; i < 50; i++) _work('src', comicId: 'comic-$i')],
        cacheGeneration: 1,
      );
      final filtered = filterTargetsByDue(
        snapshot: snapshot,
        dueComicIdsBySource: const {'src': <String>{}},
      );
      expect(filtered.works, isEmpty);
    });
  });
}

ScanWorkSpec _work(String sourceKey, {String? comicId, String? collectionKey}) {
  final source = _stubSource(sourceKey);
  final adapter = _StubAdapter(sourceKey);
  return comicId != null
      ? ScanWorkSpec.comic(source: source, adapter: adapter, comicId: comicId)
      : ScanWorkSpec.collection(
          source: source,
          adapter: adapter,
          collectionKey: collectionKey!,
        );
}

ComicSource _stubSource(String key) => ComicSource(
  'Stub $key',
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

class _StubAdapter implements ScanSourceAdapter {
  _StubAdapter(this.sourceKey);

  @override
  final String sourceKey;

  @override
  String get definitionRevision => 'rev-1';

  @override
  String? get evidenceSchema => null;

  @override
  ManagedSourceContext? get runtimeContext => null;

  @override
  ScanCapabilities get capabilities => const ScanCapabilities.absent();

  @override
  Future<Object?> loadComic(String comicId, ScanCallLease lease) async => null;

  @override
  Future<Object?> loadCollection(
    String collectionKey,
    Object? cursor,
    ScanCallLease lease,
  ) async => null;
}
