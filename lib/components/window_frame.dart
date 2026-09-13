import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/failure_sanitizer.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

const _kTitleBarHeight = 36.0;

class WindowFrameController extends InheritedWidget {
  /// Whether the window frame is hidden.
  final bool isWindowFrameHidden;

  /// Sets the visibility of the window frame.
  final void Function(bool) setWindowFrame;

  /// Adds a listener that will be called when close button is clicked.
  /// The listener should return `true` to allow the window to be closed.
  final void Function(WindowCloseListener listener) addCloseListener;

  /// Removes a close listener.
  final void Function(WindowCloseListener listener) removeCloseListener;

  const WindowFrameController._create({
    required this.isWindowFrameHidden,
    required this.setWindowFrame,
    required this.addCloseListener,
    required this.removeCloseListener,
    required super.child,
  });

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) {
    return false;
  }
}

class WindowFrame extends StatefulWidget {
  const WindowFrame(this.child, {super.key});

  final Widget child;

  @override
  State<WindowFrame> createState() => _WindowFrameState();

  static WindowFrameController of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<WindowFrameController>()!;
  }
}

typedef WindowCloseListener = bool Function();

class _WindowFrameState extends State<WindowFrame> {
  final _debugButtonKey = GlobalKey();

  bool isWindowFrameHidden = false;
  bool useDarkTheme = false;
  var closeListeners = <WindowCloseListener>[];

  /// Sets the visibility of the window frame.
  void setWindowFrame(bool show) {
    setState(() {
      isWindowFrameHidden = !show;
    });
  }

  void _showDebugMenu() {
    showDebugMenu(_debugButtonKey);
  }

  /// Adds a listener that will be called when close button is clicked.
  /// The listener should return `true` to allow the window to be closed.
  void addCloseListener(WindowCloseListener listener) {
    closeListeners.add(listener);
  }

  /// Removes a close listener.
  void removeCloseListener(WindowCloseListener listener) {
    closeListeners.remove(listener);
  }

  void _onClose() {
    for (var listener in closeListeners) {
      if (!listener()) {
        return;
      }
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    if (App.isMobile) return widget.child;

    Widget body = Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: isWindowFrameHidden
                  ? null
                  : const EdgeInsets.only(top: _kTitleBarHeight),
            ),
            child: widget.child,
          ),
        ),
        if (!isWindowFrameHidden)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.transparent,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(brightness: useDarkTheme ? Brightness.dark : null),
                child: Builder(
                  builder: (context) {
                    return SizedBox(
                      height: _kTitleBarHeight,
                      child: Row(
                        children: [
                          if (App.isMacOS)
                            const DragToMoveArea(
                              child: SizedBox(
                                height: double.infinity,
                                width: 16,
                              ),
                            ).paddingRight(52)
                          else
                            const SizedBox(width: 12),
                          Expanded(
                            child: DragToMoveArea(
                              child:
                                  Text(
                                        'Venera',
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color:
                                              (useDarkTheme ||
                                                  context.brightness ==
                                                      Brightness.dark)
                                              ? Colors.white
                                              : Colors.black,
                                        ),
                                      )
                                      .toAlign(Alignment.centerLeft)
                                      .paddingLeft(4 + (App.isMacOS ? 25 : 0)),
                            ),
                          ),
                          if (kDebugMode)
                            TextButton(
                              key: _debugButtonKey,
                              onPressed: _showDebugMenu,
                              child: const Text('Debug'),
                            ),
                          if (!App.isMacOS) _WindowButtons(onClose: _onClose),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );

    if (App.isLinux) {
      body = VirtualWindowFrame(child: body);
    }

    return WindowFrameController._create(
      isWindowFrameHidden: isWindowFrameHidden,
      setWindowFrame: setWindowFrame,
      addCloseListener: addCloseListener,
      removeCloseListener: removeCloseListener,
      child: body,
    );
  }
}

Future<void> showDebugMenu(GlobalKey buttonKey) async {
  final navigator = App.rootNavigatorKey.currentState;
  final overlay = navigator?.overlay;
  final buttonContext = buttonKey.currentContext;
  if (navigator == null || overlay == null || buttonContext == null) {
    return;
  }
  final overlayBox = overlay.context.findRenderObject();
  final buttonBox = buttonContext.findRenderObject();
  if (overlayBox is! RenderBox || buttonBox is! RenderBox) {
    return;
  }
  final buttonOrigin = overlayBox.globalToLocal(
    buttonBox.localToGlobal(Offset.zero),
  );
  final buttonRect = buttonOrigin & buttonBox.size;
  final value = await showMenu<String>(
    context: App.rootContext,
    useRootNavigator: true,
    position: RelativeRect.fromRect(
      Rect.fromLTRB(
        buttonRect.left,
        buttonRect.bottom,
        buttonRect.right,
        buttonRect.bottom,
      ),
      Offset.zero & overlayBox.size,
    ),
    items: [
      PopupMenuItem(
        value: 'clearFavorites',
        child: Text('Clear Favorites Cache'.tl),
      ),
      PopupMenuItem(
        value: 'clearJudgmentState',
        child: Text('Clear All Judgment Data'.tl),
      ),
      PopupMenuItem(
        value: 'forceScanAll',
        child: Text('Force Scan All Comics'.tl),
      ),
      PopupMenuItem(value: 'rerunJudgment', child: Text('Rerun Judgment'.tl)),
      PopupMenuItem(
        value: 'refreshRandomComics',
        child: Text('Random Refresh Comics'.tl),
      ),
    ],
  );
  if (value != null) {
    handleDebugMenuSelected(value);
  }
}

Future<void> showDebugMenuSheet() async {
  final value = await showModalBottomSheet<String>(
    context: App.rootContext,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text('Clear Favorites Cache'.tl),
            onTap: () => context.pop('clearFavorites'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text('Clear All Judgment Data'.tl),
            onTap: () => context.pop('clearJudgmentState'),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_check),
            title: Text('Force Scan All Comics'.tl),
            onTap: () => context.pop('forceScanAll'),
          ),
          ListTile(
            leading: const Icon(Icons.rule),
            title: Text('Rerun Judgment'.tl),
            onTap: () => context.pop('rerunJudgment'),
          ),
          ListTile(
            leading: const Icon(Icons.shuffle),
            title: Text('Random Refresh Comics'.tl),
            onTap: () => context.pop('refreshRandomComics'),
          ),
        ],
      ),
    ),
  );
  if (value != null) {
    handleDebugMenuSelected(value);
  }
}

