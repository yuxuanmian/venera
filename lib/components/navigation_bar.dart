part of 'components.dart';

class PaneItemEntry {
  String label;

  IconData icon;

  IconData activeIcon;

  PaneItemEntry({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }
}

typedef NaviItemTapListener = void Function(int);

class NaviPaneState extends State<NaviPane>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _canPop = true;

  late int _currentPage = widget.initialPage;

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;
  late final AnimationController _tabTransition;
  late double _indicatorStart = currentPage.toDouble();
  int? _previousPage;
  double _outgoingOpacity = 1;
  static const _incomingTabCurve = Interval(.22, 1, curve: Curves.easeOut);
  static const _outgoingTabEnd = .42;
  static const _outgoingTabCurve = Interval(
    0,
    _outgoingTabEnd,
    curve: Curves.easeInOut,
  );
  final _heroController = MaterialApp.createMaterialHeroController();

  double get _indicatorPosition => ui.lerpDouble(
    _indicatorStart,
    currentPage.toDouble(),
    Curves.easeOutCubic.transform(_tabTransition.value),
  )!;

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  static const _kBottomBarHeight = 58.0;

  static const _kFoldedSideBarWidth = 72.0;

  static const _kSideBarWidth = 224.0;

  static const _kTopBarHeight = 48.0;

  double get bottomBarHeight =>
      _kBottomBarHeight + MediaQuery.of(context).padding.bottom;

  void onNavigatorStateChange() {
    onRebuild(_mediaQueryData() ?? MediaQueryData());
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    if (currentPage == index) {
      return;
    }
    setState(() {
      _indicatorStart = _indicatorPosition;
      _outgoingOpacity = _incomingTabCurve.transform(_tabTransition.value);
      _previousPage = currentPage;
      currentPage = index;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _tabTransition.value = 1;
    } else {
      _tabTransition.forward(from: 0);
    }
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    _tabTransition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    );
    widget.observer.addListener(onNavigatorStateChange);
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    _tabTransition.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    super.dispose();
  }

  double targetFormContext(MediaQueryData mq) {
    var width = mq.size.width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  /// Snapshot of the metrics this pane's layout depends on, read without
  /// registering a [MediaQuery] dependency. Keyboard inset (viewInsets)
  /// changes therefore don't rebuild the pane and its whole navigator subtree
  /// on every animation frame; [didChangeMetrics] re-syncs the snapshot when
  /// the metrics that matter (size / viewPadding / systemGestureInsets)
  /// actually change, e.g. rotation or window resize.
  ({Size size, EdgeInsets viewPadding, EdgeInsets systemGestureInsets})?
  _layoutMetrics;

  MediaQueryData? _mediaQueryData() =>
      context.getInheritedWidgetOfExactType<MediaQuery>()?.data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _layoutMetrics ??= _readLayoutMetrics();
  }

  @override
  void didChangeMetrics() {
    final metrics = _readLayoutMetrics();
    if (metrics == null || metrics == _layoutMetrics) {
      return;
    }
    _layoutMetrics = metrics;
    if (mounted) {
      setState(() {});
    }
  }

