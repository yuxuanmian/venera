import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/scan.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/scan/models.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F2.1 (criterion set), F2.2 (completeness), F2.4 (empty set).
///
/// The point of these tests is that every criterion is answered from
/// **configuration**.  Nothing here populates a favorite cache, and the
/// assertions would be the same if the cache did not exist — which is exactly
/// what the cache-derived legacy enumeration could not offer.
void main() {
  /// A source that has been pinned to at least one account.
  ///
  /// `ComicSource.isLogged` reads `data['account'] != null`, so a non-null
  /// [account] config plus a populated `data` entry is what "logged in" means.
  ComicSource loggedInSource(String sourceKey, {bool scanCapable = true}) {
    final source = _source(
      sourceKey,
      withAccount: true,
      scanCapable: scanCapable,
    );
    source.data['account'] = ['some-account'];
    return source;
  }

  ComicSource loggedOutSource(String sourceKey, {bool scanCapable = true}) =>
      _source(sourceKey, withAccount: true, scanCapable: scanCapable);

  ComicSource anonymousSource(String sourceKey, {bool scanCapable = true}) =>
      _source(sourceKey, withAccount: false, scanCapable: scanCapable);

  ({Set<String> keys, Map<String, String> skipped}) derive(
    List<ComicSource> sources,
    Set<String> selected, {
    bool Function(String)? enabled,
  }) => followUpdateSourceKeys(
    sources: sources,
    selectedSourceKeys: selected,
    sourceEnabled: enabled ?? (_) => true,
  );

  group('the criterion set comes from configuration', () {
    test('is non-empty with an empty cache', () {
      // No cache is consulted anywhere in this path; the assertion is really
      // "nothing in the derivation reaches for cached rows".
      final result = derive(
        [loggedInSource('manwa'), loggedInSource('picacg')],
        {'manwa', 'picacg'},
      );
      expect(result.keys, {'manwa', 'picacg'});
      expect(result.skipped, isEmpty);
    });

    test('a source that is not selected is not a criterion', () {
      final result = derive(
        [loggedInSource('manwa'), loggedInSource('picacg')],
        {'manwa'},
      );
      expect(result.keys, {'manwa'});
    });

    test('an empty selection yields an empty criterion set', () {
      final result = derive([loggedInSource('manwa')], const <String>{});
      expect(result.keys, isEmpty);
    });

    test('a selected but disabled source is excluded and recorded', () {
      final result = derive(
        [loggedInSource('manwa'), loggedInSource('picacg')],
        {'manwa', 'picacg'},
        enabled: (key) => key == 'manwa',
      );
      expect(result.keys, {'manwa'});
      expect(result.skipped['picacg'], 'disabled');
    });

    test('a selected but logged-out source is excluded and recorded', () {
      final result = derive(
        [loggedInSource('manwa'), loggedOutSource('picacg')],
        {'manwa', 'picacg'},
      );
      expect(result.keys, {'manwa'});
      expect(result.skipped['picacg'], 'notLoggedIn');
    });

    test('a source with no account config counts as logged in', () {
      // `isLogged` is `data['account'] != null`; a source that never asked for
      // an account cannot be "not logged in", so it must not be dropped.
      final result = derive([anonymousSource('nologin')], {'nologin'});
      expect(result.keys, {'nologin'});
      expect(result.skipped, isEmpty);
    });

    test('a source without a usable scan capability is excluded', () {
      final result = derive(
        [loggedInSource('manwa'), loggedInSource('noscan', scanCapable: false)],
        {'manwa', 'noscan'},
      );
      expect(
        result.keys,
        {'manwa'},
        reason:
            'only sources that can produce an update belong in the '
            'criterion set; otherwise one source without the ability would '
            'block follow-up forever',
      );
      expect(result.skipped['noscan'], 'noScanCapability');
    });

    test('an unsupported (invalid) declaration is not a capability', () {
      final invalid = _source('broken', withAccount: false, scanCapable: false);
      final result = derive([invalid], {'broken'});
      expect(result.keys, isEmpty);
      expect(result.skipped['broken'], 'noScanCapability');
    });
  });

  group('completeness is per criterion source', () {
    test('satisfied only when every criterion source is complete', () {
      final gate = FollowUpdateGate(
        sourceKeys: {'manwa', 'picacg'},
        satisfiedSourceKeys: {'manwa', 'picacg'},
      );
      expect(gate.isCacheComplete, isTrue);
      expect(gate.isSatisfied, isTrue);
      expect(gate.pendingSourceKeys, isEmpty);
      expect(gate.hasPendingSources, isFalse);
      expect(gate.reason, FollowUpdateGateReason.satisfied);
    });

    test('one complete source is enough to show its own results', () {
      // F2.3 (revised): the remaining sources are reported, not blocking.  The
      // old rule held the whole gate closed here, which made follow-up
      // permanently unusable for anyone who added a source and never cached it.
      final gate = FollowUpdateGate(
        sourceKeys: {'manwa', 'picacg'},
        satisfiedSourceKeys: {'manwa'},
      );
      expect(
        gate.isSatisfied,
        isTrue,
        reason: 'the user must see what is ready instead of nothing at all',
      );
      expect(gate.satisfiedSourceKeys, {'manwa'});
      expect(gate.pendingSourceKeys, {'picacg'});
      expect(gate.hasPendingSources, isTrue);
      expect(gate.reason, FollowUpdateGateReason.satisfied);
      expect(
        gate.isCacheComplete,
        isFalse,
        reason: '"everything is ready" stays a different question',
      );
    });

    test('with no complete source there is nothing to show', () {
      final gate = FollowUpdateGate(
        sourceKeys: {'manwa', 'picacg'},
        satisfiedSourceKeys: const <String>{},
      );
      expect(gate.isSatisfied, isFalse);
      expect(gate.reason, FollowUpdateGateReason.cacheIncomplete);
      expect(gate.pendingSourceKeys, {'manwa', 'picacg'});
    });

    test(
      'an empty criterion set is NOT satisfied, though vacuously complete',
      () {
        final gate = FollowUpdateGate(
          sourceKeys: const <String>{},
          satisfiedSourceKeys: const <String>{},
        );
        expect(gate.hasSources, isFalse);
        expect(gate.isCacheComplete, isTrue);
        expect(
          gate.isSatisfied,
          isFalse,
          reason:
              'F2.4: "there is nothing to track" MUST NOT be read as '
              '"everything is ready", or the user sees a permanently empty list',
        );
        expect(gate.reason, FollowUpdateGateReason.noSources);
      },
    );

    test('extra completeness marks do not widen the criterion set', () {
      final gate = FollowUpdateGate(
        sourceKeys: {'manwa'},
        satisfiedSourceKeys: {'manwa', 'a-source-the-user-deselected'},
      );
      expect(gate.isSatisfied, isTrue);
      expect(gate.sourceKeys, {'manwa'});
    });
  });

  group('evaluateFollowUpdateGate', () {
    test('derives criteria and completeness together from configuration', () {
      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: {'manwa'},
        sources: [loggedInSource('manwa'), loggedInSource('picacg')],
        selectedSourceKeys: {'manwa', 'picacg'},
        sourceEnabled: (_) => true,
      );
      expect(gate.sourceKeys, {'manwa', 'picacg'});
      expect(gate.satisfiedSourceKeys, {'manwa'});
      expect(
        gate.isSatisfied,
        isTrue,
        reason: 'the complete source can answer; picacg is reported, not fatal',
      );
      expect(gate.pendingSourceKeys, {'picacg'});
      expect(gate.hasPendingSources, isTrue);
    });

    test('an empty cache is not a satisfied gate', () {
      // The whole reason the criterion set must be configuration-derived: with
      // a cache-derived set this returns "satisfied" and shows an empty list.
      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: const <String>{},
        sources: [loggedInSource('manwa')],
        selectedSourceKeys: {'manwa'},
        sourceEnabled: (_) => true,
      );
      expect(gate.sourceKeys, isNotEmpty);
      expect(gate.isSatisfied, isFalse);
      expect(gate.reason, FollowUpdateGateReason.cacheIncomplete);
    });

    test('a source outside the criterion set cannot block the gate', () {
      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: const <String>{},
        sources: [
          loggedInSource('manwa'),
          // Selected but not scan capable: its cache being incomplete is
          // irrelevant, because it can never produce an update.
          loggedInSource('noscan', scanCapable: false),
        ],
        selectedSourceKeys: {'manwa', 'noscan'},
        sourceEnabled: (_) => true,
      );
      expect(gate.sourceKeys, {'manwa'});
      expect(gate.isSatisfied, isFalse);
      expect(gate.pendingSourceKeys, {'manwa'});
    });
  });
}

ComicSource _source(
  String key, {
  required bool withAccount,
  required bool scanCapable,
}) => ComicSource(
  'Fake $key',
  key,
  withAccount
      ? AccountConfig(null, null, null, _noop, null, null, null, null)
      : null,
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
  scan: scanCapable
      ? ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic(_stubLoader, evidenceSchema: '{"a":"b"}'),
        )
      : null,
);

void _noop() {}

/// A loader that is never invoked: these tests only ask *whether* a source
/// declares a usable capability, never run one.
Future<Object?> _stubLoader(String comicId, ScanHostRequest request) async =>
    null;
