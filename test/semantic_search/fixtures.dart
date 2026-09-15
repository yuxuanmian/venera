import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/semantic_search/models.dart';
import 'package:venera/foundation/semantic_search/request_scope.dart';

/// Deterministic `Comic` factory. Identity is exactly `(sourceKey, id)`.
Comic fixtureComic(int index, {String sourceKey = 'fixture_source'}) => Comic(
  'Comic $index',
  // An empty cover keeps the shared card widget from starting a network image
  // load, which would leave pending timers in widget tests.
  '',
  'id-$index',
  null,
  // Mutable, exactly like `Comic.fromJson` produces; the shared card widget
  // normalises this list in place.
  <String>[],
  '',
  sourceKey,
  null,
  null,
);

List<Comic> fixtureComics(int count, {String sourceKey = 'fixture_source'}) =>
    List<Comic>.generate(
      count,
      (index) => fixtureComic(index, sourceKey: sourceKey),
    );

/// One recorded invocation of the resolved semantic loader.
class RecordedInvocation {
  RecordedInvocation(this.snapshot, this.scope);

  final SemanticInvocationSnapshot snapshot;

  final SemanticSearchRequestScope scope;

  SemanticQuery get query => snapshot.query;

  SemanticContinuation? get inputContinuation => snapshot.inputContinuation;

  int get generation => snapshot.generation;

  /// Whether the Host retired the query attempt this invocation belonged to.
  bool get scopeCanceled => scope.isCanceled;

  @override
  String toString() =>
      'RecordedInvocation(gen: $generation, input: $inputContinuation)';
}

Res<SemanticSourceResult> semanticSuccess(
  List<Comic> comics, [
  SemanticContinuation? next,
]) => Res(SemanticSourceResult(comics, next));

SemanticContinuation pageContinuation(int nextPage, [int? maxPage]) =>
    PageContinuation(nextPage, maxPage);

SemanticContinuation cursorContinuation(String value) =>
    CursorContinuation(value);

/// A fully scripted [SemanticResolver].
///
/// It records every invocation (query, options, continuation, generation and
/// the Host scope it received), counts requests and lets a test gate completion
/// behind a [Completer] so cancellation and late-completion races are testable.
/// It never touches global search history, a real network or a JavaScript
/// runtime.
class FakeSemanticResolver implements SemanticResolver {
  FakeSemanticResolver({
    this.mode = SemanticCapabilityMode.exactTag,
    int initialRevision = 0,
  }) : _revision = initialRevision;

  @override
  SemanticCapabilityMode mode;

  int _revision;

  @override
  int get revision => _revision;

  final _LifecycleNotifier _lifecycle = _LifecycleNotifier();

  @override
  Listenable get lifecycle => _lifecycle;

  final List<RecordedInvocation> invocations = <RecordedInvocation>[];

  final List<SemanticSearchRequestScope> releasedScopes =
      <SemanticSearchRequestScope>[];

  /// Number of resolved-loader calls. The contract's "source request count".
  int get requestCount => invocations.length;

  int get lastRequestCount => _lastRequestCount;

  int _lastRequestCount = 0;

  /// Called for every invocation. The default is an empty terminal success.
  Future<Res<SemanticSourceResult>> Function(RecordedInvocation invocation)
  onLoad = (invocation) async => semanticSuccess(const <Comic>[]);

  /// When set, every invocation waits for it before producing a result.
  Completer<void>? gate;

  /// Marks the loading of an invocation as started, for deterministic tests.
  final List<Completer<void>> started = <Completer<void>>[];

  RecordedInvocation get last => invocations.last;

  @override
  Future<Res<SemanticSourceResult>> load(
    SemanticInvocationSnapshot snapshot,
    SemanticSearchRequestScope scope,
  ) async {
    _lastRequestCount++;
    final record = RecordedInvocation(snapshot, scope);
    invocations.add(record);
    final startedCompleter = Completer<void>();
    started.add(startedCompleter);
    startedCompleter.complete();
    final pendingGate = gate;
    if (pendingGate != null) {
      await pendingGate.future;
    }
    return onLoad(record);
  }

  @override
  Future<void> releaseLane(SemanticSearchRequestScope scope) async {
    releasedScopes.add(scope);
  }

  /// Simulates a source assembly replacement.
  void bumpRevision() {
    _revision++;
    _lifecycle.notify();
  }

  void dispose() => _lifecycle.dispose();
}

class _LifecycleNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Builds the option snapshot a semantic page starts from, exactly as the
/// ordinary search page does: one default value per declared option group.
List<String> defaultSearchOptions(ComicSource source) {
  final options =
      source.searchPageData?.searchOptions ?? const <SearchOptions>[];
  return options.map((option) => option.defaultValue).toList();
}
