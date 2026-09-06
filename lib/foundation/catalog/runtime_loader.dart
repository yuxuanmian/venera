import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../comic_source/comic_source.dart';
import 'models.dart';
import 'runtime_context.dart';

typedef CatalogSourceFactory =
    FutureOr<Object> Function(
      CatalogSourceEntry entry,
      String source,
      ManagedSourceContext context,
    );

class PreparedSource {
  const PreparedSource({
    required this.entry,
    required this.value,
    required this.context,
    this.afterPublish,
  });

  final CatalogSourceEntry entry;
  final Object value;
  final ManagedSourceContext context;
  final Future<void> Function()? afterPublish;
}

class PreparedRuntime {
  PreparedRuntime({
    required this.snapshot,
    required this.sources,
    this.onPublish,
    this.onDispose,
  });

  final CatalogSnapshot snapshot;
  final List<PreparedSource> sources;
  final void Function(List<PreparedSource> sources)? onPublish;
  final void Function(List<PreparedSource> sources)? onDispose;
  bool _published = false;
  bool _disposed = false;

  bool get isPublished => _published;
  bool get isDisposed => _disposed;

  void publish() {
    if (_disposed) throw StateError('prepared Runtime has been disposed');
    if (_published) return;
    for (final source in sources) {
      source.context.publish();
    }
    _published = true;
    onPublish?.call(List.unmodifiable(sources));
    // Business init is intentionally after the synchronous publication
    // barrier. Errors here do not revoke a successfully published Catalog.
    for (final source in sources) {
      unawaited(_runAfterPublish(source));
    }
  }

  Future<void> _runAfterPublish(PreparedSource source) async {
    try {
      await source.afterPublish?.call();
      await source.context.runAfterPublish();
    } catch (_) {
      // Site init is a post-publish business error. The active Runtime stays
      // available; callers can report it through their normal diagnostics.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final source in sources) {
      source.context.revoke();
    }
    onDispose?.call(List.unmodifiable(sources));
  }
}

class CatalogRuntimeLoader {
  CatalogRuntimeLoader({CatalogSourceFactory? factory})
    : factory = factory ?? _defaultFactory;

  final CatalogSourceFactory factory;

  factory CatalogRuntimeLoader.forComicSources() {
    return CatalogRuntimeLoader(
      factory: (entry, source, context) async {
        return ComicSourceParser().parseManaged(
          source,
          context.sourcePath,
          expectedKey: entry.key,
          context: context,
        );
      },
    );
  }

  Future<PreparedRuntime> prepare(
    CatalogSnapshot snapshot, {
    Map<String, Map<String, dynamic>> sourceData = const {},
    void Function(List<PreparedSource> sources)? onPublish,
    void Function(List<PreparedSource> sources)? onDispose,
  }) async {
    final prepared = <PreparedSource>[];
    ManagedSourceContext? currentContext;
    try {
      for (final entry in snapshot.index.entries) {
        final record = snapshot.manifest.files.firstWhere(
          (file) => file.sourceKey == entry.key,
        );
        final file = File(snapshot.sourcePath(record));
        final source = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: false,
        );
        final context = ManagedSourceContext(
          snapshot: snapshot,
          sourceKey: entry.key,
          data: sourceData[entry.key],
        );
        currentContext = context;
        final value = await factory(entry, source, context);
        if (context.preparationViolation != null) {
          throw CatalogRuntimeDenied(
            'Source preparation attempted a forbidden side effect: '
            '${context.preparationViolation}',
          );
        }
        prepared.add(
          PreparedSource(entry: entry, value: value, context: context),
        );
        currentContext = null;
      }
      return PreparedRuntime(
        snapshot: snapshot,
        sources: List.unmodifiable(prepared),
        onPublish: onPublish,
        onDispose: onDispose,
      );
    } catch (_) {
      currentContext?.revoke();
      for (final source in prepared) {
        source.context.revoke();
      }
      rethrow;
    }
  }

  /// Validates the entire candidate using a disposable preparation assembly.
  Future<void> validateCandidate(
    CatalogSnapshot snapshot, {
    Map<String, Map<String, dynamic>> sourceData = const {},
  }) async {
    final runtime = await prepare(snapshot, sourceData: sourceData);
    runtime.dispose();
  }
}

Future<Object> _defaultFactory(
  CatalogSourceEntry entry,
  String source,
  ManagedSourceContext context,
) async {
  if (source.isEmpty) throw StateError('source ${entry.key} is empty');
  // The actual ComicSource parser can be injected by the App integration;
  // this structural default keeps the Catalog core independent of Flutter QJS.
  return source;
}
