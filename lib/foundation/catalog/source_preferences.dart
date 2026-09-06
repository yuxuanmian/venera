import 'package:flutter/foundation.dart';

import '../appdata.dart';
import '../comic_source/comic_source.dart';
import 'models.dart';

typedef SourcePreferencesWriter = Future<void> Function(List<String>? value);
typedef SourcePreferencesUpdater =
    Future<List<String>?> Function(
      List<String>? Function(List<String>? current) mutation,
    );

/// User-owned source selection. It never starts or reloads a Runtime.
class SourcePreferences extends ChangeNotifier {
  SourcePreferences({List<String>? initial, this.writer, this.updater})
    : _enabled = initial == null ? null : normalizeSelection(initial),
      _lastAppdataValue = appdata.settings['enabledSources'] {
    appdata.settings.addListener(_onAppdataChanged);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onAppdataChanged);
    super.dispose();
  }

  List<String>? _enabled;
  Object? _lastAppdataValue;
  final SourcePreferencesWriter? writer;
  final SourcePreferencesUpdater? updater;
  Future<void> _mutationTail = Future<void>.value();

  List<String>? get enabledSources =>
      _enabled == null ? null : List.unmodifiable(_enabled!);

  /// Installs a value already persisted by the Catalog appdata commit. It is
  /// intentionally split from [replace] so publication can install the
  /// complete in-memory state without a second write or an await.
  void installSilently(Object? value) {
    _enabled = normalizeSelection(value);
    _lastAppdataValue = value;
  }

  void notifyChanged() => notifyListeners();

  void _onAppdataChanged() {
    final raw = appdata.settings['enabledSources'];
    // A null default means “not initialized”. Do not turn an explicit empty
    // selection into all sources merely because an unrelated setting changed.
    // A transition from a real list to null is intentional and is accepted.
    if (raw == null && _lastAppdataValue == null && _enabled != null) return;
    final next = normalizeOrPrevious(raw, _enabled);
    _lastAppdataValue = raw;
    if (!listEquals(_enabled, next)) {
      _enabled = next;
      notifyListeners();
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final current = _mutationTail.then((_) => action());
    _mutationTail = current.catchError((_) {});
    return current;
  }

  static List<String>? normalizeSelection(Object? value) {
    if (value == null) return null;
    if (value is! List ||
        value.any((item) => item is! String || item.isEmpty)) {
      throw const CatalogFormatException(
        'enabledSources must be a string array or null',
      );
    }
    final values = value.cast<String>();
    if (values.any(
      (key) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key),
    )) {
      throw const CatalogFormatException(
        'enabledSources contains an invalid source key',
      );
    }
    final result = values.toSet().toList()..sort();
    return List.unmodifiable(result);
  }

  static List<String>? normalizeOrPrevious(
    Object? value,
    List<String>? previous,
  ) {
    try {
      return normalizeSelection(value);
    } on CatalogFormatException {
      return previous;
    }
  }

  Set<String> effectiveKeys(CatalogIndex index) {
    final enabled = _enabled;
    // Null means the Catalog has not been initialized for user execution yet;
    // it must not silently grant every source eligibility.
    if (enabled == null) return <String>{};
    return enabled.toSet().intersection(index.keys);
  }

  /// Variant used by the UI while the index is represented by live parsed
  /// sources. It intersects against the manager's complete active list.
  Set<String> effectiveKeysFor(Iterable<String> allKeys) {
    final keys = allKeys.toSet();
    if (_enabled == null) return <String>{};
    return _enabled!.toSet().intersection(keys);
  }

  bool isEnabled(String key, CatalogIndex index) =>
      effectiveKeys(index).contains(key);

  Future<void> setEnabled(String key, bool enabled, CatalogIndex index) =>
      _enqueue(() async {
        if (index.find(key) == null) {
          throw CatalogFormatException(
            'source is not present in active catalog: $key',
          );
        }
        final current = _enabled ?? const <String>[];
        if (!enabled && _enabled == null) return;
        final next = List<String>.from(current)..sort();
        next.remove(key);
        if (enabled) next.add(key);
        next.sort();
        final normalized = List<String>.unmodifiable(
          next.toSet().cast<String>().toList()..sort(),
        );
        if (listEquals(_enabled, normalized)) return;
        final persisted = updater == null
            ? null
            : await updater!((latest) => _applyToggle(latest, key, enabled));
        if (updater == null) await writer?.call(normalized);
        final installed = persisted ?? normalized;
        if (!listEquals(_enabled, installed)) {
          _enabled = List<String>.from(installed);
          notifyListeners();
        }
      });

  Future<void> setEnabledFor(
    String key,
    bool enabled,
    Iterable<String> allKeys,
  ) => _enqueue(() async {
    final keys = allKeys.toSet();
    if (!keys.contains(key)) {
      throw CatalogFormatException(
        'source is not present in active catalog: $key',
      );
    }
    final current = _enabled ?? const <String>[];
    if (!enabled && _enabled == null) return;
    final next = List<String>.from(current)..sort();
    next.remove(key);
    if (enabled) next.add(key);
    next.sort();
    final normalized = List<String>.unmodifiable(next.toSet().toList()..sort());
    if (listEquals(_enabled, normalized)) return;
    final persisted = updater == null
        ? null
        : await updater!((latest) => _applyToggle(latest, key, enabled));
    if (updater == null) await writer?.call(normalized);
    final installed = persisted ?? normalized;
    if (!listEquals(_enabled, installed)) {
      _enabled = List<String>.from(installed);
      notifyListeners();
    }
  });

  Future<void> replace(Object? value) => _enqueue(() async {
    // A malformed value can arrive from an older sync/import payload. Keep
    // the last valid user choice instead of replacing it with an invalid
    // value (or surfacing a write failure after the document is unchanged).
    late final List<String>? normalized;
    try {
      normalized = normalizeSelection(value);
    } on CatalogFormatException {
      return;
    }
    if (listEquals(_enabled, normalized)) return;
    if (updater != null) {
      final persisted = await updater!((_) => normalized);
      _enabled = persisted == null ? null : List<String>.from(persisted);
    } else {
      await writer?.call(normalized);
      _enabled = normalized;
    }
    notifyListeners();
  });

  /// Applies removal only when an Authority transition actually succeeded.
  /// Local fallback and failed checks intentionally leave the user's intent.
  static List<String>? afterCatalogTransition({
    required List<String>? enabled,
    required CatalogIndex? oldIndex,
    required CatalogIndex newIndex,
    required bool isAuthorityTransition,
  }) {
    if (!isAuthorityTransition || enabled == null || oldIndex == null) {
      return enabled == null ? null : List.unmodifiable(enabled);
    }
    final removed = oldIndex.keys.difference(newIndex.keys);
    final next =
        enabled
            .where((key) => !removed.contains(key))
            .toSet()
            .cast<String>()
            .toList()
          ..sort();
    return List.unmodifiable(next);
  }
}