void handleDebugMenuSelected(String value) {
  switch (value) {
    case 'clearFavorites':
      scanDebugService.cancel(ScanControlReason.cacheInvalidated);
      App.favorites.clearAllCache();
      _debugResult('Favorites cache cleared'.tl);
      break;
    case 'clearJudgmentState':
      unawaited(_clearJudgmentState());
      break;
    case 'forceScanAll':
      unawaited(_runDebugFullScan());
      break;
    case 'rerunJudgment':
      unawaited(_rerunJudgment());
      break;
    case 'refreshRandomComics':
      _debugResult(followUpdateScannerUnavailableMessage.tl);
      break;
  }
}

/// Reports the result of one Debug entry point.
///
/// The transient bubble stays the primary feedback, but it is gone long before
/// a multi-line scan or judgment summary can be read.  Mirroring the same text
/// into the persistent log is what makes those summaries reviewable after the
/// fact, so every Debug entry point reports through here rather than calling
/// `showMessage` directly.
void _debugResult(String message) {
  App.rootContext.showMessage(message: message);
  Log.info('Debug', message);
}

Future<void> _runDebugFullScan() async {
  final service = scanDebugService;
  if (service.isRunning) {
    _debugResult('Scan already running'.tl);
    return;
  }

  final scanFuture = service.startFullScan();
  final controller = showLoadingDialog(
    App.rootContext,
    message: _scanProgressMessage(service.progress.value),
    barrierDismissible: false,
    allowCancel: true,
    closeOnCancel: false,
    onCancel: service.cancel,
  );
  void onProgress() {
    controller.setMessage(_scanProgressMessage(service.progress.value));
  }

  service.progress.addListener(onProgress);
  try {
    final summary = await scanFuture;
    controller.close();
    _debugResult(_scanSummaryMessage(summary));
    await _runJudgmentAfterScan(summary);
  } catch (error) {
    controller.close();
    _debugResult('${'Scan failed'.tl}: ${_safeScanError(error)}');
    // A scan failure is reported on its own; judgment is not run and its
    // outcome must not be folded into the scan message.
  } finally {
    service.progress.removeListener(onProgress);
  }
}

