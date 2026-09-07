import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart' as win32;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

class Appdata with Init {
  Appdata._create({Future<Directory> Function()? supportDirectoryProvider})
    : _supportDirectoryProvider = supportDirectoryProvider;

  @visibleForTesting
  Appdata.createForTesting(Future<Directory> Function() provider)
    : this._create(supportDirectoryProvider: provider);

  final Future<Directory> Function()? _supportDirectoryProvider;

  final Settings settings = Settings._create();

  /// Whether the global developer-mode switch (Settings -> Debug) is on.
  bool get developerMode => settings['developerMode'] == true;

  var searchHistory = <String>[];

  /// Kept separately from Settings because it is device/runtime state and is
  /// never included in the user-data sync projection.
  dynamic catalogRuntime;

  /// Process-local pointer for diagnostics; it may differ from the persisted
  /// pointer while a healthy local fallback is serving the app.
  AppCatalogState? sessionCatalogState;

  /// Set when the persisted user document cannot be decoded as a document.
  /// The original bytes are deliberately kept in place so recovery can be
  /// attempted without turning a damaged profile into a new installation.
  String? loadError;

  Completer<void>? _writeTail;

  /// Test/integration hook for exercising the failed-replace contract.
  Future<void> Function(File source, File target)? atomicReplace;

  Future<void> saveData([bool sync = true]) async {
    if (loadError != null) {
      throw StateError('appdata is in recovery: $loadError');
    }
    late Map<String, dynamic> document;
    await _withWriteLock(() async {
      document = await _writeDocument(toJson());
      // Keep the derived projection in commit order with the primary file.
      // Its failure is logged but never rolls back the durable document.
      try {
        await _writeSyncProjection(document);
      } catch (error, stack) {
        Log.error('Appdata', 'Failed to update sync projection: $error', stack);
      }
    });
    if (sync) {
      DataSync().uploadData();
    }
  }

  /// Persists the Catalog source selection without first mutating the live
  /// Settings object. This is used by the source-management UI so a failed
  /// filesystem write cannot briefly publish an unsaved selection.
  Future<void> persistEnabledSources(List<String>? value) async {
    await updateEnabledSources((_) => value);
  }

  /// Applies a source-selection mutation to the latest on-disk value while
  /// holding the shared appdata write lock. This prevents two independently
  /// opened SourcePreferences adapters from calculating full-list writes from
  /// the same stale value and losing one another's changes.
  Future<List<String>?> updateEnabledSources(
    List<String>? Function(Object? current) mutation,
  ) async {
    if (loadError != null) {
      throw StateError('appdata is in recovery: $loadError');
    }
    late List<String>? result;
    await _withWriteLock(() async {
      final document = await _readCurrentDocument();
      final next = Map<String, dynamic>.from(_deepCopy(document) as Map);
      final nextSettings = Map<String, dynamic>.from(
        next['settings'] as Map? ?? const {},
      );
      result = mutation(nextSettings['enabledSources']);
      nextSettings['enabledSources'] = result == null
          ? null
          : List<String>.from(result!);
      next['settings'] = nextSettings;
      await _writeDocument(next);
      _installDocumentSilently(next);
      try {
        await _writeSyncProjection(next);
      } catch (error, stack) {
        Log.error('Appdata', 'Failed to update sync projection: $error', stack);
      }
    });
    notifyMemoryChanged();
    DataSync().uploadData();
    return result;
  }

  /// Reads the device-only Catalog pointer without mutating or deleting the
  /// user document. Missing/null means a new installation; malformed means
  /// Recovery and is intentionally surfaced to the controller.
  AppCatalogState? readCatalogState() {
    final value = catalogRuntime;
    if (value == null) return null;
    return AppCatalogState.fromJson(value);
  }

