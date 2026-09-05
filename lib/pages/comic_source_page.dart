import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/foundation/tracking/tracking.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

@visibleForTesting
bool shouldCommitComicSourceEdit(String initial, String current) {
  return initial != current;
}

/// The small commit gate shared by the mobile editor and its regression
/// tests. Opening an editor is not a runtime mutation; only a changed buffer
/// writes the file and invokes the reload/fence callback.
@visibleForTesting
class ComicSourceEditSession {
  ComicSourceEditSession({
    required this.file,
    required String initialValue,
    this.onBeforeWrite,
    required this.onCommit,
  }) : initial = initialValue,
       current = initialValue;

  final io.File file;
  final String initial;
  String current;
  final void Function()? onBeforeWrite;
  final void Function() onCommit;

  void close() {
    if (!shouldCommitComicSourceEdit(initial, current)) return;
    onBeforeWrite?.call();
    file.writeAsStringSync(current);
    onCommit();
  }
}

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static ActiveArtifact? _activeForSource(
    ActiveArtifactRegistry registry,
    SourceRevisionStore store,
    ComicSource source,
  ) => registry.artifacts.firstWhereOrNull(
    (artifact) =>
        artifact.sourceKey == source.key &&
        p.equals(
          store.fileForRelativePath(artifact.relativePath).absolute.path,
          io.File(source.filePath).absolute.path,
        ),
  );

  /// Resolves legacy source files without registering a second live runtime.
  ///
  /// Migration can run while the existing source manager still owns the same
  /// key.  Validation-only parsing keeps that lookup side-effect free and
  /// lets the caller decide when the selected artifact becomes active.
  static Future<String> _resolveSourceKey(io.File file) async {
    final parsed = await ComicSourceParser().parse(
      await file.readAsString(),
      file.absolute.path,
      register: false,
      allowExistingKey: true,
      loadData: false,
      scheduleInit: false,
    );
    return parsed.key;
  }

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    if (!source.url.isURL) {
      if (showLoading) {
        App.rootContext.showMessage(message: "Invalid url config");
        return;
      } else {
        throw Exception("Invalid url config");
      }
    }
    bool cancel = false;
    LoadingDialogController? controller;
    if (showLoading) {
      controller = showLoadingDialog(
        App.rootContext,
        onCancel: () => cancel = true,
        barrierDismissible: false,
      );
    }
    try {
      final sourceDirectory = Directory(p.join(App.dataPath, 'comic_source'));
      final store = SourceRevisionStore(sourceDirectory);
      final registry = await store.load() ?? const ActiveArtifactRegistry();
      final active = _activeForSource(registry, store, source);
      if (active?.origin == ArtifactOrigin.managedCatalog) {
        await _updateManagedSource(source, active!, store);
        controller?.close();
        if (showLoading) App.forceRebuild();
        return;
      }

      var res = await AppDio().get<String>(
        source.url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) {
        controller?.close();
        return;
      }
      controller?.close();
      await _updateCustomSource(source, active, store, utf8.encode(res.data!));
      if (ComicSourceManager().availableUpdates.containsKey(source.key)) {
        ComicSourceManager().availableUpdates.remove(source.key);
      }
    } catch (e) {
      controller?.close();
      if (cancel) return;
      if (showLoading) {
        App.rootContext.showMessage(message: e.toString());
      } else {
        rethrow;
      }
    }
    if (showLoading) {
      App.forceRebuild();
    }
  }

  static Future<void> _updateManagedSource(
    ComicSource source,
    ActiveArtifact active,
    SourceRevisionStore store,
  ) async {
    final uri = Uri.tryParse(source.url);
    if (uri == null) {
      throw const FormatException('managed catalog URL is invalid');
    }
    final revision = await _resolveCatalogRevision(const TrustedCatalog(), uri);
    if (active.revision != revision) {
      await App.cloudTracking.activateManagedSource(
        identity: active.identity,
        revision: revision,
        fetch: _fetchCatalogBytes,
      );
    }
    ComicSourceManager().availableUpdates.remove(source.key);
  }

  static Future<void> _updateCustomSource(
    ComicSource source,
    ActiveArtifact? active,
    SourceRevisionStore store,
    List<int> bytes,
  ) async {
    final registry = await store.load() ?? const ActiveArtifactRegistry();
    final current = active ?? _activeForSource(registry, store, source);
    if (current == null || current.origin != ArtifactOrigin.custom) {
      throw const FormatException('custom source artifact is missing');
    }
    await SourceMutationService(
      store: store,
      coordinator: App.cloudTracking,
      resolveSourceKey: ComicSourcePage._resolveSourceKey,
    ).updateCustom(current.identity, bytes);
  }

  /// The mutation fence invalidates the old generation even when a source
  /// update rolls back.  Reconcile the restored runtime so it receives a new
  /// commit token before Local/Cloud work resumes.
  static Future<void> _reconcileAfterMutationFailure() async {
    try {
      await App.cloudTracking.onSettingsChanged();
    } catch (error, stack) {
      Log.error('Reconcile comic source after mutation failure', error, stack);
    }
  }

  static Future<bool> _tryAddManagedSource({
    required String sourceKey,
    required String fileName,
    required Uri uri,
  }) async {
    const catalog = TrustedCatalog();
    if (catalog.referenceFromArtifactUri(uri) == null) return false;
    final revision = await _resolveCatalogRevision(catalog, uri);
    await App.cloudTracking.activateManagedSource(
      identity: TrustedArtifact(sourceKey: sourceKey, fileName: fileName),
      revision: revision,
      fetch: _fetchCatalogBytes,
    );
    App.forceRebuild();
    return true;
  }

  static Future<List<int>> _fetchCatalogBytes(Uri uri) async {
    final response = await AppDio().get<List<int>>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.bytes,
        headers: const {'cache-time': 'no'},
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw FormatException(
        'catalog fetch failed with status ${response.statusCode}',
      );
    }
    return List<int>.from(response.data!);
  }

  static Future<String> _resolveCatalogRevision(
    TrustedCatalog catalog,
    Uri artifactUri,
  ) async {
    final reference = catalog.referenceFromArtifactUri(artifactUri);
    if (reference == null) {
      throw const FormatException('catalog URL is not trusted');
    }
    if (appdata.settings['cloudTrackingEnabled'] == true) {
      final authority = App.cloudTracking.authority;
      if (authority == null || !catalog.isTrustedCatalog(authority.catalogId)) {
        throw const FormatException(
          'Cloud source updates require the current trusted authority',
        );
      }
      // Cloud-on never follows a branch or a user URL.  The coordinator has
      // already verified this immutable revision from the trusted profile.
      return authority.activeRevision;
    }
    if (catalog.isValidRevision(reference)) return reference;
    final response = await AppDio().get<String>(
      catalog.commitResolverUri(reference).toString(),
      options: Options(responseType: ResponseType.plain),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw FormatException(
        'catalog revision resolution failed with status ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.data!);
    final resolved = decoded is Map ? decoded['sha'] : null;
    if (resolved is! String || !catalog.isValidRevision(resolved)) {
      throw const FormatException('catalog resolver returned an invalid SHA');
    }
    return resolved;
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    if (appdata.settings['cloudTrackingEnabled'] == true) {
      final authority = App.cloudTracking.authority;
      final registry = App.cloudTracking.registry;
      if (authority == null || registry == null) return -1;
      final updates = <String, String>{};
      for (final source in ComicSource.all()) {
        final active = registry.find(source.key, p.basename(source.filePath));
        if (active?.origin == ArtifactOrigin.managedCatalog &&
            active?.revision != authority.activeRevision) {
          updates[source.key] = authority.activeRevision;
        }
      }
      if (updates.isNotEmpty) {
        ComicSourceManager().updateAvailableUpdates(updates);
      }
      return updates.length;
    }
    var dio = AppDio();
    var res = await dio.get<String>(appdata.settings['comicSourceListUrl']);
    if (res.statusCode != 200) {
      return -1;
    }
    var list = jsonDecode(res.data!) as List;
    var versions = <String, String>{};
    for (var source in list) {
      versions[source['key']] = source['version'];
    }
    var shouldUpdate = <String>[];
    for (var source in ComicSource.all()) {
      if (versions.containsKey(source.key) &&
          compareSemVer(versions[source.key]!, source.version)) {
        shouldUpdate.add(source.key);
      }
    }
    if (shouldUpdate.isNotEmpty) {
      var updates = <String, String>{};
      for (var key in shouldUpdate) {
        updates[key] = versions[key]!;
      }
      ComicSourceManager().updateAvailableUpdates(updates);
    }
    return shouldUpdate.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _RecoverableSources extends StatefulWidget {
  const _RecoverableSources({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_RecoverableSources> createState() => _RecoverableSourcesState();
}

class _RecoverableSourcesState extends State<_RecoverableSources> {
  late Future<ActiveArtifactRegistry> _registryFuture;
  TrustedArtifact? _restoring;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final directory = Directory(p.join(App.dataPath, 'comic_source'));
    _registryFuture = SourceRevisionStore(
      directory,
    ).load().then((registry) => registry ?? const ActiveArtifactRegistry());
  }

  Future<void> _restore(ActiveArtifact recovery) async {
    if (!App.cloudTracking.customizationAllowed) {
      context.showMessage(
        message:
            "Turn off Cloud before editing or installing a custom source.".tl,
      );
      return;
    }
    setState(() => _restoring = recovery.identity);
    try {
      final directory = Directory(p.join(App.dataPath, 'comic_source'));
      await SourceMutationService(
        store: SourceRevisionStore(directory),
        coordinator: App.cloudTracking,
        resolveSourceKey: ComicSourcePage._resolveSourceKey,
      ).restoreCustom(recovery);
      if (!mounted) return;
      context.showMessage(message: "Custom source restored.".tl);
      widget.onChanged();
      setState(() {
        _restoring = null;
        _reload();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _restoring = null);
      context.showMessage(message: "Custom source recovery failed.".tl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ActiveArtifactRegistry>(
      future: _registryFuture,
      builder: (context, snapshot) {
        final recoveries = snapshot.data?.recoverableArtifacts ?? const [];
        final diagnostics =
            snapshot.data?.migrationDiagnostics ?? const <String, String>{};
        if (recoveries.isEmpty && diagnostics.isEmpty) {
          return const SliverToBoxAdapter();
        }
        final cloudBlocked = !App.cloudTracking.customizationAllowed;
        return SliverToBoxAdapter(
          child: Card(
            margin: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final diagnostic in diagnostics.entries)
                  ListTile(
                    title: Text(diagnostic.key),
                    subtitle: Text(
                      '${"Source file preserved; identity unresolved.".tl}\n${diagnostic.value.tl}',
                    ),
                  ),
                ListTile(
                  title: Text("Custom source recovery".tl),
                  subtitle: cloudBlocked
                      ? Text(
                          "Turn off Cloud before restoring a custom source.".tl,
                        )
                      : null,
                ),
                for (final recovery in recoveries)
                  ListTile(
                    title: Text('${recovery.sourceKey} · ${recovery.fileName}'),
                    subtitle: Text(
                      '${recovery.relativePath}\n${recovery.sha256}',
                    ),
                    trailing: TextButton(
                      onPressed: cloudBlocked || _restoring == recovery.identity
                          ? null
                          : () => _restore(recovery),
                      child: Text("Restore".tl),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BodyState extends State<_Body> {
  var url = "";

  void updateUI() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    super.dispose();
    ComicSourceManager().removeListener(updateUI);
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        _RecoverableSources(onChanged: updateUI),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.filePath),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () => unawaited(_deleteSource(source)),
    );
  }

  Future<void> _deleteSource(ComicSource source) async {
    var mutationFenced = false;
    try {
      final sourceDirectory = Directory(p.join(App.dataPath, 'comic_source'));
      final store = SourceRevisionStore(sourceDirectory);
      final registry = await store.load() ?? const ActiveArtifactRegistry();
      final active = ComicSourcePage._activeForSource(registry, store, source);
      if (active != null) {
        // The registry replacement is the first active runtime mutation. Do
        // not fence merely while resolving the source, and keep the exact
        // artifact identity for this deletion.
        App.cloudTracking.beforeArtifactChange(active.identity);
        mutationFenced = true;
        await store.save(
          registry.copyWith(
            artifacts: [
              for (final item in registry.artifacts)
                if (item != active) item,
            ],
          ),
        );
        if (active.origin == ArtifactOrigin.custom) {
          final customFile = store.fileForRelativePath(active.relativePath);
          if (await customFile.exists()) await customFile.delete();
        }
      } else {
        final sourceFile = io.File(source.filePath);
        if (await sourceFile.exists()) {
          App.cloudTracking.beforeArtifactsChange();
          mutationFenced = true;
          await sourceFile.delete();
        }
      }
      ComicSourceManager().remove(source.key);
      _validatePages();
      await App.cloudTracking.onSettingsChanged();
      App.forceRebuild();
    } catch (error, stack) {
      if (mutationFenced) {
        await ComicSourcePage._reconcileAfterMutationFailure();
      }
      Log.error('Delete comic source', error, stack);
      App.rootContext.showMessage(message: error.toString());
    }
  }

  void edit(ComicSource source) async {
    final sourceDirectory = Directory(p.join(App.dataPath, 'comic_source'));
    final store = SourceRevisionStore(sourceDirectory);
    final service = SourceMutationService(
      store: store,
      coordinator: App.cloudTracking,
      resolveSourceKey: ComicSourcePage._resolveSourceKey,
    );
    SourceEditSession session;
    try {
      final registry = await store.load() ?? const ActiveArtifactRegistry();
      final active = ComicSourcePage._activeForSource(registry, store, source);
      if (active == null) {
        throw const SourceMutationDenied(
          'Source selection is no longer active.',
        );
      }
      session = await service.openEditor(active.identity);
    } catch (error) {
      App.rootContext.showMessage(message: error.toString());
      return;
    }
    if (App.isDesktop) {
      try {
        await Process.run("code", [session.draftPath], runInShell: true);
        var committed = false;
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("cancel".tl),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await service.commitDraft(session);
                    committed = true;
                    App.forceRebuild();
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (context.mounted) {
                      context.showMessage(message: error.toString());
                    }
                  }
                },
                child: Text("continue".tl),
              ),
            ],
          ),
        );
        if (!committed) await service.cancel(session);
        return;
      } catch (_) {
        // Fall through to the in-app editor when the desktop editor is not
        // available.  The session still points at the isolated draft.
      }
    }
    if (!mounted) {
      await service.cancel(session);
      return;
    }
    context.to(
      () => _EditFilePage(session.draftPath, (value) async {
        await service.commitBuffer(session, value);
        if (mounted) setState(() {});
      }, onCancel: () => service.cancel(session)),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: Icon(Icons.article_outlined),
                  label: Text("Comic Source list".tl),
                  onPressed: () {
                    showPopUpWidget(
                      App.rootContext,
                      _ComicSourceList(handleAddSource),
                    );
                  },
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    if (!App.cloudTracking.customizationAllowed) {
      context.showMessage(
        message:
            "Turn off Cloud before editing or installing a custom source.".tl,
      );
      return;
    }
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/venera-app/venera/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(
    String url, {
    String? sourceKey,
    String? fileName,
  }) async {
    if (url.isEmpty) {
      return;
    }
    final resolvedFileName = fileName ?? _fileNameFromUrl(url);
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      if (sourceKey != null && resolvedFileName != null) {
        final added = await ComicSourcePage._tryAddManagedSource(
          sourceKey: sourceKey,
          fileName: resolvedFileName,
          uri: Uri.parse(url),
        );
        if (added) {
          controller.close();
          return;
        }
      }
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller.close();
      await addSource(res.data!, resolvedFileName ?? 'source.js');
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  String? _fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final value = uri.pathSegments.last.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> addSource(String js, String fileName) async {
    final sourceDirectory = Directory(p.join(App.dataPath, 'comic_source'));
    final artifact = await SourceMutationService(
      store: SourceRevisionStore(sourceDirectory),
      coordinator: App.cloudTracking,
      resolveSourceKey: ComicSourcePage._resolveSourceKey,
    ).addCustom(js, fileName);
    final comicSource = ComicSource.find(artifact.sourceKey);
    if (comicSource == null) {
      throw const FormatException('installed comic source was not loaded');
    }
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String url, {String? sourceKey, String? fileName})
  onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  List? json;
  bool changed = false;
  var controller = TextEditingController();

  void load() async {
    if (json != null) {
      setState(() {
        json = null;
      });
    }
    if (controller.text.isEmpty) {
      setState(() {
        json = [];
      });
      return;
    }
    var dio = AppDio();
    try {
      var res = await dio.get<String>(controller.text);
      if (res.statusCode != 200) {
        throw "error";
      }
      if (mounted) {
        setState(() {
          json = jsonDecode(res.data!);
        });
      }
    } catch (e) {
      context.showMessage(message: "Network error".tl);
      if (mounted) {
        setState(() {
          json = [];
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller.text = appdata.settings['comicSourceListUrl'];
    load();
  }

  @override
  void dispose() {
    super.dispose();
    if (changed) {
      appdata.settings['comicSourceListUrl'] = controller.text;
      appdata.saveData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(title: "Comic Source".tl, body: buildBody());
  }

  Widget buildBody() {
    var currentKey = ComicSource.all().map((e) => e.key).toList();

    return ListView.builder(
      itemCount: (json?.length ?? 1) + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
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
                  leading: Icon(Icons.source_outlined),
                  title: Text("Repo URL".tl),
                ),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "URL",
                    border: const UnderlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onChanged: (value) {
                    changed = true;
                  },
                ).paddingHorizontal(16).paddingBottom(8),
                Text(
                  "The URL should point to a 'index.json' file".tl,
                ).paddingLeft(16),
                Text(
                  "Do not report any issues related to sources to App repo.".tl,
                ).paddingLeft(16),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        launchUrlString(
                          "https://github.com/venera-app/venera/blob/master/doc/comic_source.md",
                        );
                      },
                      child: Text("Help".tl),
                    ),
                    FilledButton.tonal(
                      onPressed: load,
                      child: Text("Refresh".tl),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        }

        if (index == 1 && json == null) {
          return Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(24).fixHeight(24),
          );
        }

        index--;

        var key = json![index]["key"];
        var action = currentKey.contains(key)
            ? const Icon(Icons.check, size: 20).paddingRight(8)
            : Button.filled(
                child: Text("Add".tl),
                onPressed: () async {
                  var fileName = json![index]["fileName"];
                  var url = json![index]["url"];
                  if (url == null || !(url.toString()).isURL) {
                    var listUrl =
                        appdata.settings['comicSourceListUrl'] as String;
                    if (listUrl
                        .replaceFirst("https://", "")
                        .replaceFirst("http://", "")
                        .contains("/")) {
                      url =
                          listUrl.substring(0, listUrl.lastIndexOf("/") + 1) +
                          fileName;
                    } else {
                      url = '$listUrl/$fileName';
                    }
                  }
                  await widget.onAdd(
                    url,
                    sourceKey: json![index]["key"]?.toString(),
                    fileName: fileName?.toString(),
                  );
                  setState(() {});
                },
              ).fixHeight(32);

        var description = json![index]["version"];
        if (json![index]["description"] != null) {
          description = "$description\n${json![index]["description"]}";
        }

        return ListTile(
          title: Text(json![index]["name"]),
          subtitle: Text(description),
          trailing: action,
        );
      },
    );
  }
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onCommit, {this.onCancel});

  final String path;

  final Future<void> Function(String value) onCommit;
  final Future<void> Function()? onCancel;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';
  var _saving = false;

  @override
  void initState() {
    super.initState();
    current = io.File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    if (!_saving) unawaited(widget.onCancel?.call());
    super.dispose();
  }

  Future<void> _commit() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onCommit(current);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        context.showMessage(message: error.toString());
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Edit".tl),
        actions: [
          IconButton(
            onPressed: _saving ? null : _commit,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          var source = ComicSource.find(key)!;
          await ComicSourcePage.update(source, false);
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        context.showMessage(message: e.toString());
      }
      loadingController.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Text(source.name, style: ts.s18),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source.version,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (hasUpdate)
                  Tooltip(
                    message: newVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "New Version".tl,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ).paddingLeft(4),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: (current as String).ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
            source.key,
          );
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
            widget.source.key,
          );
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
            widget.source.key,
          );
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
        widget.source.key,
      );
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
          widget.source.key,
        );
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