/// Runs judgment once after a completed full scan.
///
/// This is the only trigger in the normal flow.  Judgment only reads persisted
/// evidence, so without it the Debug page would stay empty until someone
/// reran judgment by hand.
Future<void> _runJudgmentAfterScan(FullScanSummary summary) async {
  if (summary.disposition != FullScanDisposition.completed) return;
  try {
    final judgment = await judgmentService.run();
    _debugResult(_judgmentSummaryMessage(judgment));
  } catch (error) {
    // Judgment failures never mask the scan result: the two are reported
    // separately.
    _debugResult('${'Judgment summary'.tl}: ${_safeScanError(error)}');
  }
}

/// Contract U4.2: rerun judgment only.
///
/// One invocation always does exactly one thing — run judgment once.  It must
/// never clear state, never issue a source request, and never implicitly chain
/// a `clear()` in front of the run: FR-034 forbids that, and a button called
/// "rerun" must not silently discard every comparison baseline.  "Complete
/// rerun" is the user-driven two-step combination of
/// [clearJudgmentState] followed by this entry.
///
/// A rule change does not need a special branch here: judgment stamps each row
/// with the algorithm version that produced it and recomputes rows written by a
/// different one, so this entry covers that case while still obeying the four
/// rules above.
Future<void> _rerunJudgment() async {
  if (judgmentService.isRunning) {
    _debugResult('Judgment already running'.tl);
    return;
  }
  try {
    final summary = await judgmentService.run();
    _debugResult(_judgmentSummaryMessage(summary));
  } catch (error) {
    _debugResult('${'Judgment summary'.tl}: ${_safeScanError(error)}');
  }
}

/// Contract U4.1: cancel an in-flight scan first, then clear every judgment row.
///
/// Scan evidence survives, which is what makes this a debugging entry point
/// rather than a reset button: the same evidence can be judged again from
/// scratch, which is how "build state from zero" is observed.
///
/// The entry sits where the retired "Clear Baselines" item used to be. That item
/// was never wired to anything — it only reported that the retired follow-up
/// scanner is unavailable — and "baseline" no longer names a live concept, so
/// the slot now carries the entry that actually does something. Its label also
/// replaces "Clear Observation Facts", which described the **preserved** side of
/// the operation and so read as a different, dangerous action (wiping the
/// evidence) than the one it performed.
///
/// What it does **not** touch: scan evidence, the schedule store, the favorites
/// cache, user preferences (ADR-0016 keeps the schedule out of the judgment
/// clear on purpose).
Future<void> _clearJudgmentState() async {
  try {
    await judgmentService.clear();
    _debugResult(
      '${'Judgment data cleared'.tl} · ${'Scan evidence is kept'.tl}',
    );
  } catch (error) {
    _debugResult('${'Judgment State Unreadable'.tl}: ${_safeScanError(error)}');
  }
}

String _judgmentSummaryMessage(JudgmentSummary summary) {
  if (summary.rejectedAsRunning) return 'Judgment already running'.tl;
  final details = [
    'Judgment summary'.tl,
    '${'Judgment processed'.tl}: ${summary.processed}',
    '${'Judgment changed'.tl}: ${summary.changed}',
    '${'Judgment failed items'.tl}: ${summary.failed}',
    '${'Judgment written rows'.tl}: ${summary.writtenRows}',
  ];
  // "No pending observations" is reported honestly rather than as a silent
  // success (Contract U4.2).
  if (summary.writtenRows == 0) {
    details.add('No pending observations, no rows written'.tl);
  }
  return details.join(' · ');
}

String _scanProgressMessage(ScanProgress progress) => [
  '${'Scan works found'.tl}: ${progress.discoveredWorks}',
  '${'Scan works active'.tl}: ${progress.activeWorks}',
  '${'Persisted items'.tl}: ${progress.persistedItems}',
  '${'Scan works failed'.tl}: ${progress.failedWorks}',
  if (progress.canceledWorks > 0)
    '${'Scan works canceled'.tl}: ${progress.canceledWorks}',
  if (progress.skippedSources.isNotEmpty)
    '${'Skipped sources'.tl}: ${progress.skippedSources.map(_scanSkipText).join(', ')}',
].join('\n');

