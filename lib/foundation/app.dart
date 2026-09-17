import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/semantic_version.dart';

import 'appdata.dart';
import 'favorites.dart';
import 'local.dart';
import 'log.dart';

export "widget_utils.dart";
export "context.dart";

/// The explicit marker used when the running build's version is unknown.
///
/// It is never a version number, so no consumer can mistake it for one. The
/// string is also a translation key, which is how the UI renders it localized.
const String unknownAppVersion = "Unknown";

/// Reads the build artifact's package metadata for the running application.
///
/// Replaced in tests so the version path can be exercised with synthetic
/// metadata instead of a platform channel.
typedef PackageInfoReader = Future<PackageInfo> Function();

class _App {
  factory _App() => _instance;

  _App._();

  static final _App _instance = _App._();

  /// The injectable package-metadata reader.
  ///
  /// Kept as a field with a production default so a test can substitute the
  /// metadata source without a platform channel.
  static PackageInfoReader packageInfoReader = PackageInfo.fromPlatform;

  /// The current package-metadata reader, as a test seam.
  PackageInfoReader get packageInfoReaderSeam => packageInfoReader;

  /// Replaces the package-metadata reader, as a test seam.
  set packageInfoReaderSeam(PackageInfoReader reader) =>
      packageInfoReader = reader;

  /// Reads the build artifact's package metadata.
  ///
  /// This is the only call site of [packageInfoReader]; [readPackageVersion]
  /// turns its result into the runtime version state.
  static Future<PackageInfo> readPackageInfo() => packageInfoReader();

  /// The semantic version reported by the running build, or `null` when the
  /// package metadata is missing or unreadable.
  ///
  /// `pubspec.yaml` is the only place a real version is maintained. The value is
  /// read from the built package metadata during [init] so Dart never keeps a
  /// second copy that can drift from the release.
  String? packageVersion;

  /// The build number reported by the running build, or `null` when unknown.
  String? packageBuildNumber;

  /// The semantic version (`major.minor.patch[-prerelease]`) of this build.
  ///
  /// Build metadata is never shown: the release tag and the release asset name
  /// are both derived from this string. When the package metadata could not be
  /// read the version is [unknownAppVersion] — the explicit marker, which is a
  /// translation key — rather than a fabricated version.
  String get version => packageVersion ?? unknownAppVersion;

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings['language'] != 'system') {
      return Locale(
        appdata.settings['language'].split('-')[0],
        appdata.settings['language'].split('-')[1],
      );
    }
    return deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final NetworkFavoriteCacheManager favorites = NetworkFavoriteCacheManager();

  final LocalManager local = LocalManager();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    await readPackageVersion();
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  /// Reads `App.version` from the build artifact's package metadata.
  ///
  /// `pubspec.yaml` is the single real version source; the build copies it into
  /// the package metadata that this reads back, so no Dart constant can drift
  /// from a release. A missing, throwing or unparsable value is recorded and
  /// left as the explicit unknown state: version display and the update check
  /// degrade, but application start-up never fails because of versioning.
  ///
  /// Nothing from the package metadata is logged verbatim: only the fact that
  /// it was absent or unusable is recorded, so no build-specific data can leak
  /// into the log through the version path.
  ///
  /// [init] runs this first. It is public so the version contract can be
  /// exercised without the platform-directory calls in [init].
  Future<void> readPackageVersion() async {
    PackageInfo? info;
    var failed = false;
    try {
      info = await readPackageInfo();
    } catch (_) {
      failed = true;
      Log.error(
        "Read Package Version",
        "The package metadata could not be read; the version is unknown",
      );
    }
    final raw = info?.version;
    final semantic = tryParseSemanticVersion(raw)?.semantic;
    if (semantic == null) {
      packageVersion = null;
      packageBuildNumber = null;
      if (!failed) {
        Log.error(
          "Read Package Version",
          raw == null || raw.isEmpty
              ? "The package metadata has no version; the version is unknown"
              : "The package metadata version is not a semantic version; "
                    "the version is unknown",
        );
      }
      return;
    }
    packageVersion = semantic;
    final build = info?.buildNumber;
    packageBuildNumber = build == null || build.isEmpty ? null : build;
  }

  Future<void> initComponents() async {
    // Appdata is the source of the persisted Cloud ownership preference and
    // must be ready before any source/runtime component is initialized.
    await data.init();
    await Future.wait([history.init(), favorites.init(), local.init()]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
