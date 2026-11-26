part of 'home_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.active = true}) : _editorRoute = false;
  const HomePage.editor({super.key}) : _editorRoute = true, active = true;

  final bool _editorRoute;
  final bool active;

  @override
  State<HomePage> createState() => _HomePageState();
}

extension on HomeModule {
  String get title => switch (this) {
    HomeModule.sync => 'Sync Data'.tl,
    HomeModule.history => 'History'.tl,
    HomeModule.recentUpdates => 'Recent updates'.tl,
    HomeModule.comicSource => 'Comic Source'.tl,
    HomeModule.imageFavorites => 'Image Favorites'.tl,
    HomeModule.local => 'Local'.tl,
  };

  IconData get icon => switch (this) {
    HomeModule.sync => Icons.sync,
    HomeModule.history => Icons.history,
    HomeModule.recentUpdates => Icons.update,
    HomeModule.comicSource => Icons.source_outlined,
    HomeModule.imageFavorites => Icons.photo_library_outlined,
    HomeModule.local => Icons.folder_outlined,
  };
}

class _HomePageState extends State<HomePage> {
  static const _motion = Duration(milliseconds: 180);

  final _scroll = ScrollController();
  final _reorderList = GlobalKey<SliverReorderableListState>();
  final _cardKeys = {
    for (final module in HomeModule.values) module: GlobalKey(),
  };
  final _transitions = <HomeModule, ({int? departingAt, Timer timer})>{};
  late List<HomeModule> _layout;
  late bool _editing;
  bool _saving = false;
  HomeModule? _lifted;
  Timer? _liftTimer;

  Duration get _duration =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : _motion;

  bool _available(HomeModule module) =>
      module != HomeModule.sync || DataSync.isAutoSyncEnabled;

  List<HomeModule> _readLayout() =>
      HomeModule.readLayout(appdata.settings[homeModuleLayoutSetting]);

  @override
  void initState() {
    super.initState();
    _layout = _readLayout();
    _editing = widget._editorRoute;
    appdata.settings.addListener(_onSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_editing && !widget.active) _finishEditing();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    _scroll.dispose();
    _liftTimer?.cancel();
    for (final transition in _transitions.values) {
      transition.timer.cancel();
    }
    super.dispose();
  }

  void _onSettingsChanged() {
    setState(() {
      if (!_saving) _layout = _readLayout();
    });
  }