String _scanSummaryMessage(FullScanSummary summary) {
  final progress = summary.progress;
  final disposition = switch (summary.disposition) {
    FullScanDisposition.completed => 'Scan completed'.tl,
    FullScanDisposition.canceled => 'Scan canceled'.tl,
    FullScanDisposition.failed => 'Scan failed'.tl,
    FullScanDisposition.alreadyRunning => 'Scan already running'.tl,
  };
  final details = [
    disposition,
    '${'Scan works found'.tl}: ${progress.discoveredWorks}',
    '${'Persisted items'.tl}: ${progress.persistedItems}',
    '${'Scan works failed'.tl}: ${progress.failedWorks}',
    '${'Scan works canceled'.tl}: ${progress.canceledWorks}',
    '${'Skipped sources'.tl}: ${progress.skippedSources.isEmpty ? 0 : progress.skippedSources.map(_scanSkipText).join(', ')}',
    if (summary.errorMessage != null) summary.errorMessage!,
  ];
  return details.join(' · ');
}

String _scanSkipText(ScanSourceSkip skip) {
  final reason = switch (skip.reason) {
    ScanSourceSkipReason.absent => 'Source capability absent'.tl,
    ScanSourceSkipReason.invalid => 'Source capability invalid'.tl,
    ScanSourceSkipReason.disabled => 'Source disabled'.tl,
    ScanSourceSkipReason.notLoggedIn => 'Source not logged in'.tl,
  };
  return '${skip.sourceKey} ($reason)';
}

String _safeScanError(Object error) {
  final raw = error is ScanStorageException
      ? error.message
      : 'Scan operation failed (${error.runtimeType})';
  return FailureSanitizer.sanitize({'message': raw}).message ??
      'Scan failed'.tl;
}

class _WindowButtons extends StatefulWidget {
  const _WindowButtons({required this.onClose});

  final void Function() onClose;

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool isMaximized = false;

  @override
  void initState() {
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (value) {
        setState(() {
          isMaximized = true;
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    setState(() {
      isMaximized = true;
    });
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      isMaximized = false;
    });
    super.onWindowUnmaximize();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? Colors.white : Colors.black;
    final hoverColor = dark ? Colors.white30 : Colors.black12;

    return SizedBox(
      width: 138,
      height: _kTitleBarHeight,
      child: Row(
        children: [
          WindowButton(
            icon: MinimizeIcon(color: color),
            hoverColor: hoverColor,
            onPressed: () async {
              bool isMinimized = await windowManager.isMinimized();
              if (isMinimized) {
                windowManager.restore();
              } else {
                windowManager.minimize();
              }
            },
          ),
          if (isMaximized)
            WindowButton(
              icon: RestoreIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () {
                windowManager.unmaximize();
              },
            )
          else
            WindowButton(
              icon: MaximizeIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () {
                windowManager.maximize();
              },
            ),
          WindowButton(
            icon: CloseIcon(color: color),
            hoverIcon: CloseIcon(color: !dark ? Colors.white : Colors.black),
            hoverColor: Colors.red,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

class WindowButton extends StatefulWidget {
  const WindowButton({
    required this.icon,
    required this.onPressed,
    required this.hoverColor,
    this.hoverIcon,
    super.key,
  });

  final Widget icon;

  final void Function() onPressed;

  final Color hoverColor;

  final Widget? hoverIcon;

  @override
  State<WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<WindowButton> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) => setState(() {
        isHovering = true;
      }),
      onExit: (event) => setState(() {
        isHovering = false;
      }),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: double.infinity,
          decoration: BoxDecoration(
            color: isHovering ? widget.hoverColor : null,
          ),
          child: isHovering ? widget.hoverIcon ?? widget.icon : widget.icon,
        ),
      ),
    );
  }
}

/// Close
class CloseIcon extends StatelessWidget {
  final Color color;

  const CloseIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_ClosePainter(color));
}

class _ClosePainter extends _IconPainter {
  _ClosePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color, true);
    canvas.drawLine(const Offset(0, 0), Offset(size.width, size.height), p);
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), p);
  }
}

/// Maximize
class MaximizeIcon extends StatelessWidget {
  final Color color;

  const MaximizeIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_MaximizePainter(color));
}

class _MaximizePainter extends _IconPainter {
  _MaximizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width - 1, size.height - 1), p);
  }
}

/// Restore
class RestoreIcon extends StatelessWidget {
  final Color color;

  const RestoreIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_RestorePainter(color));
}

class _RestorePainter extends _IconPainter {
  _RestorePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 2, size.width - 2, size.height), p);
    canvas.drawLine(const Offset(2, 2), const Offset(2, 0), p);
    canvas.drawLine(const Offset(2, 0), Offset(size.width, 0), p);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, size.height - 2),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height - 2),
      Offset(size.width - 2, size.height - 2),
      p,
    );
  }
}

/// Minimize
class MinimizeIcon extends StatelessWidget {
  final Color color;