  Future<PreparedAppDataCommit> prepareCatalogCommit({
    required AppCatalogState nextState,
    required List<String>? nextEnabled,
    String? nextServerUrl,
    CatalogAttempt? attempt,
    void Function(Map<String, dynamic> settings)? migrateSourcePages,
  }) => _prepareCatalogDocument((next) {
    final settings = Map<String, dynamic>.from(
      next['settings'] as Map? ?? const {},
    );
    // A normal Settings mutation can happen while this commit is holding
    // the persistence lock. Keep those in-memory user edits in the single
    // Catalog document rather than silently restoring the older on-disk
    // values at the publish barrier.
    settings.addAll(
      Map<String, dynamic>.from(_deepCopy(this.settings._data) as Map),
    );
    if (nextEnabled == null) {
      settings['enabledSources'] = null;
    } else {
      final enabled = List<String>.from(nextEnabled)..sort();
      settings['enabledSources'] = enabled;
    }
    if (nextServerUrl != null) settings['serverUrl'] = nextServerUrl;
    migrateSourcePages?.call(settings);
    next['settings'] = settings;
    next['catalogRuntime'] = nextState.toJson();
  }, attempt: attempt);

  /// Local fallback repairs only device pointers. Read user fields after
  /// acquiring the shared lock so an earlier successful selection save cannot
  /// be overwritten by preferences captured when the repair was scheduled.
  Future<PreparedAppDataCommit> prepareCatalogPointerRepair(
    CatalogPointer pointer,
  ) => _prepareCatalogDocument((next) {
    final rawState = next['catalogRuntime'];
    final previous = rawState == null
        ? null
        : AppCatalogState.fromJson(rawState);
    next['catalogRuntime'] = AppCatalogState(
      active: pointer,
      lkg: null,
      lastAuthority: previous?.lastAuthority,
    ).toJson();
  });

  Future<PreparedAppDataCommit> _prepareCatalogDocument(
    void Function(Map<String, dynamic>) patch, {
    CatalogAttempt? attempt,
  }) async {
    if (attempt != null && !attempt.isOpen) {
      throw StateError('Catalog attempt is no longer open');
    }
    final releaseLock = await _acquireWriteLock();
    File? temp;
    try {
      final document = await _readCurrentDocument();
      final originalBytes = await _readAppDataBytes();
      final next = Map<String, dynamic>.from(_deepCopy(document) as Map);
      patch(next);
      final target = File(FilePath.join(App.dataPath, 'appdata.json'));
      await target.parent.create(recursive: true);
      temp = File('${target.path}.${const Uuid().v4()}.tmp');
      await temp.writeAsString(jsonEncode(next), flush: true);
      return PreparedAppDataCommit._(
        owner: this,
        document: next,
        originalDocument: document,
        originalMemoryDocument: Map<String, dynamic>.from(
          _deepCopy(toJson()) as Map,
        ),
        originalBytes: originalBytes,
        temp: temp,
        target: target,
        releaseLock: releaseLock,
      );
    } catch (_) {
      if (temp != null && await temp.exists()) await temp.delete();
      releaseLock();
      rethrow;
    }
  }

  /// Prepares a user-data-only merge while holding the same write lock used by
  /// normal saves. Callers can replace it after validating other import files,
  /// and can roll it back if a later file replacement or reopen fails.
  Future<PreparedAppDataCommit> prepareUserDataCommit(
    Map<String, dynamic> data,
  ) async {
    if (loadError != null) {
      throw StateError('appdata is in recovery: $loadError');
    }
    final releaseLock = await _acquireWriteLock();
    File? temp;
    try {
      final document = await _readCurrentDocument();
      final originalBytes = await _readAppDataBytes();
      final next = _mergeUserDataDocument(document, data);
      final target = File(FilePath.join(App.dataPath, 'appdata.json'));
      await target.parent.create(recursive: true);
      temp = File('${target.path}.${const Uuid().v4()}.tmp');
      await temp.writeAsString(jsonEncode(next), flush: true);
      return PreparedAppDataCommit._(
        owner: this,
        document: next,
        originalDocument: document,
        originalMemoryDocument: Map<String, dynamic>.from(
          _deepCopy(toJson()) as Map,
        ),
        originalBytes: originalBytes,
        temp: temp,
        target: target,
        releaseLock: releaseLock,
      );
    } catch (_) {
      if (temp != null && await temp.exists()) await temp.delete();
      releaseLock();
      rethrow;
    }
  }

