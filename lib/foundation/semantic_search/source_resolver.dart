import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';

import 'models.dart';
import 'request_scope.dart';

/// The single owner of capability resolution and of the page/cursor adapters.
///
/// The page creates the query, asks this resolver for a mode, and renders. It
/// never re-parses `search.tagSearch`, never inspects `Res.subData` and never
/// builds a second pagination adapter.
class ComicSourceSemanticResolver implements SemanticResolver {
  ComicSourceSemanticResolver(
    this.source, {
    Listenable? assemblyLifecycle,
    int Function()? assemblyRevision,
  }) : _assemblyLifecycle = assemblyLifecycle ?? ComicSourceManager(),
       _assemblyRevision =
           assemblyRevision ?? (() => ComicSourceManager().assemblyRevision) {
    _lastAssemblyRevision = _assemblyRevision();
    _assemblyLifecycle?.addListener(_onAssemblyChanged);
    _removeRevokeListener = source.runtimeContext?.addRevokeListener(
      _onSourceRevoked,
    );
  }

  final ComicSource source;

  final Listenable? _assemblyLifecycle;

  final int Function() _assemblyRevision;

  final _LifecycleNotifier _lifecycle = _LifecycleNotifier();

  void Function()? _removeRevokeListener;

  late int _lastAssemblyRevision;

  int _revision = 0;

  /// The initial page index under the existing ordinary search convention.
  static const int initialPage = 1;

  @override
  int get revision => _revision;

  @override
  Listenable get lifecycle => _lifecycle;

  @override
  SemanticCapabilityMode get mode {
    if (_exactCapability != null) return SemanticCapabilityMode.exactTag;
    if (_ordinaryPageLoader != null || _ordinaryNextLoader != null) {
      return SemanticCapabilityMode.ordinaryFallback;
    }
    return SemanticCapabilityMode.unsupported;
  }

  SemanticSearchData? get _exactCapability {
    final data = source.semanticSearchData;
    if (data == null) return null;
    if (data.loadPage == null && data.loadNext == null) return null;
    return data;
  }

  SearchFunction? get _ordinaryPageLoader => source.searchPageData?.loadPage;

  SearchNextFunction? get _ordinaryNextLoader =>
      source.searchPageData?.loadNext;

  void _onAssemblyChanged() {
    final current = _assemblyRevision();
    if (current == _lastAssemblyRevision) return;
    _lastAssemblyRevision = current;
    _bumpRevision();
  }

  void _onSourceRevoked() {
    _bumpRevision();
  }

  void _bumpRevision() {
    _revision++;
    _lifecycle.notify();
  }

  /// Releases the resolver's lifecycle subscriptions. A resolver outliving its
  /// page is what would keep an old source assembly's callbacks alive, so the
  /// controller disposes it through this method's owner.
  void dispose() {
    _assemblyLifecycle?.removeListener(_onAssemblyChanged);
    _removeRevokeListener?.call();
    _removeRevokeListener = null;
    _lifecycle.dispose();
  }

  @override
  Future<Res<SemanticSourceResult>> load(
    SemanticInvocationSnapshot snapshot,
    SemanticSearchRequestScope scope,
  ) async {
    final capability = _exactCapability;
    if (capability != null) {
      return _loadExact(capability, snapshot, scope);
    }
    if (_ordinaryPageLoader != null || _ordinaryNextLoader != null) {
      return _loadOrdinary(snapshot, scope);
    }
    return const Res.error('This source does not support semantic search');
  }

  @override
  Future<void> releaseLane(SemanticSearchRequestScope scope) async {
    await source.semanticSearchData?.releaseLane?.call(scope);
  }

  Future<Res<SemanticSourceResult>> _loadExact(
    SemanticSearchData capability,
    SemanticInvocationSnapshot snapshot,
    SemanticSearchRequestScope scope,
  ) async {
    final options = snapshot.query.options;
    if (capability.loadPage != null) {
      final int page;
      switch (snapshot.inputContinuation) {
        case null:
          page = initialPage;
        case PageContinuation(:final nextPage):
          page = nextPage;
        case CursorContinuation():
          return const Res.error('Semantic source pagination form changed');
      }
      final res = await capability.loadPage!(
        snapshot.query.value,
        options,
        page,
        requestScope: scope,
      );
      return _adaptPageResult(res, page);
    }
    final String? next;
    switch (snapshot.inputContinuation) {
      case null:
        next = null;
      case CursorContinuation(:final value):
        next = value;
      case PageContinuation():
        return const Res.error('Semantic source pagination form changed');
    }
    final res = await capability.loadNext!(
      snapshot.query.value,
      options,
      next,
      requestScope: scope,
    );
    return _adaptCursorResult(res);
  }

  Future<Res<SemanticSourceResult>> _loadOrdinary(
    SemanticInvocationSnapshot snapshot,
    SemanticSearchRequestScope scope,
  ) async {
    // The ordinary loaders do not accept a Host scope, so the adapter is the
    // one place that keeps their requests inside the invocation zone.
    final options = snapshot.query.options;
    if (_ordinaryPageLoader != null) {
      final int page;
      switch (snapshot.inputContinuation) {
        case null:
          page = initialPage;
        case PageContinuation(:final nextPage):
          page = nextPage;
        case CursorContinuation():
          return const Res.error('Semantic source pagination form changed');
      }
      final res = await scope.run(
        () => _ordinaryPageLoader!(snapshot.query.value, page, options),
      );
      return _adaptPageResult(res, page);
    }
    final String? next;
    switch (snapshot.inputContinuation) {
      case null:
        next = null;
      case CursorContinuation(:final value):
        next = value;
      case PageContinuation():
        return const Res.error('Semantic source pagination form changed');
    }
    final res = await scope.run(
      () => _ordinaryNextLoader!(snapshot.query.value, next, options),
    );
    return _adaptCursorResult(res);
  }

  /// A page loader ends strictly on the source's explicit `maxPage`; empty
  /// comics before `maxPage` never imply the end.
  Res<SemanticSourceResult> _adaptPageResult(Res<List<Comic>> res, int page) {
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    final maxPage = res.subData;
    if (maxPage != null && maxPage is! int) {
      Log.error(
        'Semantic Search',
        'Source declared a non-integer maxPage (${maxPage.runtimeType})',
      );
      return const Res.error('Semantic source declared an invalid maxPage');
    }
    final limit = maxPage as int?;
    final SemanticContinuation? next = (limit != null && page >= limit)
        ? null
        : PageContinuation(page + 1, limit);
    return Res(SemanticSourceResult(res.data, next), subData: res.subData);
  }

  /// A cursor loader ends on `next == null`; the Host never decodes the value.
  Res<SemanticSourceResult> _adaptCursorResult(Res<List<Comic>> res) {
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    final raw = res.subData;
    final SemanticContinuation? next;
    if (raw == null) {
      next = null;
    } else if (raw is String) {
      next = CursorContinuation(raw);
    } else {
      Log.error(
        'Semantic Search',
        'Source declared a non-string cursor (${raw.runtimeType})',
      );
      return const Res.error('Semantic source declared an invalid cursor');
    }
    return Res(SemanticSourceResult(res.data, next), subData: raw);
  }
}

class _LifecycleNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
