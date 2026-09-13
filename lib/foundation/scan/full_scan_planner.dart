import '../catalog/runtime_context.dart';
import '../comic_source/comic_source.dart';
import 'execution_guard.dart';
import 'models.dart';
import 'source_adapter.dart';
import 'target_provider.dart';

/// Source/account identity captured while the target snapshot is built.
/// Secrets such as passwords and tokens are intentionally not included.
class ScanSourceSnapshot {
  ScanSourceSnapshot({
    required this.managed,
    Iterable<String> accountIdentity = const [],
  }) : accountIdentity = List.unmodifiable(accountIdentity);

  final bool managed;
  final List<String> accountIdentity;
}

class ScanWorkSpec {
  const ScanWorkSpec._({
    required this.source,
    required this.adapter,
    required this.producer,
    required this.scopeKey,
    this.comicId,
    this.logLabel,
    this.sourceSnapshot,
  });

  factory ScanWorkSpec.comic({
    required ComicSource source,
    required ScanSourceAdapter adapter,
    required String comicId,
    String? logLabel,
    ScanSourceSnapshot? sourceSnapshot,
  }) => ScanWorkSpec._(
    source: source,
    adapter: adapter,
    producer: ScanProducer.comic,
    scopeKey: comicId,
    comicId: comicId,
    logLabel: logLabel,
    sourceSnapshot: sourceSnapshot,
  );

  factory ScanWorkSpec.collection({
    required ComicSource source,
    required ScanSourceAdapter adapter,
    required String collectionKey,
    ScanSourceSnapshot? sourceSnapshot,
  }) => ScanWorkSpec._(
    source: source,
    adapter: adapter,
    producer: ScanProducer.collection,
    scopeKey: collectionKey,
    sourceSnapshot: sourceSnapshot,
  );

  final ComicSource source;
  final ScanSourceAdapter adapter;
  final ScanProducer producer;
  final String scopeKey;
  final String? comicId;

  /// This work's log identity (007 Contract L4), when the planner had one.
  ///
  /// Per-comic work carries it from planning time, where the favorite-cache
  /// entry already held the display name.  Collection work leaves it null: a
  /// collection call is per **page**, and the page ordinal is only known while
  /// the pages are being walked, so the executor supplies it.
  final String? logLabel;

  final ScanSourceSnapshot? sourceSnapshot;

  String get sourceKey => source.key;
  String get identity => '$sourceKey\u0000${producer.value}\u0000$scopeKey';

  ScanWork toWork(ScanExecutionGuard guard) =>
      ScanWork(spec: this, guard: guard);
}

class ScanWork {
  const ScanWork({required this.spec, required this.guard});

  final ScanWorkSpec spec;
  final ScanExecutionGuard guard;

  String get sourceKey => spec.sourceKey;
  ScanProducer get producer => spec.producer;
  String get scopeKey => spec.scopeKey;
  String? get comicId => spec.comicId;
  String? get logLabel => spec.logLabel;
  ScanSourceAdapter get adapter => spec.adapter;
  String get definitionRevision => adapter.definitionRevision;

  /// The selected branch's comparable label, forwarded exactly like
  /// [definitionRevision].
  String? get evidenceSchema => adapter.evidenceSchema;

  ManagedSourceContext? get runtimeContext => adapter.runtimeContext;
}

class FullScanPlanner {
  const FullScanPlanner();

  List<ScanWorkSpec> plan(ScanTargetSnapshot snapshot) {
    final grouped = <String, List<ScanWorkSpec>>{};
    final unique = <String, ScanWorkSpec>{};
    for (final work in snapshot.works) {
      unique.putIfAbsent(work.identity, () => work);
    }
    for (final work in unique.values) {
      grouped.putIfAbsent(work.sourceKey, () => []).add(work);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.identity.compareTo(b.identity));
    }
    final sourceKeys = grouped.keys.toList()..sort();
    final result = <ScanWorkSpec>[];
    var index = 0;
    while (true) {
      var added = false;
      for (final sourceKey in sourceKeys) {
        final list = grouped[sourceKey]!;
        if (index < list.length) {
          result.add(list[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return List.unmodifiable(result);
  }
}
