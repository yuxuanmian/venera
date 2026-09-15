import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

import 'request_scope.dart';

/// The single Host-side semantic presentation constant.
///
/// `controller.dart` and `semantic_search_page.dart` both read this value so
/// the two never drift apart. It is deliberately **not** a source-visible
/// number: a source's own work budget (for example Pica's 6 pages / 3
/// concurrent requests) is declared by that capability and must not depend on
/// the UI append limit.
const int semanticSearchAppendLimit = 20;

/// V1 semantic kinds. Only `tag` exists; a generic kind registry is a
/// forbidden V1 extension.
enum SemanticKind { tag }

/// The immutable identity of one semantic query.
class SemanticQuery {
  /// The comic source that produced this query. It never changes inside a
  /// semantic page.
  final String sourceKey;

  final SemanticKind kind;

  /// Opaque value produced by the source. The Host never trims it, changes its
  /// case, joins a namespace into it or tokenizes it.
  final String value;

  /// A frozen snapshot built from the source's `search.optionList` defaults.
  /// The ordinary search page's mutable selection is never observed here.
  final List<String> options;

  SemanticQuery({
    required this.sourceKey,
    this.kind = SemanticKind.tag,
    required this.value,
    List<String>? options,
  }) : options = List<String>.unmodifiable(options ?? const <String>[]);

  SemanticQuery withOptions(List<String> newOptions) => SemanticQuery(
    sourceKey: sourceKey,
    kind: kind,
    value: value,
    options: newOptions,
  );