  ({Size size, EdgeInsets viewPadding, EdgeInsets systemGestureInsets})?
  _readLayoutMetrics() {
    // Read from the platform dispatcher: [didChangeMetrics] fires before the
    // widget tree is rebuilt with the new metrics, so the inherited
    // [MediaQuery] would still hold the stale snapshot at that point.
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) {
      return null;
    }
    final dpr = view.devicePixelRatio;
    EdgeInsets divide(ui.ViewPadding padding) => EdgeInsets.fromLTRB(
      padding.left / dpr,
      padding.top / dpr,
      padding.right / dpr,
      padding.bottom / dpr,
    );
    return (
      size: view.physicalSize / dpr,
      viewPadding: divide(view.viewPadding),
      systemGestureInsets: divide(view.systemGestureInsets),
    );
  }

  void onRebuild(MediaQueryData mq) {
    double target = targetFormContext(mq);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = _mediaQueryData() ?? MediaQueryData();
    onRebuild(mq);
    final sideInsets = (App.isMobile && mq.orientation == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(mq.viewPadding.left, mq.systemGestureInsets.left),
            right: math.max(mq.viewPadding.right, mq.systemGestureInsets.right),
          )
        : EdgeInsets.zero;
    return _NaviPopScope(
      action: () {
        if (App.mainNavigatorKey!.currentState!.canPop()) {
          App.mainNavigatorKey!.currentState!.maybePop();
        } else {
          SystemNavigator.pop();
        }
      },
      popGesture: App.isIOS && mq.size.width >= changePoint,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final value = controller.value;
          Widget content = Stack(
            children: [
              Positioned(
                left: _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0)),
                top: 0,
                bottom: 0,
                child: buildLeft(mq),
              ),
              Positioned.fill(
                left:
                    _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
                    (_kSideBarWidth - _kFoldedSideBarWidth) *
                        ((value - 2).clamp(0, 1)),
                child: buildMainView(),
              ),
            ],
          );
          if (sideInsets != EdgeInsets.zero) {
            content = Padding(padding: sideInsets, child: content);
          }
          return content;
        },
      ),
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: _heroController,
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          widget.navigatorKey.currentState?.maybePop(result);
        },
        child: NotificationListener<NavigationNotification>(
          onNotification: (NavigationNotification notification) {
            final bool nextCanPop = !notification.canHandlePop;
            if (nextCanPop != _canPop) {
              setState(() {
                _canPop = nextCanPop;
              });
            }
            return false;
          },
          child: Navigator(
            observers: [widget.observer],
            key: widget.navigatorKey,
            onGenerateRoute: (settings) => AppPageRoute(
              preventRebuild: false,
              builder: (context) {
                return _NaviMainView(state: this);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : _tabTransition.duration!,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, if (current != null) current],
                ),
                child: Text(
                  widget.paneItems[currentPage].label,
                  key: ValueKey(currentPage),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            for (var action in widget.paneActions)
              Tooltip(
                message: action.label,
                child: IconButton(
                  icon: Icon(action.icon),
                  onPressed: action.onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    return Material(
      textStyle: Theme.of(context).textTheme.labelSmall,
      elevation: 0,
      child: Container(
        height: _kBottomBarHeight,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemCount = widget.paneItems.length;
            if (itemCount == 0) return const SizedBox.shrink();
            final itemWidth = constraints.maxWidth / itemCount;
            final rtl = Directionality.of(context) == TextDirection.rtl;
            return Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _tabTransition,
                  builder: (context, child) {
                    final position = rtl
                        ? itemCount - 1 - _indicatorPosition
                        : _indicatorPosition;
                    final stretch =
                        math.sin(_tabTransition.value * math.pi) * 12;
                    final width = math.min(64.0 + stretch, itemWidth);
                    return Positioned(
                      left: (position + 0.5) * itemWidth - width / 2,
                      width: width,
                      height: 28,
                      child: child!,
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(32),
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, entry) in widget.paneItems.indexed)
                      Expanded(
                        child: Semantics(
                          selected: currentPage == index,
                          button: true,
                          child: Tooltip(
                            message: entry.label,
                            child: InkWell(
                              highlightColor: Colors.transparent,
                              hoverColor: Colors.transparent,
                              splashFactory: NoSplash.splashFactory,
                              onTap: () => updatePage(index),
                              child: Icon(
                                currentPage == index
                                    ? entry.activeIcon
                                    : entry.icon,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildLeft(MediaQueryData mq) {
    final value = controller.value;
    const paddingHorizontal = 12.0;
    return Material(
      child: Container(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: paddingHorizontal),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 16),
            SizedBox(height: mq.padding.top),
            ...List<Widget>.generate(
              widget.paneItems.length,
              (index) => _SideNaviWidget(
                enabled: currentPage == index,
                entry: widget.paneItems[index],
                showTitle: value == 3,
                onTap: () {
                  updatePage(index);
                },
                key: ValueKey(index),
              ),
            ),
            const Spacer(),
            ...List<Widget>.generate(
              widget.paneActions.length,
              (index) => _PaneActionWidget(
                entry: widget.paneActions[index],
                showTitle: value == 3,
                key: ValueKey(index + widget.paneItems.length),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(enabled ? entry.activeIcon : entry.icon);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        decoration: BoxDecoration(
          color: enabled ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    routes.removeLast();
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) {
      routes.add(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in listeners) {
      listener();
    }
  }
}

class _NaviPopScope extends StatelessWidget {
  const _NaviPopScope({
    required this.child,
    this.popGesture = false,
    required this.action,
  });

  final Widget child;
  final bool popGesture;
  final VoidCallback action;

  static bool panStartAtEdge = false;

  @override
  Widget build(BuildContext context) {
    Widget res = child;
    if (popGesture) {
      res = GestureDetector(
        onPanStart: (details) {
          if (details.globalPosition.dx < 64) {
            panStartAtEdge = true;
          }
        },
        onPanEnd: (details) {
          if (details.velocity.pixelsPerSecond.dx < 0 ||
              details.velocity.pixelsPerSecond.dx > 0) {
            if (panStartAtEdge) {
              action();
            }
          }
          panStartAtEdge = false;
        },
        onPanCancel: () {
          // A canceled pan never reaches onPanEnd; clear the flag so a later
          // unrelated pan cannot trigger a stale back action.
          panStartAtEdge = false;
        },
        child: res,
      );
    }
    return res;
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;
  final _visited = <int>{};

  @override
  void initState() {
    state.mainViewUpdateHandler = () {
      setState(() {});
    };
    super.initState();
  }

  @override
  void dispose() {
    state.mainViewUpdateHandler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var shouldShowAppBar = state.controller.value < 2;
    final ambientMediaQuery = MediaQuery.of(context);
    // While another route (e.g. the search page with its keyboard) covers the
    // tab content, the tabs are invisible: drop the bottom viewInsets from
    // their MediaQuery so the keyboard show/hide animation does not rebuild
    // this whole subtree on every frame. When the tabs are the top-most route
    // (e.g. the inline search field of the favorites tab), keep the insets so
    // the keyboard resize still applies.
    var pageMediaQuery = ambientMediaQuery.removePadding(
      removeTop: shouldShowAppBar,
    );
    if (state.widget.observer.routes.length > 1) {
      pageMediaQuery = pageMediaQuery.removeViewInsets(
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
      );
    }
    _visited.add(state.currentPage);
    return Column(
      children: [
        if (shouldShowAppBar) state.buildTop().paddingTop(context.padding.top),
        Expanded(
          child: MediaQuery(
            data: pageMediaQuery,
            child: AnimatedBuilder(
              animation: state._tabTransition,
              builder: (context, child) {
                final progress = state._tabTransition.value;
                final previous = state._previousPage;
                final direction =
                    previous == null || state.currentPage > previous
                    ? 1.0
                    : -1.0;
                final rtl = Directionality.of(context) == TextDirection.rtl;
                final offset = direction * (rtl ? -8 : 8);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final page in _visited)
                      _buildTab(page, progress, offset),
                  ],
                );
              },
            ),
          ),
        ),
        if (shouldShowAppBar)
          state.buildBottom().paddingBottom(context.padding.bottom),
      ],
    );
  }

  Widget _buildTab(int page, double progress, double offset) {
    final active = page == state.currentPage;
    final outgoing =
        page == state._previousPage && progress < NaviPaneState._outgoingTabEnd;
    final fadeIn = NaviPaneState._incomingTabCurve.transform(progress);
    final fadeOut = 1 - NaviPaneState._outgoingTabCurve.transform(progress);
    return Offstage(
      key: ValueKey(page),
      offstage: !active && !outgoing,
      child: TickerMode(
        enabled: active,
        child: ExcludeFocus(
          excluding: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: IgnorePointer(
              ignoring: !active,
              child: HeroMode(
                enabled: active,
                child: Transform.translate(
                  offset: Offset(
                    active ? offset * (1 - fadeIn) : -offset * (1 - fadeOut),
                    0,
                  ),
                  child: Opacity(
                    opacity: active ? fadeIn : fadeOut * state._outgoingOpacity,
                    child: state.widget.pageBuilder(page),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
