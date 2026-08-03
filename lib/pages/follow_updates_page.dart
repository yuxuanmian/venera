import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

NetworkFavoriteFolderRef? get _followFolder =>
    NetworkFavoriteFolderRef.tryFromJson(
      appdata.settings['followUpdatesFolder'],
    );

String _folderLabel(NetworkFavoriteFolderRef folder) {
  final source = ComicSource.find(folder.sourceKey);
  return '${source?.name ?? folder.sourceKey} · ${folder.title ?? folder.folderId}';
}

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  void getCount() {
    final folder = _followFolder;
    _count = folder == null
        ? 0
        : NetworkFavoriteCacheManager().countUpdates(folder);
  }

  void updateCount() => setState(getCount);

  @override
  void initState() {
    super.initState();
    getCount();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => context.to(() => const FollowUpdatesPage()),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Follow Updates'.tl, style: ts.s18)),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (_count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 16, left: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Text(
                    '@c updates'.tlParams({'c': _count}),
                    style: ts.s16,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  List<FavoriteItemWithUpdateInfo> updatedComics = [];
  List<FavoriteItemWithUpdateInfo> allComics = [];

  NetworkFavoriteFolderRef? get folder => _followFolder;

  @override
  void initState() {
    super.initState();
    updateComics();
  }

  void sortComics() {
    allComics.sort((a, b) {
      final aTime = a.updateTime;
      final bTime = b.updateTime;
      if (aTime == null) return bTime == null ? 0 : 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Follow Updates'.tl)),
        folder == null ? buildNotConfigured(context) : buildConfigured(context),
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        buildUpdatedComics(),
        buildAllComics(),
      ],
    ),
  );

  Widget buildNotConfigured(BuildContext context) => SliverToBoxAdapter(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('Not Configured'.tl),
          ),
          Text(
            'Choose a remote favorite folder to follow updates.'.tl,
            style: ts.s16,
          ).paddingHorizontal(16),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: showSelector,
            child: Text('Choose Folder'.tl),
          ).paddingHorizontal(16).toAlign(Alignment.centerRight),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );

  Widget buildConfigured(BuildContext context) {
    final selected = folder!;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.stars_outlined),
              title: Text(_folderLabel(selected)),
            ),
            Text(
              'Automatic update checking enabled.'.tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            Text(
              'The app will check cached favorites at most once a day.'.tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text('Change Folder'.tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text('Check Now'.tl),
                ),
                const SizedBox(width: 16),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.update),
              const SizedBox(width: 8),
              Text('Updates'.tl, style: ts.s18),
              const Spacer(),
              if (updatedComics.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all),
                  onPressed: () => showConfirmDialog(
                    context: App.rootContext,
                    title: 'Mark all as read'.tl,
                    content: 'Do you want to mark all as read?'.tl,
                    onConfirm: () {
                      final selected = folder;
                      if (selected != null) {
                        for (final comic in updatedComics) {
                          NetworkFavoriteCacheManager().markAsRead(
                            selected,
                            comic.id,
                          );
                        }
                      }
                      updateFollowUpdatesUI();
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      if (updatedComics.isNotEmpty)
        SliverToBoxAdapter(
          child: Text(
            'Updates are marked read when you start reading.'.tl,
          ).paddingHorizontal(16).paddingVertical(4),
        ),
      if (updatedComics.isNotEmpty)
        SliverGridComics(comics: updatedComics)
      else
        SliverToBoxAdapter(
          child: Text(
            'No updates found'.tl,
          ).paddingHorizontal(16).paddingVertical(8),
        ),
    ],
  );

  Widget buildAllComics() => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.list),
              const SizedBox(width: 8),
              Text('All Comics'.tl, style: ts.s18),
            ],
          ),
        ),
      ),
      SliverGridComics(comics: allComics),
    ],
  );

  Future<List<NetworkFavoriteFolder>> _loadAvailableFolders() async {
    final enabled = List<String>.from(appdata.settings['favorites'] as List);
    final data = enabled.map(getFavoriteDataOrNull).whereType<FavoriteData>();
    for (final favoriteData in data) {
      final source = ComicSource.find(favoriteData.key);
      if (source?.isLogged == true) {
        await NetworkFavoriteCacheManager().refreshFolders(favoriteData);
      }
    }
    return NetworkFavoriteCacheManager().getAllCachedFolders().where((folder) {
      return enabled.contains(folder.sourceKey) &&
          ComicSource.find(folder.sourceKey)?.isLogged == true;
    }).toList();
  }

  Future<void> showSelector() async {
    final loading = showLoadingDialog(
      App.rootContext,
      message: 'Loading remote favorite folders...'.tl,
    );
    final folders = await _loadAvailableFolders();
    loading.close();
    if (!mounted) return;
    if (folders.isEmpty) {
      context.showMessage(message: 'No remote folders available'.tl);
      return;
    }
    NetworkFavoriteFolderRef? selected = folder;
    await showDialog(
      context: App.rootContext,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ContentDialog(
          title: 'Choose Folder'.tl,
          content: SizedBox(
            width: 480,
            child: RadioGroup<NetworkFavoriteFolderRef>(
              groupValue: selected,
              onChanged: (value) => setDialogState(() => selected = value),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final candidate in folders)
                    RadioListTile<NetworkFavoriteFolderRef>(
                      value: candidate,
                      title: Text(_folderLabel(candidate)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (folder != null)
              TextButton(
                onPressed: () {
                  disable();
                  context.pop();
                },
                child: Text('Disable'.tl),
              ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () {
                      context.pop();
                      setFolder(selected!);
                    },
              child: Text('Confirm'.tl),
            ),
          ],
        ),
      ),
    );
  }

  void disable() {
    appdata.settings['followUpdatesFolder'] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  Future<void> setFolder(NetworkFavoriteFolderRef selected) async {
    FollowUpdatesService.cancelChecking();
    final comics = NetworkFavoriteCacheManager().getComicsWithUpdatesInfo(
      selected,
    );
    if (comics.isNotEmpty) {
      final loading = showLoadingDialog(
        App.rootContext,
        withProgress: true,
        cancelButtonText: 'Cancel'.tl,
        message: 'Updating comics...'.tl,
      );
      await for (final progress in updateFolder(selected, true)) {
        loading.setProgress(
          progress.total == 0 ? 1 : progress.current / progress.total,
        );
      }
      loading.close();
    }
    appdata.settings['followUpdatesFolder'] = selected.toJson();
    await appdata.saveData();
    updateFollowUpdatesUI();
  }

  Future<void> checkNow() async {
    final selected = folder;
    if (selected == null) return;
    FollowUpdatesService.cancelChecking();
    final loading = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: 'Cancel'.tl,
      message: 'Updating comics...'.tl,
    );
    var updated = 0;
    await for (final progress in updateFolder(selected, true)) {
      loading.setProgress(
        progress.total == 0 ? 1 : progress.current / progress.total,
      );
      updated = progress.updated;
    }
    loading.close();
    if (updated > 0) updateFollowUpdatesUI();
  }

  void updateComics() {
    final selected = folder;
    setState(() {
      allComics = selected == null
          ? []
          : NetworkFavoriteCacheManager().getComicsWithUpdatesInfo(selected);
      sortComics();
      updatedComics = allComics.where((comic) => comic.hasNewUpdate).toList();
    });
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking cached remote favorites.
abstract class FollowUpdatesService {
  static bool _isChecking = false;
  static void Function()? _cancelChecking;
  static bool _isInitialized = false;

  static void cancelChecking() => _cancelChecking?.call();

  static void _check() async {
    if (_isChecking) return;
    _isChecking = true;
    var isCanceled = false;
    _cancelChecking = () => isCanceled = true;
    var updated = 0;
    try {
      final enabled = appdata.settings['favorites'];
      if (enabled is List) {
        for (final key in enabled.whereType<String>()) {
          if (isCanceled) return;
          final source = ComicSource.find(key);
          final data = source?.favoriteData;
          if (data == null || !source!.isLogged) continue;
          try {
            await NetworkFavoriteCacheManager().refreshCachedSummaries(data);
          } catch (e, s) {
            Log.error('Refresh favorite cache', e, s);
          }
        }
      }

      final cachedFolders = NetworkFavoriteCacheManager()
          .getAllCachedFolders()
          .where((folder) {
            final source = ComicSource.find(folder.sourceKey);
            return enabled is List &&
                enabled.contains(folder.sourceKey) &&
                source?.isLogged == true &&
                source?.loadComicInfo != null;
          });
      for (final folder in cachedFolders) {
        await for (final progress in updateFolder(folder, false)) {
          if (isCanceled) return;
          updated += progress.updated;
        }
      }
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) updateFollowUpdatesUI();
    }
  }

  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    _check();
    NetworkFavoriteCacheManager().addListener(updateFollowUpdatesUI);
    Timer.periodic(const Duration(minutes: 10), (_) => _check());
  }
}

void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