  Future<List<int>?> _readAppDataBytes() async {
    final file = File(FilePath.join(App.dataPath, 'appdata.json'));
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<Map<String, dynamic>> _readCurrentDocument() async {
    final file = File(FilePath.join(App.dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return Map<String, dynamic>.from(_deepCopy(toJson()) as Map);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('appdata must be an object');
      }
      return Map<String, dynamic>.from(
        _deepCopy(Map<String, dynamic>.from(decoded)) as Map,
      );
    } catch (error) {
      throw StateError('cannot read appdata for atomic update: $error');
    }
  }

  Future<Map<String, dynamic>> _writeDocument(
    Map<String, dynamic> document,
  ) async {
    final target = File(FilePath.join(App.dataPath, 'appdata.json'));
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temp.writeAsString(jsonEncode(document), flush: true);
      await _replaceAtomically(temp, target);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    return document;
  }

  Future<void> _writeSyncProjection(Map<String, dynamic> document) async {
    final projected = _deepCopy(document);
    projected.remove('catalogRuntime');
    final settings = projected['settings'];
    if (settings is Map) {
      for (final field in _disableSync) {
        settings.remove(field);
      }
      final disable = settings['disableSyncFields'];
      if (disable is String) {
        for (final field in splitField(disable)) {
          settings.remove(field);
        }
      }
    }
    final file = File(FilePath.join(App.dataPath, 'syncdata.json'));
    await file.writeAsString(jsonEncode(projected), flush: true);
  }

  Future<void> _replaceAtomically(File source, File target) async {
    if (atomicReplace != null) {
      await atomicReplace!(source, target);
      return;
    }
    if (Platform.isWindows) {
      final sourcePath = source.path.toNativeUtf16();
      final targetPath = target.path.toNativeUtf16();
      try {
        final result = win32.MoveFileEx(
          sourcePath,
          targetPath,
          win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH,
        );
        if (result == 0) {
          throw OSError('MoveFileExW failed', win32.GetLastError());
        }
      } finally {
        calloc.free(sourcePath);
        calloc.free(targetPath);
      }
      return;
    }
    await source.rename(target.path);
  }

  /// Shared atomic file primitive for user-data importers. The importer still
  /// stages and validates its payload before calling this method.
  Future<void> replaceFileAtomically(File source, File target) =>
      _replaceAtomically(source, target);

  Future<void Function()> _acquireWriteLock() async {
    final previous = _writeTail?.future;
    final done = Completer<void>();
    _writeTail = done;
    if (previous != null) await previous;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (identical(_writeTail, done)) _writeTail = null;
      if (!done.isCompleted) done.complete();
    };
  }

  Future<T> _withWriteLock<T>(Future<T> Function() action) async {
    final release = await _acquireWriteLock();
    try {
      return await action();
    } finally {
      release();
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {
      'settings': _deepCopy(settings._data),
      'searchHistory': List<String>.from(searchHistory),
      if (catalogRuntime != null) 'catalogRuntime': _deepCopy(catalogRuntime),
    };
  }

  /// User-data projection used by backups and WebDAV. Runtime pointers and
  /// device-owned connection fields never cross this boundary.
  Map<String, dynamic> toUserDataJson() {
    final projected = Map<String, dynamic>.from(_deepCopy(toJson()) as Map);
    projected.remove('catalogRuntime');
    final rawSettings = projected['settings'];
    if (rawSettings is Map) {
      for (final field in _disableSync) {
        rawSettings.remove(field);
      }
      final custom = rawSettings['disableSyncFields'];
      if (custom is String) {
        for (final field in splitField(custom)) {
          rawSettings.remove(field);
        }
      }
    }
    return projected;
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "deviceId",
    "serverUrl",
    "developerMode",
    "cloudTrackingEnabled",
    "cloudTrackingServerUrl",
    "cloudTrackingAccessToken",
  ];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data) {
    unawaited(syncDataAndWait(data));
  }

