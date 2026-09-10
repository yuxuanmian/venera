import 'dart:convert';
import 'dart:typed_data';

import 'failure_sanitizer.dart';
import 'models.dart';
import 'scan_limits.dart';

class ScanCodecException implements Exception {
  const ScanCodecException(this.code, [this.field, this.detail]);

  final String code;
  final String? field;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

class ComicScanEnvelope {
  const ComicScanEnvelope.observation(this.value) : failure = null;
  const ComicScanEnvelope.failure(this.failure) : value = null;

  final ScanObservation? value;
  final ScanFailure? failure;

  bool get isSuccess => value != null;
}

class ScanCollectionItem {
  const ScanCollectionItem({required this.comicId, required this.observation});

  final String comicId;
  final ScanObservation observation;
}

class ScanCollectionPage {
  ScanCollectionPage({
    required Iterable<ScanCollectionItem> items,
    required this.next,
  }) : items = List.unmodifiable(items);

  final List<ScanCollectionItem> items;
  final Object? next;

  bool get isTerminal => next == null;
}

/// Contract O/J value parsing. This class never consults old tracking state.
class ObservationCodec {
  const ObservationCodec({this.limits = const ScanLimits()});

  final ScanLimits limits;

  ScanObservation normalizeObservation(Object? raw) {
    if (raw is! Map) {
      throw const ScanCodecException('invalidObservation');
    }
    final updateRaw = raw['update'];
    UpdateDescriptor? update;
    if (updateRaw is Map) {
      update = _normalizeUpdate(updateRaw);
    }
    final sourceUnread = raw['sourceUnread'] is bool
        ? raw['sourceUnread'] as bool
        : null;
    final result = ScanObservation(
      update: update == null || update.isEmpty ? null : update,
      sourceUnread: sourceUnread,
    );
    if (result.isEmpty) throw const ScanCodecException('emptyObservation');
    return result;
  }

  ComicScanEnvelope decodeComicEnvelope(Object? raw) {
    final safe = preflightJson(raw, label: 'comic result');
    if (safe is! Map) {
      throw const ScanCodecException('invalidComicEnvelope');
    }
    final observationRaw = safe['observation'];
    final failureRaw = safe['failure'];
    final hasObservation = observationRaw != null;
    final hasFailure = failureRaw != null;
    if (hasObservation && hasFailure) {
      throw const ScanCodecException('payloadXor');
    }
    if (hasObservation) {
      return ComicScanEnvelope.observation(
        normalizeObservation(observationRaw),
      );
    }
    if (hasFailure) {
      if (failureRaw is! Map) {
        throw const ScanCodecException('invalidFailure');
      }
      return ComicScanEnvelope.failure(
        FailureSanitizer.sanitize(failureRaw, limits: limits),
      );
    }
    throw const ScanCodecException('emptyEnvelope');
  }

  /// Adapter/transport failures use a small envelope outside the successful
  /// collection-page shape.  Keeping this decoder separate makes it
  /// impossible to turn a failure into an empty page or to emit an unknown
  /// comic item.
  ScanFailure? decodeCollectionFailure(Object? raw) {
    final safe = preflightJson(raw, label: 'collection failure');
    if (safe is! Map || !safe.containsKey('failure')) return null;
    if (safe.containsKey('items') || safe.containsKey('next')) {
      throw const ScanCodecException('collectionFailureEnvelope');
    }
    final failure = safe['failure'];
    if (failure is! Map) throw const ScanCodecException('invalidFailure');
    return FailureSanitizer.sanitize(failure, limits: limits);
  }

