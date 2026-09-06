import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/favorites.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  // Need to initialize the app for some features to work
  if (!await init()) {
    cliPrint({
      'status': 'error',
      'message':
          'Catalog Runtime is not ready; initialize Venera Server first.',
    });
    exit(2);
  }

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({
          'status': 'running',
          'message': 'Downloading WebDAV data...',
        });
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid webdav command. Use "up" or "down".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({
        'status': 'running',
        'message': 'Updating subscribed comics...',
      });
      if (!followUpdatesEnabled) {
        cliPrint({
          'status': 'error',
          'message': 'Follow updates is not enabled.',
        });
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        if (updateIndex + 2 >= args.length) {
          cliPrint({
            'status': 'error',
            'message': 'Missing comic id or source key.',
          });
          exit(1);
        }
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        FavoriteItemWithUpdateInfo? comic;
        NetworkFavoriteFolderRef? folder;
        for (final candidate in getFollowUpdateFolders()) {
          var comics = NetworkFavoriteCacheManager().getComicsWithUpdatesInfo(
            candidate,
          );
          for (final candidateComic in comics) {
            if (candidateComic.id == id && candidateComic.sourceKey == type) {
              comic = candidateComic;
              folder = candidate;
              break;
            }
          }
          if (comic != null) break;
        }
        if (comic == null || folder == null) {
          cliPrint({
            'status': 'error',
            'message': 'Comic is not in the cached follow folders.',
          });
          exit(1);
        }

        var result = await updateComic(comic, folder);

        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          },
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({'status': 'running', 'message': message, 'data': data});

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          },
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJsonInFolders(
          getFollowUpdateFolders(),
        );
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in scanFollowUpdates(
          getFollowUpdateFolders(),
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
        )) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({'status': 'running', 'message': message, 'data': data});
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {'total': total, 'updated': updated, 'errors': errors},
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJsonInFolders(
          getFollowUpdateFolders(),
        );
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}
