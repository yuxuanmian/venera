import 'package:venera/foundation/comic_source/comic_source.dart';

import 'update_state.dart';

class TrackingFieldDiagnostic {
  const TrackingFieldDiagnostic(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String toString() => '$field: $reason';
}

/// Host-owned tracking facts produced from a source-owned shape.
class NormalizedTrackingFacts {
  const NormalizedTrackingFacts({
    this.state,
    this.sourceUnread,
    this.metadata,
    this.droppedFields = const [],
    this.compatibilityNotes = const [],
  });

  final UpdateState? state;
  final bool? sourceUnread;
  final Map<String, dynamic>? metadata;
  final List<TrackingFieldDiagnostic> droppedFields;
  final List<String> compatibilityNotes;

  bool get hasUsableEvidence => state?.isUsable == true;
}

/// Converts source-owned shapes into the host-owned tracking facts.
class TrackingNormalizer {
  const TrackingNormalizer._();

  /// Normalizes a comic-details payload.
  ///
  /// This is the **only** entry point left.  The former list-level
  /// `favorites.updateCheck` normalization path was retired together with the
  /// application-side channel in feature 005 (FR-044); source configs still
  /// declare that channel for older app versions, but this build no longer
  /// reads it, so there is nothing here to convert a favorite-list hint into.
  static NormalizedTrackingFacts fromComicDetails(ComicDetails details) {
    final ids = details.chapters?.ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        // Matches the observation contract's cap and UpdateState.fromJson.
        .take(5)
        .toList(growable: false);
    final state = UpdateState.fromJson({
      if (details.updateTime != null) 'updatedAt': details.updateTime,
      if (ids != null && ids.isNotEmpty) 'latestChapterId': ids.first,
      if (details.chapters != null) 'chapterCount': details.chapters!.length,
      if (ids != null && ids.isNotEmpty) 'recentChapterIds': ids,
    });
    return NormalizedTrackingFacts(state: state);
  }
}