  ScanCollectionPage decodeCollectionPage(
    Object? raw, {
    Set<String>? seenComicIds,
  }) {
    final safe = preflightJson(raw, label: 'collection page');
    if (safe is! Map ||
        !safe.containsKey('items') ||
        !safe.containsKey('next')) {
      throw const ScanCodecException('missingNext');
    }
    if (safe.containsKey('failure')) {
      throw const ScanCodecException('collectionFailureEnvelope');
    }
    final rawItems = safe['items'];
    if (rawItems is! List || rawItems.length > limits.maxPageItems) {
      throw const ScanCodecException('invalidPageItems');
    }
    final ids = <String>{};
    final items = <ScanCollectionItem>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map ||
          rawItem['comicId'] is! String ||
          rawItem['observation'] is! Map) {
        throw const ScanCodecException('invalidPageItem');
      }
      final comicId = (rawItem['comicId'] as String).trim();
      if (!_validScalar(comicId, limits.maxIdScalars) ||
          !ids.add(comicId) ||
          seenComicIds?.contains(comicId) == true) {
        throw const ScanCodecException('duplicateComicId', 'comicId');
      }
      items.add(
        ScanCollectionItem(
          comicId: comicId,
          observation: normalizeObservation(rawItem['observation']),
        ),
      );
    }
    final page = ScanCollectionPage(items: items, next: safe['next']);
    if (_utf8Length(jsonEncode(safe)) > limits.maxPageJsonBytes) {
      throw const ScanCodecException('pageTooLarge');
    }
    return page;
  }

  /// Performs the pre-bridge-compatible JSON safety checks again on the Dart
  /// side. The returned graph is detached and contains only plain values.
  Object? preflightJson(Object? value, {String label = 'value'}) {
    final active = Set<Object>.identity();
    Object? copy(Object? current, int depth) {
      if (depth > limits.maxCursorDepth) {
        throw ScanCodecException('jsonTooDeep', label);
      }
      if (current == null || current is String || current is bool) {
        return current;
      }
      if (current is int) {
        if (current.abs() > ScanLimits.safeIntegerMax) {
          throw ScanCodecException('unsafeInteger', label);
        }
        return current;
      }
      if (current is double) {
        if (!current.isFinite) {
          throw ScanCodecException('nonFiniteNumber', label);
        }
        return current;
      }
      if (current is num) {
        if (!current.isFinite) {
          throw ScanCodecException('nonFiniteNumber', label);
        }
        return current;
      }
      if (current is Function ||
          current is BigInt ||
          current is DateTime ||
          current is Uint8List) {
        throw ScanCodecException('nonJsonValue', label);
      }
      if (current is List) {
        if (!active.add(current)) {
          throw ScanCodecException('cycle', label);
        }
        try {
          return [for (final item in current) copy(item, depth + 1)];
        } finally {
          active.remove(current);
        }
      }
      if (current is Map) {
        if (!active.add(current)) {
          throw ScanCodecException('cycle', label);
        }
        try {
          final result = <String, Object?>{};
          for (final entry in current.entries) {
            if (entry.key is! String) {
              throw ScanCodecException('nonStringKey', label);
            }
            result[entry.key as String] = copy(entry.value, depth + 1);
          }
          return result;
        } finally {
          active.remove(current);
        }
      }
      throw ScanCodecException('nonJsonValue', label);
    }

    final result = copy(value, 0);
    if (_utf8Length(jsonEncode(result)) > limits.maxCursorJsonBytes &&
        label == 'cursor') {
      throw ScanCodecException('jsonTooLarge', label);
    }
    if (_utf8Length(jsonEncode(result)) > limits.maxPageJsonBytes &&
        label != 'cursor') {
      throw ScanCodecException('pageTooLarge', label);
    }
    return result;
  }

  String canonicalJson(Object? value) {
    final safe = preflightJson(value, label: 'cursor');
    String encode(Object? current) {
      if (current is Map) {
        final keys = current.keys.cast<String>().toList()..sort();
        return '{${keys.map((key) => '${jsonEncode(key)}:${encode(current[key])}').join(',')}}';
      }
      if (current is List) return '[${current.map(encode).join(',')}]';
      return jsonEncode(current);
    }

    return encode(safe);
  }

  UpdateDescriptor _normalizeUpdate(Map raw) {
    String? updatedAt;
    final rawUpdatedAt = raw['updatedAt'];
    if (rawUpdatedAt is String) {
      final candidate = rawUpdatedAt.trim();
      if (_isValidUpdatedAt(candidate)) updatedAt = candidate;
    }

    String? latestChapterId;
    final rawLatest = raw['latestChapterId'];
    if (rawLatest is String) {
      final candidate = rawLatest.trim();
      if (_validScalar(candidate, limits.maxIdScalars)) {
        latestChapterId = candidate;
      }
    }

    int? chapterCount;
    final rawCount = raw['chapterCount'];
    if (rawCount is num &&
        rawCount is! bool &&
        rawCount.isFinite &&
        rawCount == rawCount.truncate()) {
      final candidate = rawCount.toInt();
      if (candidate >= 0 && candidate <= ScanLimits.safeIntegerMax) {
        chapterCount = candidate;
      }
    }

    final recent = <String>[];
    final rawRecent = raw['recentChapterIds'];
    if (rawRecent is List) {
      for (final value in rawRecent) {
        if (value is! String) continue;
        final candidate = value.trim();
        if (!_validScalar(candidate, limits.maxIdScalars) ||
            recent.contains(candidate)) {
          continue;
        }
        recent.add(candidate);
        if (recent.length == 5) break;
      }
    }
    return UpdateDescriptor(
      updatedAt: updatedAt,
      latestChapterId: latestChapterId,
      chapterCount: chapterCount,
      recentChapterIds: recent,
    );
  }

  bool _validScalar(String value, int maxScalars) =>
      value.isNotEmpty && value.runes.length <= maxScalars;

  bool _isValidUpdatedAt(String value) {
    final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (date != null) {
      return _validDate(
        int.parse(date.group(1)!),
        int.parse(date.group(2)!),
        int.parse(date.group(3)!),
      );
    }
    final time = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$',
    ).firstMatch(value);
    if (time == null) return false;
    final offset = time.group(7)!;
    final offsetHours = offset == 'Z' ? 0 : int.parse(offset.substring(1, 3));
    final offsetMinutes = offset == 'Z' ? 0 : int.parse(offset.substring(4, 6));
    return _validDate(
          int.parse(time.group(1)!),
          int.parse(time.group(2)!),
          int.parse(time.group(3)!),
        ) &&
        int.parse(time.group(4)!) < 24 &&
        int.parse(time.group(5)!) < 60 &&
        int.parse(time.group(6)!) < 60 &&
        offsetHours <= 23 &&
        offsetMinutes < 60;
  }

  bool _validDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    final days = <int>[
      31,
      leap ? 29 : 28,
      31,
      30,
      31,
      30,
      31,
      31,
      30,
      31,
      30,
      31,
    ];
    return day <= days[month - 1];
  }

  int _utf8Length(String value) => utf8.encode(value).length;
}

final observationCodec = const ObservationCodec();