  Future<bool> _saveLayout(List<HomeModule> layout) async {
    if (_saving) return false;
    setState(() {
      _layout = layout;
      _saving = true;
    });
    try {
      await appdata.persistHomeModuleLayout(layout);
      return true;
    } catch (error, stack) {
      Log.error('Home modules', error.toString(), stack);
      if (mounted) {
        context.showMessage(message: 'Failed to save home layout'.tl);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _layout = _readLayout();
          _saving = false;
        });
      }
    }
  }

  void _startEditing([HomeModule? module]) {
    if (_editing) return;
    setState(() {
      _editing = true;
      _lifted = module;
    });
    if (module != null) {
      _liftTimer = Timer(_duration, () => setState(() => _lifted = null));
    }
  }

  void _finishEditing() {
    _reorderList.currentState?.cancelReorder();
    _liftTimer?.cancel();
    for (final transition in _transitions.values) {
      transition.timer.cancel();
    }
    _transitions.clear();
    if (widget._editorRoute) {
      context.pop();
    } else {
      setState(() {
        _editing = false;
        _lifted = null;
      });
    }
  }

  void _animate(HomeModule module, {int? departingAt}) {
    _transitions.remove(module)?.timer.cancel();
    if (_duration == Duration.zero) return;
    final timer = Timer(_duration, () {
      if (mounted) setState(() => _transitions.remove(module));
    });
    _transitions[module] = (departingAt: departingAt, timer: timer);
  }

  Future<void> _hide(HomeModule module, int visibleIndex) async {
    if (_saving || !_layout.contains(module)) return;
    _reorderList.currentState?.cancelReorder();
    _animate(module, departingAt: visibleIndex);
    await _saveLayout([..._layout]..remove(module));
  }

  Future<void> _addModules() async {
    if (_saving) return;
    _reorderList.currentState?.cancelReorder();
    final choices = HomeModule.values
        .where((module) => _available(module) && !_layout.contains(module))
        .toList();
    if (choices.isEmpty) return;
    final selected = await showModalBottomSheet<List<HomeModule>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: _duration == Duration.zero
          ? AnimationStyle.noAnimation
          : null,
      builder: (context) => _HomeModulePicker(choices),
    );
    if (!mounted || !_editing || selected == null || _saving) return;
    final added = selected
        .where((module) => !_layout.contains(module))
        .toList();
    if (added.isEmpty) return;
    for (final module in added) {
      _animate(module);
    }
    final duration = _duration;
    if (!await _saveLayout([..._layout, ...added])) return;
    await Future<void>.delayed(duration);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_editing || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (duration == Duration.zero) {
      _scroll.jumpTo(end);
    } else {
      unawaited(
        _scroll.animateTo(end, duration: duration, curve: Curves.easeOut),
      );
    }
  }

  Widget _content(HomeModule module) => switch (module) {
    HomeModule.sync => const _SyncDataWidget(),
    HomeModule.history => const _History(),
    HomeModule.recentUpdates => const FollowUpdatesWidget(asSliver: false),
    HomeModule.comicSource => const ComicSourcePreviewCard(asSliver: false),
    HomeModule.imageFavorites => const ImageFavorites(asSliver: false),
    HomeModule.local => const _Local(),
  };

  @override
  Widget build(BuildContext context) {
    final visible = _layout.where(_available).toList();
    final departing =
        _transitions.entries
            .where(
              (entry) =>
                  entry.value.departingAt != null && _available(entry.key),
            )
            .toList()
          ..sort(
            (a, b) => a.value.departingAt!.compareTo(b.value.departingAt!),
          );
    final shown = [...visible];
    for (final exit in departing) {
      if (!shown.contains(exit.key)) {
        shown.insert(exit.value.departingAt!.clamp(0, shown.length), exit.key);
      }
    }
    final duration = _duration;
    final canReorder = !_saving && departing.isEmpty;
    Widget row(BuildContext context, int index) {
      final module = shown[index];
      return KeyedSubtree(
        key: ValueKey(module),
        child: _HomeModuleTile(
          key: _cardKeys[module],
          title: module.title,
          duration: duration,
          visible: visible.contains(module),
          appearing:
              _transitions[module]?.departingAt == null &&
              _transitions.containsKey(module),
          editing: _editing,
          lifted: _lifted == module,
          handle: _editing
              ? ReorderableDragStartListener(
                  key: ValueKey('move-${module.name}'),
                  index: index,
                  enabled: canReorder,
                  child: MouseRegion(
                    cursor: canReorder
                        ? SystemMouseCursors.grab
                        : MouseCursor.defer,
                    child: Tooltip(
                      message: 'Move @a'.tlParams({'a': module.title}),
                      triggerMode: TooltipTriggerMode.manual,
                      child: const Listener(
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox.square(
                          dimension: _HomeModuleTile.cornerTargetSize,
                          child: Center(child: _HomeModuleMark()),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
          onEdit: () => _startEditing(module),
          onHide: _saving ? null : () => _hide(module, index),
          child: _content(module),
        ),
      );
    }

    final scrollView = SmoothCustomScrollView(
      controller: _scroll,
      slivers: [
        if (_editing)
          PinnedHeaderSliver(
            child: Material(
              color: context.colorScheme.surface,
              child: Padding(
                padding: EdgeInsets.only(top: context.padding.top, right: 8),
                child: Row(
                  children: [
                    const Expanded(child: _SearchBar(enabled: false)),
                    FilledButton.tonal(
                      onPressed: _finishEditing,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      child: Text('Done'.tl),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: context.padding.top),
              child: const _SearchBar(enabled: true),
            ),
          ),
        if (_editing)
          SliverReorderableList(
            key: _reorderList,
            itemBuilder: row,
            itemCount: shown.length,
            onReorderItem: (from, to) {
              if (!canReorder) return;
              final rearranged = [...visible];
              rearranged.insert(to, rearranged.removeAt(from));
              var index = 0;
              unawaited(
                _saveLayout([
                  for (final module in _layout)
                    _available(module) ? rearranged[index++] : module,
                ]),
              );
            },
            proxyDecorator: (child, index, animation) {
              if (duration == Duration.zero) return child;
              return AnimatedBuilder(
                animation: animation,
                child: child,
                builder: (context, child) => Transform.scale(
                  scale: 1 + animation.value * .015,
                  child: Material(
                    color: context.colorScheme.surface,
                    elevation: animation.value * 5,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                ),
              );
            },
          )
        else
          SliverList.builder(itemCount: shown.length, itemBuilder: row),
        if (_editing &&
            HomeModule.values.any(
              (module) => _available(module) && !_layout.contains(module),
            ))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Tooltip(
                  message: 'Add modules'.tl,
                  child: OutlinedButton(
                    onPressed: _saving ? null : _addModules,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(54, 34),
                      padding: EdgeInsets.zero,
                      side: BorderSide(
                        color: context.colorScheme.outlineVariant,
                      ),
                    ),
                    child: const Icon(Icons.add, size: 18),
                  ),
                ),
              ),
            ),
          ),
        if (shown.isEmpty && !_editing)
          SliverFillRemaining(
            hasScrollBody: false,
            child: GestureDetector(
              key: const ValueKey('empty-home'),
              behavior: HitTestBehavior.opaque,
              onLongPress: _startEditing,
              child: const Center(child: _EmptyHomeBook()),
            ),
          ),
      ],
    );
    return PopScope(
      canPop: !_editing || widget._editorRoute,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing && !widget._editorRoute) _finishEditing();
      },
      child: context.width > changePoint
          ? scrollView.paddingHorizontal(8)
          : scrollView,
    );
  }
}

class _HomeModuleTile extends StatelessWidget {
  const _HomeModuleTile({
    super.key,
    required this.title,
    required this.duration,
    required this.visible,
    required this.appearing,
    required this.editing,
    required this.lifted,
    required this.handle,
    required this.onEdit,
    required this.onHide,
    required this.child,
  });

  final String title;
  final Duration duration;
  final bool visible;
  final bool appearing;
  final bool editing;
  final bool lifted;
  final Widget? handle;
  final VoidCallback onEdit;
  final VoidCallback? onHide;
  final Widget child;

  static const cornerTargetSize = 44.0;

  Widget _corner(Widget? control) => IgnorePointer(
    ignoring: !editing,
    child: AnimatedSwitcher(
      duration: duration,
      child: control ?? const SizedBox.shrink(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final surface = editing
        ? BlurEffect(
            blur: 2.5,
            borderRadius: BorderRadius.circular(8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.surfaceBright.withValues(alpha: .45),
                    colors.surfaceContainerHighest.withValues(alpha: .35),
                  ],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          )
        : const SizedBox.expand();
    final card = IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        duration: duration,
        scale: lifted && duration != Duration.zero ? 1.015 : 1,
        child: ConstrainedBox(
          // Reserve independent touch targets even on the shortest cards.
          constraints: BoxConstraints(
            minHeight: editing ? 2 * cornerTargetSize : 0,
          ),
          child: Stack(
            children: [
              AnimatedPadding(
                duration: duration,
                padding: editing
                    ? const EdgeInsets.fromLTRB(0, 8, 14, 8)
                    : EdgeInsets.zero,
                child: GestureDetector(
                  onLongPress: editing ? null : onEdit,
                  child: ExcludeSemantics(
                    excluding: editing,
                    child: IgnorePointer(
                      ignoring: editing,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            left: 8,
                            top: 8,
                            right: 8,
                            bottom: 8,
                            child: AnimatedSwitcher(
                              duration: duration,
                              child: surface,
                            ),
                          ),
                          child,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: _corner(
                  editing
                      ? Tooltip(
                          message: 'Hide @a from home'.tlParams({'a': title}),
                          child: SizedBox.square(
                            dimension: cornerTargetSize,
                            child: Semantics(
                              button: true,
                              enabled: onHide != null,
                              child: InkResponse(
                                onTap: onHide,
                                radius: cornerTargetSize / 2,
                                child: const Center(
                                  child: _HomeModuleMark(hidesModule: true),
                                ),
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              Positioned(right: 0, bottom: 0, child: _corner(handle)),
            ],
          ),
        ),
      ),
    );
    if (duration == Duration.zero) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: appearing ? 0 : 1, end: visible ? 1 : 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: card,
      builder: (context, factor, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: factor,
          child: Opacity(opacity: factor, child: child),
        ),
      ),
    );
  }
}

class _HomeModuleMark extends StatelessWidget {
  const _HomeModuleMark({this.hidesModule = false});

  final bool hidesModule;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .7)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surface.withValues(alpha: .75),
            colors.surfaceContainerHighest.withValues(alpha: .22),
          ],
        ),
      ),
      child: Icon(
        hidesModule ? Icons.close : Icons.drag_indicator,
        color: hidesModule ? colors.error : colors.onSurfaceVariant,
        size: hidesModule ? 11 : 12,
      ),
    );
  }
}

class _HomeModulePicker extends StatefulWidget {
  const _HomeModulePicker(this.choices);

  final List<HomeModule> choices;

  @override
  State<_HomeModulePicker> createState() => _HomeModulePickerState();
}

class _HomeModulePickerState extends State<_HomeModulePicker> {
  final _selected = <HomeModule>{};

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Text('Add modules'.tl, style: ts.s18),
        const SizedBox(height: 8),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final module in widget.choices)
                CheckboxListTile(
                  value: _selected.contains(module),
                  title: Text(module.title),
                  secondary: Icon(module.icon),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(module);
                    } else {
                      _selected.remove(module);
                    }
                  }),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => context.pop(_selected.toList()),
            child: Text('Add'.tl),
          ),
        ),
      ],
    ),
  );
}

class _EmptyHomeBook extends StatelessWidget {
  const _EmptyHomeBook();

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 720),
        builder: (context, turn, _) => CustomPaint(
          size: const Size(126, 88),
          painter: BookletPainter(
            turn: AlwaysStoppedAnimation(turn),
            ink: Color.lerp(colors.outlineVariant, colors.primary, .35)!,
            paper: colors.surfaceContainer,
            leaf: colors.surfaceContainerHigh,
          ),
        ),
      ),
    );
  }
}
