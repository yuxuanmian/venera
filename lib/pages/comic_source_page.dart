import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/source_pages.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/init.dart' show catalogController;
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/settings/settings_page.dart'
    show CatalogRepositorySettings;
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/translations.dart';

const comicSourcePreviewLimit = 6;

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key, this.preferences, this.controller});

  @visibleForTesting
  final SourcePreferences? preferences;
  final CatalogController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _EnabledComicSourceHome(
        preferences: preferences,
        controller: controller ?? catalogController,
      ),
    );
  }
}

class _EnabledComicSourceHome extends StatefulWidget {
  const _EnabledComicSourceHome({this.preferences, this.controller});

  final SourcePreferences? preferences;
  final CatalogController? controller;

  @override
  State<_EnabledComicSourceHome> createState() =>
      _EnabledComicSourceHomeState();
}

class _EnabledComicSourceHomeState extends State<_EnabledComicSourceHome> {
  late final SourcePreferences _preferences;
  late final bool _ownsPreferences;

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences ?? appSourcePreferences();
    _ownsPreferences = widget.preferences == null;
    ComicSourceManager().addListener(_refresh);
    _preferences.addListener(_refresh);
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(_refresh);
    _preferences.removeListener(_refresh);
    if (_ownsPreferences) _preferences.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  List<ComicSource> get _enabledSources {
    final all = ComicSourceManager().all();
    final effective = _preferences.effectiveKeysFor(
      all.map((item) => item.key),
    );
    return all.where((source) => effective.contains(source.key)).toList();
  }

  Future<void> _openSelection() async {
    await context.to(
      () => ComicSourceSelectionPage(
        preferences: _preferences,
        onComplete: () => Navigator.of(context).pop(),
        onCancel: () => Navigator.of(context).pop(),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabledSources;
    final visible = enabled.take(comicSourcePreviewLimit).toList();
    return CustomScrollView(
      slivers: [
        SliverAppbar(
          title: Text('Comic Source'.tl),
          style: AppbarStyle.shadow,
          actions: [
            if (widget.controller case final controller?)
              IconButton(
                tooltip: '配置仓库'.tl,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.to(
                  () => CatalogRepositorySettings(controller: controller),
                ),
              ),
          ],
        ),
        SliverToBoxAdapter(
          child: ListTile(
            key: const Key('manage-comic-sources'),
            leading: const Icon(Icons.tune),
            title: Text('Manage comic sources'.tl),
            subtitle: Text(
              'Select sources to show and use for local update tracking'.tl,
            ),
            trailing: const Icon(Icons.arrow_right),
            onTap: _openSelection,
          ),
        ),
        if (enabled.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.source_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text('No comic sources enabled'.tl, style: ts.s18),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('choose-comic-sources-empty'),
                      onPressed: _openSelection,
                      child: Text('Choose comic sources'.tl),
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Enabled comic sources'.tl, style: ts.s18),
            ),
          ),
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final source = visible[index];
              return _CompactEnabledSourceRow(
                key: Key('enabled-source-row-${source.key}'),
                source: source,
                onTap: () =>
                    context.to(() => ComicSourceDetailPage(source: source)),
              );
            },
          ),
          if (enabled.length > comicSourcePreviewLimit)
            SliverToBoxAdapter(
              child: ListTile(
                key: const Key('view-all-enabled-sources'),
                title: Text(
                  'View all (@c sources)'.tlParams({'c': enabled.length}),
                ),
                trailing: const Icon(Icons.arrow_right),
                onTap: () => context.to(
                  () => EnabledComicSourcesPage(preferences: _preferences),
                ),
              ),
            ),
        ],
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }
}

class _CompactEnabledSourceRow extends StatelessWidget {
  const _CompactEnabledSourceRow({
    super.key,
    required this.source,
    required this.onTap,
  });

