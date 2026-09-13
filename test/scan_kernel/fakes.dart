import 'dart:async';

import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/scan/target_provider.dart';

class FakeScanAdapter implements ScanSourceAdapter {
  FakeScanAdapter({
    required this.sourceKey,
    this.definitionRevision = 'fake-revision',
    this.evidenceSchema,
    this.comicLoader,
    this.collectionLoader,
    this.runtimeContext,
  });

  @override
  final String sourceKey;

  @override
  final String definitionRevision;

  @override
  final String? evidenceSchema;

  @override
  final ManagedSourceContext? runtimeContext;

  @override
  ScanCapabilities get capabilities => const ScanCapabilities.absent();

  final Future<Object?> Function(String comicId, ScanCallLease lease)?
  comicLoader;
  final Future<Object?> Function(
    String collectionKey,
    Object? cursor,
    ScanCallLease lease,
  )?
  collectionLoader;
  final List<ScanCallLease> comicLeases = [];
  final List<ScanCallLease> collectionLeases = [];

  @override
  Future<Object?> loadComic(String comicId, ScanCallLease lease) {
    comicLeases.add(lease);
    return comicLoader?.call(comicId, lease) ??
        Future.value(const {
          'observation': {
            'update': {'updatedAt': '2026-09-10'},
          },
        });
  }

  @override
  Future<Object?> loadCollection(
    String collectionKey,
    Object? cursor,
    ScanCallLease lease,
  ) {
    collectionLeases.add(lease);
    return collectionLoader?.call(collectionKey, cursor, lease) ??
        Future.value(const {'items': <Object?>[], 'next': null});
  }
}

class FakeScanResultRepository implements ScanResultRepository {
  FakeScanResultRepository({this.databaseId = 'fake-db'});

  final String databaseId;
  final _events = StreamController<ScanRepositoryEvent>.broadcast();
  final Map<String, _FakeScope> _scopes = {};
  final Map<String, ScanStoredItem> items = {};
  int nextOrdinal = 0;
  bool opened = false;
  bool closed = false;

  @override
  String get dbInstanceId => databaseId;

  @override
  Stream<ScanRepositoryEvent> get events => _events.stream;

  @override
  Future<void> ensureOpen() async {
    opened = true;
    closed = false;
  }

  @override
  Future<ScanScopeHandle> beginScope({
    required String sourceKey,
    required ScanProducer producer,
    required String scopeKey,
    required String definitionRevision,
    String? scopeAttemptId,
    String? accessContextKey,
    ScanExecutionGuard? guard,
  }) async {
    await ensureOpen();
    guard?.check();
    final handle = ScanScopeHandle(
      sourceKey: sourceKey,
      producer: producer,
      scopeKey: scopeKey,
      scopeAttemptId: scopeAttemptId ?? newScanUuidV4(),
      attemptOrdinal: ++nextOrdinal,
      definitionRevision: definitionRevision,
      accessContextKey: accessContextKey,
      dbInstanceId: databaseId,
    );
    _scopes[_scopeKey(sourceKey, producer, scopeKey)] = _FakeScope(handle);
    return handle;
  }

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async {
    await ensureOpen();
    context.guard?.check();
    _checkContext(context, item);
    final scope =
        _scopes[_scopeKey(
          context.scope.sourceKey,
          context.scope.producer,
          context.scope.scopeKey,
        )];
    if (scope == null) {
      throw const ScanResultConflictException('scan scope is missing');
    }
    if (!_sameHandle(scope.handle, context.scope)) {
      return const ScanItemWriteResult(ScanItemWriteDisposition.stale);
    }
    final key = _itemKey(item.sourceKey, item.comicId);
    final current = items[key];
    if (current != null &&
        current.attemptOrdinal > context.scope.attemptOrdinal) {
      return const ScanItemWriteResult(ScanItemWriteDisposition.stale);
    }
    if (current != null &&
        current.attemptOrdinal == context.scope.attemptOrdinal) {
      if (current.result == item) {
        return const ScanItemWriteResult(ScanItemWriteDisposition.duplicate);
      }
      throw const ScanResultConflictException(
        'same ordinal has a different item payload',
      );
    }
    if (scope.status != ScanScopeStatus.running) {
      return const ScanItemWriteResult(ScanItemWriteDisposition.stale);
    }
    final committed = (committedAt ?? DateTime.now()).millisecondsSinceEpoch;
    final stored = ScanStoredItem(
      result: item,
      attemptOrdinal: context.scope.attemptOrdinal,
      observedAtMs: DateTime.parse(item.observedAt).millisecondsSinceEpoch,
      committedAtMs: committed,
    );
    items[key] = stored;
    scope.itemCount++;
    _events.add(ScanRepositoryEvent(item: stored));
    return const ScanItemWriteResult(ScanItemWriteDisposition.written);
  }

