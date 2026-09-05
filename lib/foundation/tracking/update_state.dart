import 'dart:convert';

/// Standard, source-scoped content evidence used by the App comparator.
///
/// Every field is optional because sources often expose only one reliable
/// fact. The object is usable when at least one field contains valid evidence.
class UpdateState {
  const UpdateState({
    this.updatedAt,
    this.latestChapterId,
    this.chapterCount,
    this.recentChapterIds,
  });

  final DateTime? updatedAt;
  final String? latestChapterId;
  final int? chapterCount;
  final List<String>? recentChapterIds;

  bool get isUsable =>
      updatedAt != null ||
      latestChapterId != null ||
      chapterCount != null ||
      (recentChapterIds?.isNotEmpty ?? false);

  /// Parses and independently sanitizes the known contract fields.
  ///
  /// Invalid fields are omitted while valid siblings remain usable. Unknown
  /// fields are intentionally ignored until the shared contract gives them
  /// comparison semantics.
  static UpdateState? fromJson(Object? value) {
    if (value is! Map) return null;

    DateTime? updatedAt;
    final rawUpdatedAt = value['updatedAt'];
    if (rawUpdatedAt is String) {
      updatedAt = _parseRfc3339(rawUpdatedAt);
    }

    String? latestChapterId;
    final rawLatestChapterId = value['latestChapterId'];
    if (rawLatestChapterId is String) {
      final candidate = rawLatestChapterId.trim();
      if (candidate.isNotEmpty && candidate.length <= 1024) {
        latestChapterId = candidate;
      }
    }

    int? chapterCount;
    final rawChapterCount = value['chapterCount'];
    if (rawChapterCount is int && rawChapterCount >= 0) {
      chapterCount = rawChapterCount;
    }

    List<String>? recentChapterIds;
    final rawRecentChapterIds = value['recentChapterIds'];
    if (rawRecentChapterIds is List) {
      final normalized = <String>[];
      final seen = <String>{};
      for (final rawId in rawRecentChapterIds) {
        if (rawId is! String) continue;
        final id = rawId.trim();
        if (id.isEmpty || id.length > 1024 || !seen.add(id)) continue;
        normalized.add(id);
        if (normalized.length == 10) break;
      }
      if (normalized.isNotEmpty) {
        recentChapterIds = List.unmodifiable(normalized);
      }
    }

    final state = UpdateState(
      updatedAt: updatedAt,
      latestChapterId: latestChapterId,
      chapterCount: chapterCount,
      recentChapterIds: recentChapterIds,
    );
    return state.isUsable ? state : null;
  }

  static DateTime? _parseRfc3339(String value) {
    final candidate = value.trim();
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$',
    ).hasMatch(candidate)) {
      return null;
    }
    try {
      return DateTime.parse(candidate).toUtc();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
      if (latestChapterId != null) 'latestChapterId': latestChapterId,
      if (chapterCount != null) 'chapterCount': chapterCount,
      if (recentChapterIds != null && recentChapterIds!.isNotEmpty)
        'recentChapterIds': List<String>.from(recentChapterIds!),
    };
  }

  String toCanonicalJson() => jsonEncode(toJson());

  UpdateState copyWith({
    DateTime? updatedAt,
    String? latestChapterId,
    int? chapterCount,
    List<String>? recentChapterIds,
  }) => UpdateState(
    updatedAt: updatedAt ?? this.updatedAt,
    latestChapterId: latestChapterId ?? this.latestChapterId,
    chapterCount: chapterCount ?? this.chapterCount,
    recentChapterIds: recentChapterIds ?? this.recentChapterIds,
  );

  @override
  bool operator ==(Object other) =>
      other is UpdateState &&
      other.updatedAt == updatedAt &&
      other.latestChapterId == latestChapterId &&
      other.chapterCount == chapterCount &&
      _listEquals(other.recentChapterIds, recentChapterIds);

  @override
  int get hashCode => Object.hash(
    updatedAt,
    latestChapterId,
    chapterCount,
    Object.hashAll(recentChapterIds ?? const <String>[]),
  );

  static bool _listEquals(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
