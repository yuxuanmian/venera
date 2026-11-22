import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scan/scan_service.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

bool _hasActiveWork() {
  final sync = DataSync.instance;
  return sync?.isDownloading == true ||
      sync?.isUploading == true ||
      App.local.downloadingTasks.any((task) => !task.isPaused) ||
      FollowUpdatesService.taskRunning ||
      FollowUpdatesService.isCachingFavorites ||
      scanService.isRunning;
}

bool _restarting = false;

/// Restarts the Android app through its normal launcher entry point.
Future<void> restartAndroidApp(BuildContext context) async {
  if (_restarting) return;
  _restarting = true;
  try {
    // Saving preferences and the Catalog source uses the same write queue.
    await appdata.waitForPendingWrites();
    if (!context.mounted) return;
    if (_hasActiveWork()) {
      context.showMessage(
        message:
            'Wait for downloads, sync, or scans to finish before restarting.'
                .tl,
      );
      return;
    }
    CacheManager.instance?.flushPendingExpiryUpdates();
    await const MethodChannel(
      'venera/method_channel',
    ).invokeMethod<void>('restartApp');
  } catch (error, stack) {
    Log.error('Restart App', error.toString(), stack);
    if (context.mounted) {
      context.showMessage(message: 'Unable to restart the app'.tl);
    }
  } finally {
    _restarting = false;
  }
}
