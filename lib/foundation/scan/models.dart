import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

enum ScanProducer { comic, collection }

extension ScanProducerValue on ScanProducer {
  String get value => switch (this) {
    ScanProducer.comic => 'comic',
    ScanProducer.collection => 'collection',
  };

  static ScanProducer? parse(Object? value) {
    return switch (value) {
      'comic' => ScanProducer.comic,
      'collection' => ScanProducer.collection,
      _ => null,
    };
  }
}

enum ScanScopeStatus { running, completed, failed, canceled, interrupted }

extension ScanScopeStatusValue on ScanScopeStatus {
  String get value => name;

  static ScanScopeStatus? parse(Object? value) {
    for (final candidate in ScanScopeStatus.values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

enum ScanProgressPhase { idle, discovering, running, canceling, finished }

extension ScanProgressPhaseValue on ScanProgressPhase {
  String get value => name;
}

enum ScanSourceSkipReason { absent, invalid, disabled, notLoggedIn }

extension ScanSourceSkipReasonValue on ScanSourceSkipReason {
  String get value => name;
}

enum FullScanDisposition { completed, canceled, failed, alreadyRunning }

extension FullScanDispositionValue on FullScanDisposition {
  String get value => name;
}

/// Facts reported by a source. This class intentionally has no update
/// decision fields such as marker, baseline, or hasNewUpdate.
class UpdateDescriptor {
  UpdateDescriptor({
    this.updatedAt,
    this.latestChapterId,
    this.chapterCount,
    Iterable<String> recentChapterIds = const [],
  }) : recentChapterIds = List.unmodifiable(recentChapterIds);

  final String? updatedAt;
  final String? latestChapterId;
  final int? chapterCount;
  final List<String> recentChapterIds;

  bool get isEmpty =>
      updatedAt == null &&
      latestChapterId == null &&
      chapterCount == null &&
      recentChapterIds.isEmpty;

  Map<String, dynamic> toJson() => {
    if (updatedAt != null) 'updatedAt': updatedAt,
    if (latestChapterId != null) 'latestChapterId': latestChapterId,
    if (chapterCount != null) 'chapterCount': chapterCount,
    if (recentChapterIds.isNotEmpty)
      'recentChapterIds': List<String>.from(recentChapterIds),
  };

  @override
  bool operator ==(Object other) =>
      other is UpdateDescriptor &&
      other.updatedAt == updatedAt &&
      other.latestChapterId == latestChapterId &&
      other.chapterCount == chapterCount &&
      _listEquals(other.recentChapterIds, recentChapterIds);

  @override
  int get hashCode => Object.hash(
    updatedAt,
    latestChapterId,
    chapterCount,
    Object.hashAll(recentChapterIds),
  );
}

class ScanObservation {
  ScanObservation({this.update, this.sourceUnread});

  final UpdateDescriptor? update;
  final bool? sourceUnread;

  bool get isEmpty => update == null && sourceUnread == null;

  Map<String, dynamic> toJson() => {
    if (update != null && !update!.isEmpty) 'update': update!.toJson(),
    if (sourceUnread != null) 'sourceUnread': sourceUnread,
  };

  @override
  bool operator ==(Object other) =>
      other is ScanObservation &&
      other.update == update &&
      other.sourceUnread == sourceUnread;

  @override
  int get hashCode => Object.hash(update, sourceUnread);
}

class ScanFailure {
  const ScanFailure({
    this.httpStatus,
    this.sourceCode,
    this.exceptionType,
    this.message,
    this.retryAfter,
  });

  final int? httpStatus;
  final String? sourceCode;
  final String? exceptionType;
  final String? message;
  final String? retryAfter;

  Map<String, dynamic> toJson() => {
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (sourceCode != null) 'sourceCode': sourceCode,
    if (exceptionType != null) 'exceptionType': exceptionType,
    if (message != null) 'message': message,
    if (retryAfter != null) 'retryAfter': retryAfter,
  };

  factory ScanFailure.fromJson(Object? value) {
    if (value is! Map) {
      return const ScanFailure(
        message: 'Scan failed without diagnostic details',
      );
    }
    int? status;
    final rawStatus = value['httpStatus'];
    if (rawStatus is int) status = rawStatus;
    return ScanFailure(
      httpStatus: status,
      sourceCode: value['sourceCode'] is String
          ? value['sourceCode'] as String
          : null,
      exceptionType: value['exceptionType'] is String
          ? value['exceptionType'] as String
          : null,
      message: value['message'] is String ? value['message'] as String : null,
      retryAfter: value['retryAfter'] is String
          ? value['retryAfter'] as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScanFailure &&
      other.httpStatus == httpStatus &&
      other.sourceCode == sourceCode &&
      other.exceptionType == exceptionType &&
      other.message == message &&
      other.retryAfter == retryAfter;

  @override
  int get hashCode =>
      Object.hash(httpStatus, sourceCode, exceptionType, message, retryAfter);
}

/// A result has exactly one payload. The factories make the invariant easy
/// to preserve at every call site and at the persistence boundary.
class ScanItemResult {
  ScanItemResult._({
    required this.attemptId,
    required this.scopeAttemptId,
    required this.sourceKey,
    required this.comicId,
    required this.producer,
    required this.definitionRevision,
    required this.observedAt,
    this.accessContextKey,
    this.observation,
    this.failure,
  }) : assert((observation == null) != (failure == null));

  factory ScanItemResult.observed({
    required String attemptId,
    required String scopeAttemptId,
    required String sourceKey,
    required String comicId,
    required ScanProducer producer,
    required String definitionRevision,
    required String observedAt,
    String? accessContextKey,
    required ScanObservation observation,
  }) {
    if (observation.isEmpty) throw ArgumentError('observation is empty');
    return ScanItemResult._(
      attemptId: attemptId,
      scopeAttemptId: scopeAttemptId,
      sourceKey: sourceKey,
      comicId: comicId,
      producer: producer,
      definitionRevision: definitionRevision,
      observedAt: observedAt,
      accessContextKey: accessContextKey,
      observation: observation,
    );
  }

  factory ScanItemResult.failed({
    required String attemptId,
    required String scopeAttemptId,
    required String sourceKey,
    required String comicId,
    required ScanProducer producer,
    required String definitionRevision,
    required String observedAt,
    String? accessContextKey,
    required ScanFailure failure,
  }) {
    return ScanItemResult._(
      attemptId: attemptId,
      scopeAttemptId: scopeAttemptId,
      sourceKey: sourceKey,
      comicId: comicId,
      producer: producer,
      definitionRevision: definitionRevision,
      observedAt: observedAt,
      accessContextKey: accessContextKey,
      failure: failure,
    );
  }

  final String attemptId;
  final String scopeAttemptId;
  final String sourceKey;
  final String comicId;
  final String? accessContextKey;
  final ScanProducer producer;
  final String definitionRevision;
  final String observedAt;
  final ScanObservation? observation;
  final ScanFailure? failure;

  bool get isSuccess => observation != null;

  Map<String, dynamic> toJson() => {
    'attemptId': attemptId,
    'scopeAttemptId': scopeAttemptId,
    'sourceKey': sourceKey,
    'comicId': comicId,
    if (accessContextKey != null) 'accessContextKey': accessContextKey,
    'producer': producer.value,
    'definitionRevision': definitionRevision,
    'observedAt': observedAt,
    if (observation != null) 'observation': observation!.toJson(),
    if (failure != null) 'failure': failure!.toJson(),
  };

  factory ScanItemResult.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid scan item result');
    final producer = ScanProducerValue.parse(value['producer']);
    if (producer == null ||
        value['attemptId'] is! String ||
        value['scopeAttemptId'] is! String ||
        value['sourceKey'] is! String ||
        value['comicId'] is! String ||
        value['definitionRevision'] is! String ||
        value['observedAt'] is! String) {
      throw const FormatException('invalid scan item identity');
    }
    final hasObservation = value['observation'] is Map;
    final hasFailure = value['failure'] is Map;
    if (hasObservation == hasFailure) {
      throw const FormatException('scan item payload must be xor');
    }
    final common = {
      'attemptId': value['attemptId'] as String,
      'scopeAttemptId': value['scopeAttemptId'] as String,
      'sourceKey': value['sourceKey'] as String,
      'comicId': value['comicId'] as String,
      'producer': producer,
      'definitionRevision': value['definitionRevision'] as String,
      'observedAt': value['observedAt'] as String,
      'accessContextKey': value['accessContextKey'] is String
          ? value['accessContextKey'] as String
          : null,
    };
    if (hasObservation) {
      final observation = _observationFromJson(value['observation']);
      return ScanItemResult.observed(
        attemptId: common['attemptId'] as String,
        scopeAttemptId: common['scopeAttemptId'] as String,
        sourceKey: common['sourceKey'] as String,
        comicId: common['comicId'] as String,
        producer: producer,
        definitionRevision: common['definitionRevision'] as String,
        observedAt: common['observedAt'] as String,
        accessContextKey: common['accessContextKey'] as String?,
        observation: observation,
      );
    }
    return ScanItemResult.failed(
      attemptId: common['attemptId'] as String,
      scopeAttemptId: common['scopeAttemptId'] as String,
      sourceKey: common['sourceKey'] as String,
      comicId: common['comicId'] as String,
      producer: producer,
      definitionRevision: common['definitionRevision'] as String,
      observedAt: common['observedAt'] as String,
      accessContextKey: common['accessContextKey'] as String?,
      failure: ScanFailure.fromJson(value['failure']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScanItemResult && _jsonEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

class ScanSourceSkip {
  const ScanSourceSkip({
    required this.sourceKey,
    required this.reason,
    this.message,
  });

  final String sourceKey;
  final ScanSourceSkipReason reason;
  final String? message;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'reason': reason.value,
    if (message != null) 'message': message,
  };
}

class ScanProgress {
  ScanProgress({
    this.phase = ScanProgressPhase.idle,
    this.discoveredWorks = 0,
    this.activeWorks = 0,
    this.succeededWorks = 0,
    this.failedWorks = 0,
    this.canceledWorks = 0,
    this.persistedItems = 0,
    Iterable<ScanSourceSkip> skippedSources = const [],
  }) : skippedSources = List.unmodifiable(skippedSources);

  final ScanProgressPhase phase;
  final int discoveredWorks;
  final int activeWorks;
  final int succeededWorks;
  final int failedWorks;
  final int canceledWorks;
  final int persistedItems;
  final List<ScanSourceSkip> skippedSources;

  ScanProgress copyWith({
    ScanProgressPhase? phase,
    int? discoveredWorks,
    int? activeWorks,
    int? succeededWorks,
    int? failedWorks,
    int? canceledWorks,
    int? persistedItems,
    Iterable<ScanSourceSkip>? skippedSources,
  }) => ScanProgress(
    phase: phase ?? this.phase,
    discoveredWorks: discoveredWorks ?? this.discoveredWorks,
    activeWorks: activeWorks ?? this.activeWorks,
    succeededWorks: succeededWorks ?? this.succeededWorks,
    failedWorks: failedWorks ?? this.failedWorks,
    canceledWorks: canceledWorks ?? this.canceledWorks,
    persistedItems: persistedItems ?? this.persistedItems,
    skippedSources: skippedSources ?? this.skippedSources,
  );

  Map<String, dynamic> toJson() => {
    'phase': phase.value,
    'discoveredWorks': discoveredWorks,
    'activeWorks': activeWorks,
    'succeededWorks': succeededWorks,
    'failedWorks': failedWorks,
    'canceledWorks': canceledWorks,
    'persistedItems': persistedItems,
    'skippedSources': skippedSources.map((item) => item.toJson()).toList(),
  };
}

class FullScanSummary {
  const FullScanSummary({
    required this.disposition,
    required this.progress,
    this.errorMessage,
  });

  final FullScanDisposition disposition;
  final ScanProgress progress;
  final String? errorMessage;

  Map<String, dynamic> toJson() => {
    'disposition': disposition.value,
    'progress': progress.toJson(),
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

enum ScanControlReason {
  userCanceled,
  cacheInvalidated,
  sourceInvalidated,
  accountChanged,
}

extension ScanControlReasonValue on ScanControlReason {
  String get value => name;
}

/// Host-only control flow. It must never be serialized as a source failure.
class ScanControlException implements Exception {
  const ScanControlException(this.reason, [this.detail]);

  final ScanControlReason reason;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'Scan canceled: ${reason.value}'
      : 'Scan canceled: ${reason.value}: $detail';
}

/// Storage errors are deliberately distinct from acquisition failures.
class ScanStorageException implements Exception {
  const ScanStorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'Scan storage error: $message';
}

class ScanResultConflictException implements Exception {
  const ScanResultConflictException(this.message);

  final String message;

  @override
  String toString() => 'Scan result conflict: $message';
}

String newScanUuidV4() => const Uuid().v4();

/// UUID v5 with the Scope UUID as namespace. The uuid package intentionally
/// does not expose every version helper consistently across its releases, so
/// the small RFC 4122 operation is kept local and deterministic.
String scanUuidV5(String namespace, String name) {
  final normalized = namespace.replaceAll('-', '');
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(normalized)) {
    throw ArgumentError.value(namespace, 'namespace', 'must be a UUID');
  }
  final namespaceBytes = <int>[];
  for (var index = 0; index < normalized.length; index += 2) {
    namespaceBytes.add(
      int.parse(normalized.substring(index, index + 2), radix: 16),
    );
  }
  final digest = List<int>.from(
    sha1.convert([...namespaceBytes, ...utf8.encode(name)]).bytes,
  );
  digest[6] = (digest[6] & 0x0f) | 0x50;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  final hex = digest
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _jsonEquals(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

ScanObservation _observationFromJson(Object? value) {
  if (value is! Map) {
    throw const FormatException('invalid scan observation');
  }
  UpdateDescriptor? update;
  final rawUpdate = value['update'];
  if (rawUpdate != null) {
    if (rawUpdate is! Map) {
      throw const FormatException('invalid scan update');
    }
    final recent = rawUpdate['recentChapterIds'];
    if (recent != null && recent is! List) {
      throw const FormatException('invalid recent chapter ids');
    }
    final recentIds = <String>[];
    if (recent is List) {
      for (final id in recent) {
        if (id is! String) {
          throw const FormatException('invalid recent chapter id');
        }
        recentIds.add(id);
      }
    }
    final chapterCount = rawUpdate['chapterCount'];
    if (chapterCount != null && chapterCount is! int) {
      throw const FormatException('invalid chapter count');
    }
    for (final key in const ['updatedAt', 'latestChapterId']) {
      final field = rawUpdate[key];
      if (field != null && field is! String) {
        throw FormatException('invalid update field: $key');
      }
    }
    update = UpdateDescriptor(
      updatedAt: rawUpdate['updatedAt'] as String?,
      latestChapterId: rawUpdate['latestChapterId'] as String?,
      chapterCount: chapterCount as int?,
      recentChapterIds: recentIds,
    );
    if (update.isEmpty) update = null;
  }
  final sourceUnread = value['sourceUnread'];
  if (sourceUnread != null && sourceUnread is! bool) {
    throw const FormatException('invalid source unread flag');
  }
  final observation = ScanObservation(
    update: update,
    sourceUnread: sourceUnread as bool?,
  );
  if (observation.isEmpty) {
    throw const FormatException('scan observation is empty');
  }
  return observation;
}