  /// Applies only user-owned fields and waits until the new document has been
  /// durably replaced. Device/runtime fields are never accepted from input.
  Future<void> syncDataAndWait(Map<String, dynamic> data) async {
    if (loadError != null) {
      throw StateError('appdata is in recovery: $loadError');
    }
    final commit = await prepareUserDataCommit(data);
    try {
      await commit.replace();
      commit.installMemorySilently();
      // Rebuild the derived projection before releasing the commit lock so a
      // concurrent save cannot publish an older projection after this one.
      try {
        await _writeSyncProjection(commit.document);
      } catch (error, stack) {
        Log.error('Appdata', 'Failed to update sync projection: $error', stack);
      }
      commit.release();
    } catch (_) {
      await commit.rollback();
      rethrow;
    }
    notifyMemoryChanged();
    DataSync().uploadData();
  }

  Map<String, dynamic> _mergeUserDataDocument(
    Map<String, dynamic> document,
    Map<String, dynamic> data,
  ) {
    // `_deepCopy` intentionally keeps dynamic map keys for arbitrary sync
    // payloads; normalize the top-level document before accessing settings so
    // decoded JSON maps do not fail a reified generic cast on Windows.
    final next = Map<String, dynamic>.from(_deepCopy(document) as Map);
    final currentSettings = Map<String, dynamic>.from(
      next['settings'] as Map? ?? const {},
    );
    final incoming = data['settings'];
    if (incoming is Map) {
      final customDisableSync = splitField(
        currentSettings['disableSyncFields'] is String
            ? currentSettings['disableSyncFields'] as String
            : '',
      );
      for (final item in incoming.entries) {
        final key = item.key;
        if (key is String &&
            !_disableSync.contains(key) &&
            !customDisableSync.contains(key) &&
            item.value != null) {
          currentSettings[key] = _deepCopy(item.value);
        }
      }
    }
    next['settings'] = currentSettings;
    if (data.containsKey('searchHistory')) {
      final history = data['searchHistory'];
      if (history is List && history.every((item) => item is String)) {
        next['searchHistory'] = List<String>.from(history);
      }
    }
    // catalogRuntime from another device is intentionally ignored; preserve
    // the local value already present in [next].
    return next;
  }

  var implicitData = <String, dynamic>{};

  void writeImplicitData() async {
    final release = await _acquireWriteLock();
    try {
      var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
      await file.writeAsString(jsonEncode(implicitData), flush: true);
    } finally {
      release();
    }
  }