  @override
  bool operator ==(Object other) {
    if (other is! SemanticQuery) return false;
    if (other.sourceKey != sourceKey ||
        other.kind != kind ||
        other.value != value ||
        other.options.length != options.length) {
      return false;
    }
    for (var i = 0; i < options.length; i++) {
      if (other.options[i] != options[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(sourceKey, kind, value, Object.hashAll(options));

  @override
  String toString() => 'SemanticQuery($kind, $sourceKey, $value)';
}

/// Host-internal algebra for the two source pagination forms. It is never a
/// public JavaScript value.
sealed class SemanticContinuation {
  const SemanticContinuation();

  /// Whether this continuation is indistinguishable from [other] as far as the
  /// Host is allowed to know. The Host only compares cursors for exact
  /// equality and checks page equality; it never decodes either.
  bool sameAs(SemanticContinuation? other);
}

/// Produced by the Host from a successful page response's explicit `maxPage`.
class PageContinuation extends SemanticContinuation {
  /// The next page the source convention would request.
  final int nextPage;

  /// The inclusive last page the source reported, or `null` when the source
  /// declares no limit.
  final int? maxPage;

  const PageContinuation(this.nextPage, this.maxPage);

  @override
  bool sameAs(SemanticContinuation? other) =>
      other is PageContinuation && other.nextPage == nextPage;

  @override
  bool operator ==(Object other) =>
      other is PageContinuation &&
      other.nextPage == nextPage &&
      other.maxPage == maxPage;

  @override
  int get hashCode => Object.hash(nextPage, maxPage);

  @override
  String toString() => 'PageContinuation($nextPage, $maxPage)';
}

/// An opaque, source-owned cursor. The Host compares it for equality and
/// checks for `null`; it never decodes its content.
class CursorContinuation extends SemanticContinuation {
  final String value;

  const CursorContinuation(this.value);

  @override
  bool sameAs(SemanticContinuation? other) =>
      other is CursorContinuation && other.value == value;

  @override
  bool operator ==(Object other) =>
      other is CursorContinuation && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CursorContinuation(${value.length} chars)';
}

/// The normalized result of one completely successful source invocation.
class SemanticSourceResult {
  /// Never partially committed: the controller only sees a result after the
  /// source invocation as a whole succeeded.
  final List<Comic> comics;

  final SemanticContinuation? next;

  const SemanticSourceResult(this.comics, this.next);
}

/// One replayable, bounded, atomically committed logical invocation.
class SemanticInvocationSnapshot {
  final SemanticQuery query;

  /// The continuation fed into this invocation, or `null` for the initial one.
  final SemanticContinuation? inputContinuation;

  final int generation;

  const SemanticInvocationSnapshot({
    required this.query,
    required this.inputContinuation,
    required this.generation,
  });

  /// The exact logical input a Retry must replay.
  SemanticInvocationSnapshot replay() => SemanticInvocationSnapshot(
    query: query,
    inputContinuation: inputContinuation,
    generation: generation,
  );

  @override
  String toString() =>
      'SemanticInvocationSnapshot(gen: $generation, input: $inputContinuation)';
}

/// The exact logical input of the invocation that failed, retained so Retry
/// replays it instead of skipping a range.
class SemanticFailedInvocation {
  final SemanticQuery query;

  final SemanticContinuation? inputContinuation;

  final int generation;

  const SemanticFailedInvocation({
    required this.query,
    required this.inputContinuation,
    required this.generation,
  });

  SemanticInvocationSnapshot toSnapshot() => SemanticInvocationSnapshot(
    query: query,
    inputContinuation: inputContinuation,
    generation: generation,
  );

  @override
  bool operator ==(Object other) =>
      other is SemanticFailedInvocation &&
      other.query == query &&
      other.inputContinuation == inputContinuation &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(query, inputContinuation, generation);
}

/// Which loader the fixed source actually offers.
enum SemanticCapabilityMode {
  /// A valid `search.tagSearch` exists; results may be called exact.
  exactTag,

  /// No usable `tagSearch`, but an ordinary loader exists. The page stays a
  /// semantic page and links the ordinary loader as a compatibility adapter.
  ordinaryFallback,

  /// No loader at all. A terminal, non-retrying state.
  unsupported,
}

/// Stable comic identity used for cross-invocation de-duplication.
class ComicIdentity {
  final String sourceKey;

  final String id;

  const ComicIdentity(this.sourceKey, this.id);

  factory ComicIdentity.of(Comic comic) =>
      ComicIdentity(comic.sourceKey, comic.id);

  @override
  bool operator ==(Object other) =>
      other is ComicIdentity && other.sourceKey == sourceKey && other.id == id;

  @override
  int get hashCode => sourceKey.hashCode ^ id.hashCode;

  @override
  String toString() => '$sourceKey@$id';
}

/// The controller state machine.
enum SemanticSearchStatus {
  initial,
  loading,
  idle,
  waitingForContinue,
  error,
  finished,
  unsupported,
  disposed,
}

/// The unified loader the controller calls, regardless of capability mode and
/// pagination form. [source_resolver.dart] is its only production
/// implementation; [requestScope] is Host-only and never serialized to JS.
typedef SemanticInvocationRunner =
    Future<Res<SemanticSourceResult>> Function(
      SemanticInvocationSnapshot snapshot,
      SemanticSearchRequestScope scope,
    );

/// The single resolution surface the controller consumes.
///
/// [source_resolver.dart] owns the only production implementation: capability
/// resolution, the page/cursor adapters and the source assembly revision. The
/// page never builds a second adapter and never re-reads `Res.subData`.
abstract class SemanticResolver {
  SemanticCapabilityMode get mode;

  /// Identity of the source assembly that produced these loaders. A change
  /// invalidates every in-flight generation.
  int get revision;

  /// Notifies when the source assembly is replaced, reloaded, disposed or has
  /// its managed runtime revoked. `null` when the resolver cannot observe a
  /// lifecycle.
  Listenable? get lifecycle;

  Future<Res<SemanticSourceResult>> load(
    SemanticInvocationSnapshot snapshot,
    SemanticSearchRequestScope scope,
  );

  /// Destroys the semantic execution lane bound to [scope], if any.
  ///
  /// Idempotent: a scope that never created a lane, or that has already been
  /// released, is a no-op.
  Future<void> releaseLane(SemanticSearchRequestScope scope);
}
