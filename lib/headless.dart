import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/init.dart';
import 'package:venera/utils/data_sync.dart';

const _missingUpdateComicArguments = 'Missing comic id or source key.';

({int exitCode, Map<String, dynamic> payload})? unavailableHeadlessScanResult(
  List<String> args,
) {
  final headlessIndex = args.indexOf('--headless');
  if (headlessIndex == -1 || headlessIndex + 1 >= args.length) return null;
  if (args[headlessIndex + 1] != 'updatesubscribe') return null;

  final updateIndex = args.indexOf('--update-comic-by-id-type');
  if (updateIndex != -1 && updateIndex + 2 >= args.length) {
    return (
      exitCode: 1,
      payload: {'status': 'error', 'message': _missingUpdateComicArguments},
    );
  }

  return (
    exitCode: 3,
    payload: {
      'status': 'error',
      'code': followUpdateScannerUnavailableCode,
      'message': followUpdateScannerUnavailableMessage,
    },
  );
}

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

  final unavailable = unavailableHeadlessScanResult(args);
  if (unavailable != null) {
    cliPrint(unavailable.payload);
    exit(unavailable.exitCode);
  }

  final commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex <= 0 || commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  // Need to initialize the app for the remaining headless features.
  if (!await init()) {
    cliPrint({
      'status': 'error',
      'message':
          'Catalog Runtime is not ready; initialize Venera Server first.',
    });
    exit(2);
  }

  final command = args[commandIndex];
  final subCommand = commandIndex + 1 < args.length
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
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  exit(0);
}
