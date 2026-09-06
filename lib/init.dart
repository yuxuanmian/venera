import 'dart:async';
import 'dart:io';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

bool _baseInitialized = false;
bool _runtimeInitialized = false;
CatalogController? catalogController;

Future<void> initBase() async {
  if (_baseInitialized) return;
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  try {
    await Rhttp.init();
    await appdata.init();
    await Future.wait([
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      OpenCC.init(),
    ]);
    // Do not turn a failed native engine into a successful empty runtime.
    // The outer base error is logged, and Catalog preparation will surface the
    // same failure to the Gate instead of publishing partial sources.
    await JsEngine().init();
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  catalogController ??= CatalogController(
    store: CatalogStore(Directory('${App.dataPath}/catalog_runtime')),
    runtimeLoader: CatalogRuntimeLoader.forComicSources(),
  );
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  _baseInitialized = true;
}

Future<void> initRuntimeServices() async {
  if (_runtimeInitialized) return;
  await SAFTaskWorker().init().wait();
  // CatalogGate has already published the complete Source assembly. Component
  // initialization can now restore user data and download tasks safely.
  await App.initComponents();
  DataSync.markRuntimeReady();
  App.local.restoreDownloadingTasks();
  _checkOldConfigs();
  checkUpdates();
  _runtimeInitialized = true;
  // Flush batched cache index updates when the app is backgrounded or
  // killed, so sliding expirations are durable even if the process dies.
  AppLifecycleListener(
    onPause: CacheManager().flushPendingExpiryUpdates,
    onDetach: CacheManager().flushPendingExpiryUpdates,
  );
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

/// Compatibility entry point for headless callers. The visible UI uses the
/// split base/Gate/runtime sequence in main.dart.
Future<bool> init() async {
  await initBase();
  final result = await catalogController!.boot();
  if (result is CatalogReady) {
    await initRuntimeServices();
    return true;
  } else {
    Log.error('init', 'Catalog is not ready: $result');
    return false;
  }
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}