  @override
  Future<ScanScopeWriteResult> finishScope(
    ScanIngestionContext context,
    ScanScopeStatus status, {
    ScanFailure? failure,
    bool allowCanceledAfterControl = false,
    DateTime? finishedAt,
  }) async {
    if (!(status == ScanScopeStatus.canceled && allowCanceledAfterControl)) {
      context.guard?.check();
    }
    final scope =
        _scopes[_scopeKey(
          context.scope.sourceKey,
          context.scope.producer,
          context.scope.scopeKey,
        )];
    if (scope == null || !_sameHandle(scope.handle, context.scope)) {
      return const ScanScopeWriteResult(ScanScopeWriteDisposition.stale);
    }
    if (scope.status != ScanScopeStatus.running) {
      return scope.status == status
          ? const ScanScopeWriteResult(ScanScopeWriteDisposition.duplicate)
          : const ScanScopeWriteResult(ScanScopeWriteDisposition.stale);
    }
    scope.status = status;
    scope.failure = status == ScanScopeStatus.failed ? failure : null;
    scope.finishedAtMs = (finishedAt ?? DateTime.now()).millisecondsSinceEpoch;
    _events.add(ScanRepositoryEvent(scope: _storedScope(scope)));
    return const ScanScopeWriteResult(ScanScopeWriteDisposition.finished);
  }

  @override
  Future<ScanStoredItem?> readLatestItem(
    String sourceKey,
    String comicId,
  ) async {
    return items[_itemKey(sourceKey, comicId)];
  }

  @override
  Future<List<ScanStoredItem>> readAllItems() async =>
      List<ScanStoredItem>.unmodifiable(items.values);

  @override
  Future<ScanStoredScope?> readMatchingScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
    String scopeAttemptId,
  ) async {
    final scope = _scopes[_scopeKey(sourceKey, producer, scopeKey)];
    if (scope == null || scope.handle.scopeAttemptId != scopeAttemptId) {
      return null;
    }
    return _storedScope(scope);
  }

  @override
  Future<ScanStoredScope?> readScopeByAttemptId(
    String sourceKey,
    ScanProducer producer,
    String scopeAttemptId,
  ) async {
    for (final scope in _scopes.values) {
      if (scope.handle.sourceKey == sourceKey &&
          scope.handle.producer == producer &&
          scope.handle.scopeAttemptId == scopeAttemptId) {
        return _storedScope(scope);
      }
    }
    return null;
  }

  @override
  Future<ScanStoredScope?> readLatestScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
  ) async => _scopes[_scopeKey(sourceKey, producer, scopeKey)] == null
      ? null
      : _storedScope(_scopes[_scopeKey(sourceKey, producer, scopeKey)]!);

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }

  void _checkContext(ScanIngestionContext context, ScanItemResult item) {
    if (context.scope.dbInstanceId != databaseId ||
        item.sourceKey != context.scope.sourceKey ||
        item.scopeAttemptId != context.scope.scopeAttemptId ||
        item.producer != context.scope.producer) {
      throw const ScanResultConflictException(
        'scan item does not match its scope',
      );
    }
  }

  static String _scopeKey(String source, ScanProducer producer, String key) =>
      '$source\u0000${producer.value}\u0000$key';

  static String _itemKey(String source, String comic) => '$source\u0000$comic';

  static bool _sameHandle(ScanScopeHandle a, ScanScopeHandle b) =>
      a.dbInstanceId == b.dbInstanceId &&
      a.scopeAttemptId == b.scopeAttemptId &&
      a.attemptOrdinal == b.attemptOrdinal;

  ScanStoredScope _storedScope(_FakeScope scope) => ScanStoredScope(
    sourceKey: scope.handle.sourceKey,
    producer: scope.handle.producer,
    scopeKey: scope.handle.scopeKey,
    scopeAttemptId: scope.handle.scopeAttemptId,
    attemptOrdinal: scope.handle.attemptOrdinal,
    accessContextKey: scope.handle.accessContextKey,
    definitionRevision: scope.handle.definitionRevision,
    startedAtMs: scope.startedAtMs,
    finishedAtMs: scope.finishedAtMs,
    status: scope.status,
    itemCount: scope.itemCount,
    failure: scope.failure,
  );
}

class _FakeScope {
  _FakeScope(this.handle) : startedAtMs = DateTime.now().millisecondsSinceEpoch;

  final ScanScopeHandle handle;
  final int startedAtMs;
  ScanScopeStatus status = ScanScopeStatus.running;
  int? finishedAtMs;
  int itemCount = 0;
  ScanFailure? failure;
}

class FakeTargetProvider extends ScanTargetProvider {
  FakeTargetProvider(this.value)
    : super(
        cache: NetworkFavoriteCacheManager.forTesting(),
        sources: () => const [],
      );

  final ScanTargetSnapshot value;

  @override
  Future<ScanTargetSnapshot> snapshot({
    Map<String, Set<String>>? dueComicIdsBySource,
  }) async => value;
}

ComicSource makeScanTestSource(
  String key, {
  AccountConfig? account,
  FavoriteData? favoriteData,
  ScanCapabilities? scan,
}) => ComicSource(
  'Scan test source',
  key,
  account,
  null,
  null,
  favoriteData,
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
  scan: scan,
);