  @override
  Future<void> doInit() async {
    final provider = _supportDirectoryProvider;
    final supportDirectory = provider == null
        ? await getApplicationSupportDirectory()
        : await provider();
    var dataPath = supportDirectory.path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    loadError = null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('appdata must be an object');
      }
      final json = Map<String, dynamic>.from(decoded);
      final persistedSettings = json['settings'];
      if (persistedSettings is Map) {
        for (final item in persistedSettings.entries) {
          if (item.key is String && item.value != null) {
            settings[item.key as String] = _deepCopy(item.value);
          }
        }
      } else if (json.containsKey('settings') && persistedSettings != null) {
        Log.error("Appdata", "Ignoring invalid settings field");
      }
      final persistedHistory = json['searchHistory'];
      if (persistedHistory is List &&
          persistedHistory.every((item) => item is String)) {
        searchHistory = List<String>.from(persistedHistory);
      } else if (json.containsKey('searchHistory') &&
          persistedHistory != null) {
        Log.error("Appdata", "Ignoring invalid searchHistory field");
      }
      if (json.containsKey('catalogRuntime')) {
        catalogRuntime = _deepCopy(json['catalogRuntime']);
      }
    } catch (e) {
      loadError = 'Failed to load appdata: $e';
      Log.error("Appdata", "Failed to load appdata", e);
      Log.info("Appdata", "Keeping appdata for recovery");
    }
    if (loadError == null && settings["deviceId"] is! String) {
      settings._data["deviceId"] = '';
    }
    if (loadError == null && (settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = jsonDecode(await implicitDataFile.readAsString());
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
  }

  void _installDocumentSilently(
    Map<String, dynamic> document, {
    bool notify = true,
  }) {
    final persistedSettings = document['settings'];
    var settingsChanged = false;
    if (persistedSettings is Map) {
      for (final item in persistedSettings.entries) {
        // enabledSources uses null as the explicit “not initialized” value.
        // Keep that null when installing a just-persisted document while
        // retaining the historical default-preserving behavior for unrelated
        // sparse settings.
        if (item.key is String &&
            (item.value != null || item.key == 'enabledSources')) {
          settings._data[item.key as String] = _deepCopy(item.value);
          settingsChanged = true;
        }
      }
    }
    final history = document['searchHistory'];
    if (history is List && history.every((item) => item is String)) {
      searchHistory = List<String>.from(history);
    }
    if (document.containsKey('catalogRuntime')) {
      catalogRuntime = _deepCopy(document['catalogRuntime']);
    }
    if (settingsChanged && notify) settings.notifyChanged();
  }

  void notifyMemoryChanged() => settings.notifyChanged();
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'followUpdateThreads': 8,
    'followUpdateBatchDelay': 5, // in seconds
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'preloadImageCount': 4,
    'followUpdatesEnabled': false,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'developerMode': false, // show debug info in comic details
    // Deprecated device-local fields retained for migration compatibility.
    // Cloud tracking has no active behavior or user-facing configuration.
    'cloudTrackingEnabled': false,
    'cloudTrackingServerUrl': '',
    'cloudTrackingAccessToken': '',
    'serverUrl': '',
    'enabledSources': null,
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void notifyChanged() => notifyListeners();

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

class PreparedAppDataCommit {
  PreparedAppDataCommit._({
    required this.owner,
    required this.document,
    required this.originalDocument,
    required this.originalMemoryDocument,
    required this.originalBytes,
    required this.temp,
    required this.target,
    required this.releaseLock,
  });

  final Appdata owner;
  final Map<String, dynamic> document;
  final Map<String, dynamic> originalDocument;
  final Map<String, dynamic> originalMemoryDocument;
  final List<int>? originalBytes;
  final File temp;
  final File target;
  final void Function() releaseLock;
  bool _replaced = false;
  bool _released = false;

  bool get isReleased => _released;

  Future<void> replace() async {
    if (_released) throw StateError('appdata commit has been released');
    if (_replaced) return;
    await owner._replaceAtomically(temp, target);
    _replaced = true;
  }

  /// Must be called synchronously after replace and before release.
  void installMemorySilently() {
    if (!_replaced) throw StateError('appdata commit was not replaced');
    owner._installDocumentSilently(document, notify: false);
  }

  void release() {
    if (_released) return;
    _released = true;
    releaseLock();
  }

  Future<void> discard() async {
    if (_released) return;
    try {
      if (await temp.exists()) await temp.delete();
    } finally {
      release();
    }
  }

  /// Restores the appdata document and in-memory projection after a commit
  /// that was already replaced. This is intentionally per-file recovery; it
  /// is not a claim of a cross-file power-loss transaction.
  Future<void> rollback() async {
    if (_released) return;
    try {
      if (_replaced) {
        if (originalBytes == null) {
          if (await target.exists()) await target.delete();
        } else {
          final restore = File('${target.path}.${const Uuid().v4()}.rollback');
          await restore.writeAsBytes(originalBytes!, flush: true);
          try {
            await owner._replaceAtomically(restore, target);
          } finally {
            if (await restore.exists()) await restore.delete();
          }
        }
        _replaced = false;
      } else if (await temp.exists()) {
        await temp.delete();
      }
      owner._installDocumentSilently(originalMemoryDocument, notify: false);
    } finally {
      release();
    }
  }
}

dynamic _deepCopy(dynamic value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key, _deepCopy(value)));
  }
  if (value is List) return value.map(_deepCopy).toList();
  return value;
}