  final ComicSource source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final showLogin = source.account != null;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.extension_outlined),
      title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showLogin)
            Text(
              source.isLogged ? 'Logged in'.tl : 'Not logged in'.tl,
              style: ts.s12.copyWith(
                color: source.isLogged
                    ? context.colorScheme.primary
                    : context.colorScheme.onSurfaceVariant,
              ),
            ),
          const Icon(Icons.arrow_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

class EnabledComicSourcesPage extends StatefulWidget {
  const EnabledComicSourcesPage({super.key, required this.preferences});

  final SourcePreferences preferences;

  @override
  State<EnabledComicSourcesPage> createState() =>
      _EnabledComicSourcesPageState();
}

class _EnabledComicSourcesPageState extends State<EnabledComicSourcesPage> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(_refresh);
    ComicSourceManager().addListener(_refresh);
    widget.preferences.addListener(_refresh);
  }

  @override
  void dispose() {
    _search
      ..removeListener(_refresh)
      ..dispose();
    ComicSourceManager().removeListener(_refresh);
    widget.preferences.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final effective = widget.preferences.effectiveKeysFor(
      ComicSourceManager().all().map((source) => source.key),
    );
    final keyword = _search.text.trim().toLowerCase();
    final sources = ComicSourceManager()
        .all()
        .where((source) => effective.contains(source.key))
        .where(
          (source) =>
              keyword.isEmpty || source.name.toLowerCase().contains(keyword),
        )
        .toList();
    return Scaffold(
      appBar: Appbar(title: Text('All enabled sources'.tl)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('enabled-source-search'),
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search enabled sources'.tl,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: sources.isEmpty
                ? Center(child: Text('No matching enabled sources'.tl))
                : ListView.builder(
                    itemCount: sources.length,
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      return _CompactEnabledSourceRow(
                        key: Key('enabled-list-row-${source.key}'),
                        source: source,
                        onTap: () => context.to(
                          () => ComicSourceDetailPage(source: source),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

enum _SourceSelectionFilter { all, selected }

class ComicSourceSelectionPage extends StatefulWidget {
  const ComicSourceSelectionPage({
    super.key,
    required this.preferences,
    required this.onComplete,
    required this.onCancel,
    this.firstRun = false,
  });

  final SourcePreferences preferences;
  final VoidCallback onComplete;
  final VoidCallback onCancel;
  final bool firstRun;

  @override
  State<ComicSourceSelectionPage> createState() =>
      _ComicSourceSelectionPageState();
}

class _ComicSourceSelectionPageState extends State<ComicSourceSelectionPage> {
  final _search = TextEditingController();
  late final Set<String> _initialSelection;
  late final Set<String> _draft;
  var _filter = _SourceSelectionFilter.all;
  bool _saving = false;
  bool _confirmingDiscard = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final activeKeys = ComicSourceManager().all().map((source) => source.key);
    _initialSelection = widget.preferences.effectiveKeysFor(activeKeys).toSet();
    _draft = Set<String>.from(_initialSelection);
    _search.addListener(_refresh);
  }

  @override
  void dispose() {
    _search
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _dirty => !setEquals(_draft, _initialSelection);

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Discard unsaved changes?'.tl),
            content: Text(
              'Search and filters do not change the selection. Returning discards this draft.'
                  .tl,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Continue editing'.tl),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Discard changes'.tl),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _leave() async {
    if (_saving || _confirmingDiscard) return;
    _confirmingDiscard = true;
    try {
      if (await _confirmDiscard() && mounted) widget.onCancel();
    } finally {
      _confirmingDiscard = false;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final added = _draft.difference(_initialSelection);
    final removed = _initialSelection.difference(_draft);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.preferences.applySelectionChanges(
        added: added,
        removed: removed,
        patchSettings: (settings) {
          for (final key in added) {
            final source = ComicSourceManager().find(key);
            if (source != null) {
              settings.addAll(defaultSourcePages(settings, source));
            }
          }
        },
      );
      if (!mounted) return;
      widget.onComplete();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save comic source selection. Try again.'.tl;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _search.text.trim().toLowerCase();
    final allSources = ComicSourceManager().all();
    final visible = allSources.where((source) {
      final matchesName =
          keyword.isEmpty || source.name.toLowerCase().contains(keyword);
      final matchesFilter =
          _filter == _SourceSelectionFilter.all || _draft.contains(source.key);
      return matchesName && matchesFilter;
    }).toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: Appbar(
          title: Text(
            widget.firstRun
                ? 'Choose comic sources'.tl
                : 'Manage comic sources'.tl,
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _saving ? null : _leave,
          ),
          actions: [
            Center(
              child: Text(
                'Selected @a of @b'.tlParams({
                  'a': _draft.length,
                  'b': allSources.length,
                }),
                style: ts.s14,
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                key: const Key('source-selection-search'),
                controller: _search,
                enabled: !_saving,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search comic sources'.tl,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SegmentedButton<_SourceSelectionFilter>(
                segments: [
                  ButtonSegment(
                    value: _SourceSelectionFilter.all,
                    label: Text('All'.tl),
                  ),
                  ButtonSegment(
                    value: _SourceSelectionFilter.selected,
                    label: Text('Selected'.tl),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: _saving
                    ? null
                    : (selection) {
                        setState(() => _filter = selection.single);
                      },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(color: context.colorScheme.error),
                  ),
                ),
              ),
            Expanded(
              child: visible.isEmpty
                  ? Center(child: Text('No matching comic sources'.tl))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final source = visible[index];
                        return CheckboxListTile(
                          key: Key('source-selection-${source.key}'),
                          value: _draft.contains(source.key),
                          onChanged: _saving
                              ? null
                              : (selected) {
                                  setState(() {
                                    if (selected == true) {
                                      _draft.add(source.key);
                                    } else {
                                      _draft.remove(source.key);
                                    }
                                  });
                                },
                          title: Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.trailing,
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('save-comic-source-selection'),
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…'.tl : 'Save selection'.tl),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ComicSourceDetailPage extends StatelessWidget {
  const ComicSourceDetailPage({super.key, required this.source});

  final ComicSource source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppbar(title: Text(source.name), style: AppbarStyle.shadow),
          _SliverComicSource(key: ValueKey(source.filePath), source: source),
          SliverPadding(
            padding: EdgeInsets.only(bottom: context.padding.bottom),
          ),
        ],
      ),
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
  const _SliverComicSource({super.key, required this.source});

  final ComicSource source;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s18,
                  ),
                ),
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
    var settingsMap = source.runtimeContext == null
        ? source.settings
        : source.getSettingsDynamic() ?? source.settings;

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
