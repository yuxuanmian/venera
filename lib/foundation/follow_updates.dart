import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';

export 'follow_update_availability.dart';
export 'follow_update_schedule.dart';

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;
  final bool isBatchWork;
  final String? currentLabel;
  final bool containsBatchWork;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
    this.isBatchWork = false,
    this.currentLabel,
    this.containsBatchWork = false,
  ]);
}

bool get followUpdatesEnabled =>
    appdata.settings['followUpdatesEnabled'] == true;

List<NetworkFavoriteFolderRef> getFollowUpdateFolders() {
  final enabled = appdata.settings['favorites'];
  if (enabled is! List) return const [];
  final cache = NetworkFavoriteCacheManager();
  return cache.getAllCachedFolders().where((folder) {
    final source = ComicSource.find(folder.sourceKey);
    return enabled.contains(folder.sourceKey) &&
        isSourceEnabled(folder.sourceKey) &&
        source?.isLogged == true &&
        source?.loadComicInfo != null &&
        cache.countCachedComics(folder) > 0;
  }).toList();
}

/// The scanner is unavailable during the 003 retirement window.
///
/// Keep the signature so existing UI callers can continue to distinguish an
/// empty historical cache from active work. No database or source lookup is
/// allowed here: old pending rows are historical data, not live work.
bool hasPendingFollowUpdateWork({
  required FollowUpdateMode mode,
  Iterable<NetworkFavoriteFolderRef>? folders,
  DateTime? now,
}) => false;

/// Progress of a background follow-up scan run. The type remains part of the
/// page shell so historical state can be displayed without manufacturing a
/// new scan result.
class BaselineStatus {
  const BaselineStatus({
    required this.isRunning,
    required this.total,
    required this.completed,
    required this.errors,
    required this.updated,
    this.currentComic,
    this.isBatchWork = false,
    this.currentLabel,
    this.containsBatchWork = false,
  });

  final bool isRunning;
  final int total;
  final int completed;
  final int errors;
  final int updated;
  final String? currentComic;
  final bool isBatchWork;
  final String? currentLabel;
  final bool containsBatchWork;
}

/// Historical selection values retained for compatibility with the page
/// shell. They do not schedule work while the scanner is unavailable.
enum FollowUpdateMode { missing, regular, force }

Future<String> getUpdatedComicsAsJsonInFolders(
  Iterable<NetworkFavoriteFolderRef> folders,
) async {
  final updatedComics = NetworkFavoriteCacheManager().getUpdatedComicsInFolders(
    folders,
  );
  final jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'chapterCount': c.chapterCount,
          'type': c.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
