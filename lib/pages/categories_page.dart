import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart' show App;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';
import 'explore_page.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage>
    with TickerProviderStateMixin {
  final _selectedTabLabel = GlobalKey();
  PageStorageBucket _headerStorage = PageStorageBucket();
  TabController? _tabs;
  static const _recentSourcesKey = 'categoryBrowseSources';
  static const _sourceOrderKey = 'categorySourceOrder';
  final _changes = Listenable.merge([appdata.settings, ComicSourceManager()]);
  List<String> _recentSources = const [];
  List<String> _sourceOrder = const [];
  List<ComicSource> _sources = const [];
  ComicSource? _selected;

  @override
  void initState() {
    super.initState();
    final recent = appdata.implicitData[_recentSourcesKey];
    if (recent is List) {
      _recentSources = recent.whereType<String>().toList();
    }
    final order = appdata.implicitData[_sourceOrderKey];
    if (order is List) {
      _sourceOrder = order.whereType<String>().toSet().toList();
    }
    _updateSources();
    _changes.addListener(_onSourcesChanged);
  }

  @override
  void dispose() {
    _changes.removeListener(_onSourcesChanged);
    _tabs?.dispose();
    super.dispose();
  }

  void _onSourcesChanged() => setState(_updateSources);

  void _updateSources() {
    final previousKeys = _sources.map((source) => source.key).toList();
    final installed = ComicSource.all();
    final enabled = effectiveSourceKeys(installed.map((source) => source.key));
    final available = {
      for (final source in installed)
        if (enabled.contains(source.key) &&
            (source.categoryData != null || source.explorePages.isNotEmpty))
          source.key: source,
    };
    _storeSourceOrder({..._sourceOrder, ...available.keys}.toList());
    _sources = [
      for (final key in _sourceOrder)
        if (available[key] case final source?) source,
    ];
    final key = available.containsKey(_selected?.key)
        ? _selected!.key
        : _recentSources.where(available.containsKey).firstOrNull ??
              _legacySourceKeys().firstOrNull ??
              _sources.firstOrNull?.key;
    _selected = available[key];
    if (key != null) _remember(key);

    if (listEquals(
      previousKeys,
      _sources.map((source) => source.key).toList(),
    )) {
      return;
    }
    _tabs?.dispose();
    _tabs = null;
    if (key == null) return;

    final tabs = TabController(
      length: _sources.length,
      initialIndex: _sources.indexWhere((source) => source.key == key),
      vsync: this,
    );
    _tabs = tabs;
    _headerStorage = PageStorageBucket();
    tabs.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_tabs, tabs)) return;
      final label = _selectedTabLabel.currentContext;
      if (label != null) Scrollable.ensureVisible(label, alignment: 0.5);
    });
  }

  void _onTabChanged() {
    final source = _sources[_tabs!.index];
    _selected = source;
    _remember(source.key);
  }

  Iterable<String> _legacySourceKeys() sync* {
    final settings = appdata.settings;
    final exploreFirst = settings['initialPage'].toString() == '2';
    for (final setting
        in exploreFirst
            ? ['explore_pages', 'categories']
            : ['categories', 'explore_pages']) {
      final saved = settings[setting];
      if (saved is! List) continue;
      for (final entry in saved.whereType<String>()) {
        for (final source in _sources) {
          final matches = setting == 'categories'
              ? source.categoryData?.key == entry
              : source.explorePages.any((page) => page.title == entry);
          if (matches) yield source.key;
        }
      }
    }
  }

  void _remember(String key) {
    if (_recentSources.firstOrNull == key) return;
    _recentSources = [key, ..._recentSources.where((source) => source != key)];
    appdata.implicitData[_recentSourcesKey] = _recentSources;
    if (App.isInitialized) appdata.writeImplicitData();
  }

  void _storeSourceOrder(List<String> order) {
    if (listEquals(_sourceOrder, order)) return;
    _sourceOrder = order;
    appdata.implicitData[_sourceOrderKey] = order;
    if (App.isInitialized) appdata.writeImplicitData();
  }

  void _applySourceOrder(List<String> order) {
    if (!mounted) return;
    final available = _sources.map((source) => source.key).toSet();
    final edited = order.where(available.contains).toSet();
    final next = edited.iterator;
    // Keep inactive sources and sources added while editing in their slots.
    final merged = [
      for (final key in _sourceOrder)
        if (edited.contains(key) && next.moveNext()) next.current else key,
    ];
    if (listEquals(_sourceOrder, merged)) return;
    setState(() {
      _storeSourceOrder(merged);
      _updateSources();
    });
  }

  Future<void> _pickSource() async {
    final key = await context.to<String>(
      () => _SourcePickerPage(
        sources: _sources,
        recentSources: _recentSources,
        selectedKey: _selected?.key,
        onOrderConfirmed: _applySourceOrder,
      ),
    );
    if (!mounted || key == null) return;
    final index = _sources.indexWhere((source) => source.key == key);
    if (index >= 0) _tabs?.animateTo(index);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (tabs == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No Category Pages'.tl),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => context.to(() => const ComicSourcePage()),
              child: Text('Manage'.tl),
            ),
          ],
        ),
      );
    }

    return Material(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: context.colorScheme.outlineVariant,
                    width: 0.6,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: PageStorage(
                      bucket: _headerStorage,
                      child: AppTabBar(
                        key: ObjectKey(tabs),
                        controller: tabs,
                        withUnderLine: false,
                        tabs: [
                          for (final source in _sources)
                            Tab(
                              key: ValueKey(source.key),
                              child: Text(
                                source.name,
                                key: source.key == _selected?.key
                                    ? _selectedTabLabel
                                    : null,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_sources.length > 1)
                    IconButton(
                      key: const Key('category-source-picker'),
                      tooltip: 'Select comic source'.tl,
                      icon: const Icon(Icons.list_alt_outlined),
                      onPressed: _pickSource,
                    ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [
                  for (final source in _sources)
                    _SourceCategories(
                      key: ValueKey(source.key),
                      source: source,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcePickerPage extends StatefulWidget {
  const _SourcePickerPage({
    required this.sources,
    required this.recentSources,
    required this.selectedKey,
    required this.onOrderConfirmed,
  });

  final List<ComicSource> sources;
  final List<String> recentSources;
  final String? selectedKey;
  final ValueChanged<List<String>> onOrderConfirmed;

  @override
  State<_SourcePickerPage> createState() => _SourcePickerPageState();
}

class _SourcePickerPageState extends State<_SourcePickerPage> {
  List<ComicSource>? _draft;
  String _query = '';

  late final List<ComicSource> _searchOrder = _buildSearchOrder();

  List<ComicSource> _buildSearchOrder() {
    final byKey = {for (final source in widget.sources) source.key: source};
    return [
      for (final key in {...widget.recentSources, ...byKey.keys})
        if (byKey[key] case final source?) source,
    ];
  }

  void _startSorting() {
    FocusScope.of(context).unfocus();
    setState(() => _draft = List.of(widget.sources));
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return Scaffold(
      key: const Key('category-source-picker-page'),
      appBar: Appbar(
        title: Text('Select comic source'.tl),
        actions: [
          TextButton(
            onPressed: draft == null
                ? _startSorting
                : () {
                    widget.onOrderConfirmed(
                      draft.map((source) => source.key).toList(),
                    );
                    context.pop();
                  },
            child: Text((draft == null ? 'Sort' : 'Done').tl),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: draft == null ? _buildPicker() : _buildSorter(draft),
          ),
        ),
      ),
    );
  }

  Widget _buildPicker() {
    final matches = _searchOrder
        .where(
          (source) =>
              source.name.toLowerCase().contains(_query) ||
              source.key.toLowerCase().contains(_query),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search Sources'.tl,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (text) =>
                setState(() => _query = text.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: matches.isEmpty
              ? Center(child: Text('No matching sources'.tl))
              : ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final source = matches[index];
                    return _sourceTile(
                      source,
                      onTap: () => context.pop(source.key),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSorter(List<ComicSource> draft) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: draft.length,
      onReorderItem: (oldIndex, newIndex) => setState(() {
        final source = draft.removeAt(oldIndex);
        draft.insert(newIndex, source);
      }),
      itemBuilder: (context, index) => _sourceTile(
        draft[index],
        trailing: ReorderableDragStartListener(
          index: index,
          child: Tooltip(
            message: 'Reorder'.tl,
            child: const SizedBox.square(
              dimension: 48,
              child: Icon(Icons.drag_handle, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceTile(
    ComicSource source, {
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final selected = source.key == widget.selectedKey;
    return ListTile(
      key: ValueKey(source.key),
      dense: true,
      minTileHeight: 48,
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      selected: selected,
      trailing:
          trailing ?? (selected ? const Icon(Icons.check, size: 18) : null),
      onTap: onTap,
    );
  }
}

class _SourceCategories extends StatelessWidget {
  const _SourceCategories({super.key, required this.source});

  final ComicSource source;

  @override
  Widget build(BuildContext context) {
    final data = source.categoryData;
    return SingleChildScrollView(
      key: PageStorageKey('categories:${source.key}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data != null) ...[
            if (data.enableRankingPage || data.buttons.isNotEmpty) ...[
              _heading(data.title.tl),
              _links([
                if (data.enableRankingPage)
                  _tag(
                    'Ranking'.tl,
                    () => context.to(() => RankingPage(sourceKey: source.key)),
                  ),
                for (final button in data.buttons)
                  _tag(button.label.tl, button.onTap),
              ]),
            ],
            for (final part in data.categories)
              StatefulBuilder(
                builder: (context, update) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (part.enableRandom)
                      Row(
                        children: [
                          Expanded(child: _heading(part.title.tl)),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Refresh'.tl,
                            onPressed: () => update(() {}),
                          ),
                        ],
                      )
                    else
                      _heading(part.title.tl),
                    _links([
                      for (final category in part.categories)
                        _tag(
                          category.label,
                          () => category.target.jump(context),
                        ),
                    ]),
                  ],
                ),
              ),
          ],
          if (source.explorePages.isNotEmpty) ...[
            _heading('Explore'.tl),
            for (final page in source.explorePages)
              ListTile(
                title: Text(page.title.ts(source.key)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.to(
                  () => SourceExplorePage(source: source, data: page),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
    child: Text(
      title,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
    ),
  );

  Widget _links(List<Widget> links) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
    child: Wrap(children: links),
  );

  Widget _tag(String label, VoidCallback onTap) {
    const shape = BorderRadius.all(Radius.circular(8));
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Builder(
        builder: (context) => Material(
          borderRadius: shape,
          color: context.colorScheme.primaryContainer.withValues(alpha: 0.72),
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}
