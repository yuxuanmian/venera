import 'dart:async';

import 'models.dart';

enum ManagedSourcePhase { preparing, published, revoked }

class ManagedSourceContext {
  ManagedSourceContext({
    required this.snapshot,
    required this.sourceKey,
    Map<String, dynamic>? data,
    this.persistData,
  }) : _data = _copyMap(data ?? const {});

  final CatalogSnapshot snapshot;
  final String sourceKey;
  final Future<void> Function(Map<String, dynamic> data)? persistData;
  final Map<String, dynamic> _data;
  ManagedSourcePhase phase = ManagedSourcePhase.preparing;
  final _afterPublish = <FutureOr<void> Function()>[];
  final _onRevoke = <void Function()>[];
  Object? _preparationViolation;

  Map<String, dynamic> get data => Map.unmodifiable(_data);

  int get revokeListenerCount => _onRevoke.length;

  Object? get preparationViolation => _preparationViolation;

  void recordPreparationViolation(Object error) {
    _preparationViolation ??= error;
  }

  String get sourcePath {
    final file = snapshot.manifest.files.firstWhere(
      (candidate) => candidate.sourceKey == sourceKey,
    );
    return snapshot.sourcePath(file);
  }

  dynamic readData(String key) {
    _requireUsable();
    return _data[key];
  }

  /// During preparation this updates only an isolated copy. Once published,
  /// the existing source-data persistence path may be used.
  Future<void> writeData(String key, dynamic value) async {
    _requireUsable();
    _data[key] = value;
    if (phase == ManagedSourcePhase.published) {
      await persistData?.call(Map<String, dynamic>.from(_data));
    }
  }

  Future<void> deleteData(String key) async {
    _requireUsable();
    _data.remove(key);
    if (phase == ManagedSourcePhase.published) {
      await persistData?.call(Map<String, dynamic>.from(_data));
    }
  }

  void publish() {
    if (phase != ManagedSourcePhase.preparing) {
      throw StateError('source context cannot be published from $phase');
    }
    phase = ManagedSourcePhase.published;
  }

  /// Registers work which may run only after the complete source assembly has
  /// been synchronously installed by the Runtime publisher.
  void addAfterPublish(FutureOr<void> Function() callback) {
    if (phase == ManagedSourcePhase.revoked) return;
    _afterPublish.add(callback);
  }

  Future<void> runAfterPublish() async {
    if (phase != ManagedSourcePhase.published) return;
    final callbacks = List<FutureOr<void> Function()>.from(_afterPublish);
    _afterPublish.clear();
    for (final callback in callbacks) {
      try {
        await callback();
      } catch (_) {
        // Business initialization is post-publish work. A source failure must
        // not revoke an already published, otherwise valid Catalog assembly.
      }
    }
  }

  void onRevoke(void Function() callback) {
    addRevokeListener(callback);
  }

  /// Registers a revocation callback and returns a backwards-compatible
  /// removal function.  Long-lived source callbacks may keep their listener
  /// for the context lifetime; short-lived scan requests must unregister it
  /// as soon as their request settles.
  void Function() addRevokeListener(void Function() callback) {
    if (phase == ManagedSourcePhase.revoked) {
      callback();
      return () {};
    } else {
      var active = true;
      void wrapped() {
        if (!active) return;
        active = false;
        callback();
      }

      _onRevoke.add(wrapped);
      return () {
        if (!active) return;
        active = false;
        _onRevoke.remove(wrapped);
      };
    }
  }

  void revoke() {
    if (phase == ManagedSourcePhase.revoked) return;
    phase = ManagedSourcePhase.revoked;
    for (final callback in _onRevoke.toList()) {
      callback();
    }
    _onRevoke.clear();
    _afterPublish.clear();
  }

  void requirePublished() {
    if (phase != ManagedSourcePhase.published) {
      throw const CatalogRuntimeDenied(
        'Source callback is unavailable before Runtime publish.',
      );
    }
  }

  void requirePreparing() {
    if (phase != ManagedSourcePhase.preparing) {
      throw StateError('source is not in preparation');
    }
  }

  void _requireUsable() {
    if (phase == ManagedSourcePhase.revoked) {
      throw StateError('source context has been revoked');
    }
  }
}

/// Runtime admission errors are intentionally owned by the Catalog layer;
/// they are not part of tracking or source-editing state.
class CatalogRuntimeDenied implements Exception {
  const CatalogRuntimeDenied(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Small bridge used by the JS engine and source callbacks. The context is
/// the only admission token; there is no global Cloud/custom mode or durable
/// per-artifact registry involved in execution.
class ManagedRuntimeBridge {
  const ManagedRuntimeBridge();

  ManagedSourceContext? get current =>
      Zone.current[_managedContextZoneKey] as ManagedSourceContext?;

  void require(ManagedSourceContext? context) {
    if (context == null ||
        context.phase != ManagedSourcePhase.preparing &&
            context.phase != ManagedSourcePhase.published) {
      if (context != null) {
        throw const CatalogRuntimeDenied(
          'Catalog source execution has been revoked.',
        );
      }
    }
  }

  T run<T>(ManagedSourceContext context, T Function() action) {
    require(context);
    return runZoned(action, zoneValues: {_managedContextZoneKey: context});
  }
}

const managedRuntimeBridge = ManagedRuntimeBridge();
final _managedContextZoneKey = Object();

Map<String, dynamic> _copyMap(Map<String, dynamic> source) {
  dynamic copy(dynamic value) {
    if (value is Map) {
      return value.map((key, value) => MapEntry(key, copy(value)));
    }
    if (value is List) return value.map(copy).toList();
    return value;
  }

  return Map<String, dynamic>.from(copy(source) as Map);
}
