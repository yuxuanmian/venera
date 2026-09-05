import 'dart:convert';

import 'observation.dart';

/// Developer-mode stages shown by the per-comic tracking trace.
enum TrackingDiagnosticStage {
  runtime,
  rawObservation,
  normalization,
  comparison,
  presentation,
  rejection,
}

class TrackingDiagnosticTrace {
  const TrackingDiagnosticTrace({
    required this.sourceKey,
    required this.fileName,
    required this.comicId,
    required this.at,
    this.runtime = const {},
    this.rawObservation = const {},
    this.normalization = const {},
    this.comparison = const {},
    this.presentation = const {},
    this.rejection,
  });

  final String sourceKey;
  final String fileName;
  final String comicId;
  final DateTime at;
  final Map<String, dynamic> runtime;
  final Map<String, dynamic> rawObservation;
  final Map<String, dynamic> normalization;
  final Map<String, dynamic> comparison;
  final Map<String, dynamic> presentation;
  final String? rejection;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'fileName': fileName,
    'comicId': comicId,
    'at': at.toUtc().toIso8601String(),
    'runtime': runtime,
    'rawObservation': rawObservation,
    'normalization': normalization,
    'comparison': comparison,
    'presentation': presentation,
    if (rejection != null) 'rejection': rejection,
  };
}

/// A bounded session-memory trace. It intentionally has no persistence
/// adapter and redacts secrets before retaining or exposing any value.
class TrackingDiagnostics {
  TrackingDiagnostics({this.maxEntries = 64, this.maxTraceBytes = 64 * 1024});

  final int maxEntries;
  final int maxTraceBytes;
  final List<Map<String, dynamic>> _entries = [];

  void record(TrackingDiagnosticTrace trace) {
    if (maxEntries <= 0 || maxTraceBytes <= 0) return;
    final bounded = _boundedMap(trace.toJson());
    _entries.add(bounded);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  void recordDecision({
    required TrackingObservation observation,
    required TrackingBaseline? previous,
    required ComparisonDecisionView comparison,
    required bool hasNewUpdate,
    required bool baselinePersisted,
  }) {
    record(
      TrackingDiagnosticTrace(
        sourceKey: observation.artifact.sourceKey,
        fileName: observation.artifact.fileName,
        comicId: observation.comicId,
        at: observation.observedAt,
        runtime: {
          'origin': observation.origin.name,
          'revision': observation.revision,
          'observationRevision': observation.revision,
        },
        rawObservation: {
          'origin': observation.origin.name,
          'sourceUnread': observation.sourceUnread,
          'marker': observation.marker,
          'metadata': observation.metadata,
        },
        normalization: {
          'state': observation.state?.toJson(),
          'accepted': observation.state?.toJson().keys.toList(growable: false),
          'dropped': observation.normalizationDrops,
          'compatibility': observation.compatibilityNotes,
        },
        comparison: comparison.toJson(previous),
        presentation: {
          'previousHasNewUpdate': previous?.hasNewUpdate ?? false,
          'contentChange': comparison.contentChange,
          'sourceUnread': observation.sourceUnread,
          'finalHasNewUpdate': hasNewUpdate,
          'baselinePersisted': baselinePersisted,
        },
      ),
    );
  }

  void recordRejection({
    required String sourceKey,
    required String fileName,
    required String comicId,
    required String reason,
    Map<String, dynamic> runtime = const {},
  }) {
    record(
      TrackingDiagnosticTrace(
        sourceKey: sourceKey,
        fileName: fileName,
        comicId: comicId,
        at: DateTime.now().toUtc(),
        runtime: runtime,
        rejection: redactText(reason),
      ),
    );
  }

  Map<String, dynamic>? latest(String sourceKey, String comicId) {
    for (final entry in _entries.reversed) {
      if (entry['sourceKey'] == sourceKey && entry['comicId'] == comicId) {
        return Map<String, dynamic>.unmodifiable(entry);
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get entries => List.unmodifiable(_entries);

  void clear() => _entries.clear();

  /// Applies the same redaction used by the in-memory trace to copied data.
  static dynamic redactForDisplay(dynamic value) => _redact(value);

  static String redactText(String value) {
    var result = value.replaceAll(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      '[REDACTED_URL]',
    );
    result = result.replaceAll(
      RegExp(
        r'(token|cookie|authorization|password|secret)\s*[=:]\s*[^\s]+',
        caseSensitive: false,
      ),
      '[REDACTED]',
    );
    return result.length <= 512 ? result : '${result.substring(0, 512)}…';
  }

  Map<String, dynamic> _boundedMap(Map<String, dynamic> source) {
    var value = _redact(source);
    if (value is! Map<String, dynamic>) {
      value = <String, dynamic>{'rejected': 'trace is not an object'};
    }
    if (utf8.encode(jsonEncode(value)).length <= maxTraceBytes) {
      return Map<String, dynamic>.unmodifiable(value);
    }
    final minimal = <String, dynamic>{
      'sourceKey': value['sourceKey'],
      'fileName': value['fileName'],
      'comicId': value['comicId'],
      'at': value['at'],
      'rejection': value['rejection'],
      'truncated': true,
    };
    return Map<String, dynamic>.unmodifiable(minimal);
  }

  static dynamic _redact(dynamic value, {String key = ''}) {
    final lowered = key.toLowerCase();
    if (lowered.contains('token') ||
        lowered.contains('cookie') ||
        lowered.contains('authorization') ||
        lowered.contains('password') ||
        lowered.contains('secret') ||
        lowered.contains('url') ||
        lowered.contains('rawpage') ||
        lowered.contains('responsebody')) {
      return '[REDACTED]';
    }
    if (value is String) {
      if (RegExp(r'https?://', caseSensitive: false).hasMatch(value)) {
        return '[REDACTED_URL]';
      }
      return value.length <= 512 ? value : '${value.substring(0, 512)}…';
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries.take(32)) {
        result['${entry.key}'] = _redact(entry.value, key: '${entry.key}');
      }
      return result;
    }
    if (value is Iterable) {
      return value
          .take(32)
          .map((item) => _redact(item))
          .toList(growable: false);
    }
    return value;
  }
}

/// Small view object that avoids making the diagnostics package depend on the
/// comparator implementation details.
class ComparisonDecisionView {
  const ComparisonDecisionView({
    required this.contentChange,
    required this.reason,
    this.selectedEvidence,
    this.currentValue,
  });

  final String contentChange;
  final String reason;
  final String? selectedEvidence;
  final Object? currentValue;

  Map<String, dynamic> toJson(TrackingBaseline? previous) => {
    'previousState': previous?.state?.toJson(),
    'previousMarker': previous?.marker,
    'currentValue': currentValue,
    'selectedEvidence': selectedEvidence,
    'result': contentChange,
    'reason': reason,
  };
}

final trackingDiagnostics = TrackingDiagnostics();
