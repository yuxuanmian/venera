import 'dart:convert';

import 'package:venera/foundation/comic_source/comic_source.dart';

import 'update_state.dart';

class TrackingFieldDiagnostic {
  const TrackingFieldDiagnostic(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String toString() => '$field: $reason';
}

class NormalizedTrackingFacts {
  const NormalizedTrackingFacts({
    this.state,
    this.sourceUnread,
    this.marker,
    this.metadata,
    this.droppedFields = const [],
    this.compatibilityNotes = const [],
  });

  final UpdateState? state;
  final bool? sourceUnread;
  final String? marker;
  final Map<String, dynamic>? metadata;
  final List<TrackingFieldDiagnostic> droppedFields;
  final List<String> compatibilityNotes;

  bool get hasUsableEvidence => state?.isUsable == true || marker != null;
}

/// Converts source-owned shapes into the host-owned tracking facts.
class TrackingNormalizer {
  const TrackingNormalizer._();

  static NormalizedTrackingFacts fromFavoriteUpdate(FavoriteUpdateHint hint) {
    final dropped = <TrackingFieldDiagnostic>[];
    final compatibility = <String>[];

    var state = hint.state == null
        ? null
        : UpdateState.fromJson(hint.state!.toJson());
    if (state == null && hint.updateTime != null) {
      state = UpdateState.fromJson({'updatedAt': hint.updateTime});
      compatibility.add('legacy updateTime adapted to state.updatedAt');
      if (state == null) {
        dropped.add(
          const TrackingFieldDiagnostic(
            'updateTime',
            'invalid RFC3339 timestamp',
          ),
        );
      }
    }
    if (hint.state != null && state == null) {
      dropped.add(const TrackingFieldDiagnostic('state', 'no usable fields'));
    }

    final sourceUnread = hint.sourceUnread ?? hint.isNew;
    if (hint.sourceUnread == null && hint.isNew != null) {
      compatibility.add('legacy isNew adapted to sourceUnread');
    }
    if (hint.sourceUnread != null &&
        hint.isNew != null &&
        hint.sourceUnread != hint.isNew) {
      compatibility.add('sourceUnread wins over conflicting legacy isNew');
    }

    String? marker;
    if (hint.marker != null) {
      final candidate = hint.marker!.trim();
      if (candidate.isEmpty) {
        dropped.add(const TrackingFieldDiagnostic('marker', 'empty'));
      } else if (utf8.encode(candidate).length > 4096) {
        dropped.add(
          const TrackingFieldDiagnostic('marker', 'exceeds 4096 UTF-8 bytes'),
        );
      } else {
        marker = candidate;
      }
    }

    final metadata = _normalizeMetadata(hint.metadata, dropped);
    return NormalizedTrackingFacts(
      state: state,
      sourceUnread: sourceUnread,
      marker: marker,
      metadata: metadata,
      droppedFields: List.unmodifiable(dropped),
      compatibilityNotes: List.unmodifiable(compatibility),
    );
  }

  static NormalizedTrackingFacts fromFavoriteUpdateJson(Object? value) {
    final hint = FavoriteUpdateHint.fromJson(value);
    if (hint == null) {
      return const NormalizedTrackingFacts(
        droppedFields: [
          TrackingFieldDiagnostic('favoriteUpdate', 'invalid object'),
        ],
      );
    }
    return fromFavoriteUpdate(hint);
  }

  static NormalizedTrackingFacts fromComicDetails(ComicDetails details) {
    final ids = details.chapters?.ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(10)
        .toList(growable: false);
    final state = UpdateState.fromJson({
      if (details.updateTime != null) 'updatedAt': details.updateTime,
      if (ids != null && ids.isNotEmpty) 'latestChapterId': ids.first,
      if (details.chapters != null) 'chapterCount': details.chapters!.length,
      if (ids != null && ids.isNotEmpty) 'recentChapterIds': ids,
    });
    return NormalizedTrackingFacts(state: state);
  }

  static Map<String, dynamic>? _normalizeMetadata(
    Map<String, dynamic>? metadata,
    List<TrackingFieldDiagnostic> dropped,
  ) {
    if (metadata == null) return null;
    try {
      final candidate = Map<String, dynamic>.from(metadata);
      if (utf8.encode(jsonEncode(candidate)).length > 4096) {
        dropped.add(
          const TrackingFieldDiagnostic('metadata', 'exceeds 4096 UTF-8 bytes'),
        );
        return null;
      }
      return candidate;
    } catch (_) {
      dropped.add(
        const TrackingFieldDiagnostic('metadata', 'not canonical JSON'),
      );
      return null;
    }
  }
}