/// Creates the single preference adapter used by UI and local scanning.
/// Saving a selection is the only side effect; it never parses, downloads, or
/// reloads a source.
SourcePreferences appSourcePreferences() {
  late SourcePreferences preferences;
  preferences = SourcePreferences(
    initial: SourcePreferences.normalizeOrPrevious(
      appdata.settings['enabledSources'],
      null,
    ),
    writer: (value) async {
      await appdata.persistEnabledSources(value);
    },
    updater: (mutation) async => appdata.updateEnabledSources((raw) {
      final current = SourcePreferences.normalizeOrPrevious(
        raw,
        preferences._enabled,
      );
      return mutation(current);
    }),
  );
  return preferences;
}

Set<String> effectiveSourceKeys(Iterable<String> allKeys) {
  final raw = appdata.settings['enabledSources'];
  final normalized = SourcePreferences.normalizeOrPrevious(raw, null);
  final keys = allKeys.toSet();
  if (normalized == null) return <String>{};
  return normalized.toSet().intersection(keys);
}

bool isSourceEnabled(String key, [Iterable<String>? activeKeys]) {
  final keys = activeKeys ?? ComicSource.all().map((source) => source.key);
  return effectiveSourceKeys(keys).contains(key);
}

List<String> _applyToggle(List<String>? current, String key, bool enabled) {
  final next = List<String>.from(current ?? const <String>[]);
  next.remove(key);
  if (enabled) next.add(key);
  return SourcePreferences.normalizeSelection(next)!;
}