  const MinimizeIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) => _AlignedPaint(_MinimizePainter(color));
}

class _MinimizePainter extends _IconPainter {
  _MinimizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint p = getPaint(color);
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      p,
    );
  }
}

/// Helpers
abstract class _IconPainter extends CustomPainter {
  _IconPainter(this.color);

  final Color color;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AlignedPaint extends StatelessWidget {
  const _AlignedPaint(this.painter);

  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: CustomPaint(size: const Size(10, 10), painter: painter),
    );
  }
}

Paint getPaint(Color color, [bool isAntiAlias = false]) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..isAntiAlias = isAntiAlias
  ..strokeWidth = 1;

class WindowPlacement {
  final Rect rect;

  final bool isMaximized;

  const WindowPlacement(this.rect, this.isMaximized);

  Future<void> applyToWindow() async {
    await windowManager.setBounds(rect);

    if (!validate(rect)) {
      await windowManager.center();
    }

    if (isMaximized) {
      await windowManager.maximize();
    }
  }

  Future<void> writeToFile() async {
    var file = File("${App.dataPath}/window_placement");
    await file.writeAsString(
      jsonEncode({
        'width': rect.width,
        'height': rect.height,
        'x': rect.topLeft.dx,
        'y': rect.topLeft.dy,
        'isMaximized': isMaximized,
      }),
    );
  }

  static Future<WindowPlacement> loadFromFile() async {
    try {
      var file = File("${App.dataPath}/window_placement");
      if (!file.existsSync()) {
        return defaultPlacement;
      }
      var json = jsonDecode(await file.readAsString());
      var rect = Rect.fromLTWH(
        json['x'],
        json['y'],
        json['width'],
        json['height'],
      );
      return WindowPlacement(rect, json['isMaximized']);
    } catch (e) {
      return defaultPlacement;
    }
  }

  static Rect? lastValidRect;

  static Future<WindowPlacement> get current async {
    var rect = await windowManager.getBounds();
    if (validate(rect)) {
      lastValidRect = rect;
    } else {
      rect = lastValidRect ?? defaultPlacement.rect;
    }
    var isMaximized = await windowManager.isMaximized();
    return WindowPlacement(rect, isMaximized);
  }

  static const defaultPlacement = WindowPlacement(
    Rect.fromLTWH(10, 10, 900, 600),
    false,
  );

  static WindowPlacement cache = defaultPlacement;

  static Timer? timer;

  static void loop() async {
    timer ??= Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      var placement = await WindowPlacement.current;
      if (placement.rect != cache.rect ||
          placement.isMaximized != cache.isMaximized) {
        cache = placement;
        await placement.writeToFile();
      }
    });
  }

  static bool validate(Rect rect) {
    return rect.topLeft.dx >= 0 && rect.topLeft.dy >= 0;
  }
}

class VirtualWindowFrame extends StatefulWidget {
  const VirtualWindowFrame({super.key, required this.child});

  /// The [child] contained by the VirtualWindowFrame.
  final Widget child;

  @override
  State<StatefulWidget> createState() => _VirtualWindowFrameState();
}

class _VirtualWindowFrameState extends State<VirtualWindowFrame>
    with WindowListener {
  bool _isFocused = true;
  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Widget _buildVirtualWindowFrame(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_isMaximized ? 0 : 8),
        color: Colors.transparent,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.toOpacity(_isFocused ? 0.4 : 0.2),
            blurRadius: 4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      enableResizeEdges: (_isMaximized || _isFullScreen) ? [] : null,
      child: Padding(
        padding: EdgeInsets.all(_isMaximized ? 0 : 4),
        child: _buildVirtualWindowFrame(context),
      ),
    );
  }

  @override
  void onWindowFocus() {
    setState(() {
      _isFocused = true;
    });
  }

  @override
  void onWindowBlur() {
    setState(() {
      _isFocused = false;
    });
  }

  @override
  void onWindowMaximize() {
    setState(() {
      _isMaximized = true;
    });
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      _isMaximized = false;
    });
  }

  @override
  void onWindowEnterFullScreen() {
    setState(() {
      _isFullScreen = true;
    });
  }

  @override
  void onWindowLeaveFullScreen() {
    setState(() {
      _isFullScreen = false;
    });
  }
}

// ignore: non_constant_identifier_names
TransitionBuilder VirtualWindowFrameInit() {
  return (_, Widget? child) {
    return VirtualWindowFrame(child: child!);
  };
}
