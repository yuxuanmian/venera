part of 'reader.dart';

/// What one ordinary single tap means for the reader surface.
enum ReaderTapAction {
  /// The tap is swallowed: a user drag armed the scroll guard, so the tap must
  /// produce no page turn, no chapter turn and no toolbar toggle.
  consume,

  /// The tap turns to the previous page or chapter.
  previous,

  /// The tap turns to the next page or chapter.
  next,

  /// The tap toggles the toolbar (center tap, or any tap when tap-to-turn is
  /// off).
  toggleToolbar,

  /// The tap is outside the reader's responsibility (toolbar already open, or
  /// the chapter comments page).
  none,
}

/// The event input of one single-tap routing decision.
///
/// It is extracted from the gesture detector so the routing rules — in
/// particular that the scroll guard is consulted before any tap region is
/// dispatched — are directly testable.
class ReaderTapDecisionInput {
  const ReaderTapDecisionInput({
    required this.guardArmed,
    required this.toolbarOpen,
    required this.onChapterCommentsPage,
    required this.tapToTurnEnabled,
    required this.reverseTapToTurn,
    required this.mode,
    required this.position,
    required this.size,
    required this.eventTime,
    required this.isQuickTap,
    required this.lastMenuToggleTime,
    this.tapToTurnPercent = _ReaderGestureDetectorState._kTapToTurnPagePercent,
    this.menuToggleCooldown = _ReaderGestureDetectorState._kMenuToggleCooldown,
  });

  /// Whether a user drag armed [ScrollTapGuard].
  final bool guardArmed;

  /// Whether the toolbar is currently open.
  final bool toolbarOpen;

  final bool onChapterCommentsPage;

  final bool tapToTurnEnabled;

  final bool reverseTapToTurn;

  final ReaderMode mode;

  /// The tap position in global coordinates.
  final Offset position;

  /// The reader surface size.
  final Size size;

  /// The pointer-up time stamp, used to tell a quick tap from a press-and-hold.
  final Duration eventTime;

  final bool isQuickTap;

  /// Event time stamp of the last toolbar toggle, or `null` when none happened.
  final Duration? lastMenuToggleTime;

  final double tapToTurnPercent;

  final Duration menuToggleCooldown;
}

/// Routes one ordinary single tap to exactly one action.
///
/// The guard is checked first and on its own, before the toolbar state, the
/// chapter-comments shortcut and every tap-to-turn region. That ordering is the
/// contract: an armed guard makes the tap a no-op for the whole surface, so an
/// edge tap cannot turn a page behind the guard's back.
ReaderTapAction routeReaderSingleTap(ReaderTapDecisionInput input) {
  if (input.guardArmed) return ReaderTapAction.consume;
  // An open toolbar is closed by any tap, exactly as before this routing was
  // extracted: the close action does not depend on the tap being quick or on
  // the toggle cooldown.
  if (input.toolbarOpen) return ReaderTapAction.toggleToolbar;
  if (input.onChapterCommentsPage) return ReaderTapAction.none;
  if (!input.tapToTurnEnabled) {
    return readerTapToolbarOrNothing(input);
  }
  final region = readerTapRegion(input);
  switch (region) {
    case ReaderTapRegion.previous:
      return ReaderTapAction.previous;
    case ReaderTapRegion.next:
      return ReaderTapAction.next;
    case ReaderTapRegion.center:
      return readerTapToolbarOrNothing(input);
  }
}

/// The toolbar rule: only a quick tap outside the toggle cooldown toggles it.
ReaderTapAction readerTapToolbarOrNothing(ReaderTapDecisionInput input) {
  if (!input.isQuickTap) return ReaderTapAction.none;
  final lastToggle = input.lastMenuToggleTime;
  if (lastToggle != null &&
      input.eventTime - lastToggle < input.menuToggleCooldown) {
    return ReaderTapAction.none;
  }
  return ReaderTapAction.toggleToolbar;
}

/// Where a tap landed for the active reading mode.
enum ReaderTapRegion { previous, next, center }

/// The tap-to-turn region of [input], honouring the reverse-tap setting.
///
/// Kept separate from the routing decision because the mapping from a physical
/// edge to previous/next is the only part that depends on the reading direction.
ReaderTapRegion readerTapRegion(ReaderTapDecisionInput input) {
  final width = input.size.width;
  final height = input.size.height;
  final x = input.position.dx;
  final y = input.position.dy;
  final percent = input.tapToTurnPercent;
  var isLeft = false, isRight = false, isTop = false, isBottom = false;
  if (x < width * percent) {
    isLeft = true;
  } else if (x > width * (1 - percent)) {
    isRight = true;
  }
  if (y < height * percent) {
    isTop = true;
  } else if (y > height * (1 - percent)) {
    isBottom = true;
  }
  var prev = ReaderTapRegion.previous;
  var next = ReaderTapRegion.next;
  if (input.reverseTapToTurn) {
    prev = ReaderTapRegion.next;
    next = ReaderTapRegion.previous;
  }
  switch (input.mode) {
    case ReaderMode.galleryLeftToRight:
    case ReaderMode.continuousLeftToRight:
      if (isLeft) return prev;
      if (isRight) return next;
      return ReaderTapRegion.center;
    case ReaderMode.galleryRightToLeft:
    case ReaderMode.continuousRightToLeft:
      if (isLeft) return next;
      if (isRight) return prev;
      return ReaderTapRegion.center;
    case ReaderMode.galleryTopToBottom:
    case ReaderMode.continuousTopToBottom:
      if (isTop) return prev;
      if (isBottom) return next;
      return ReaderTapRegion.center;
  }
}

class _ReaderGestureDetector extends StatefulWidget {
  const _ReaderGestureDetector({required this.child});

  final Widget child;

  @override
  State<_ReaderGestureDetector> createState() => _ReaderGestureDetectorState();
}

class _ReaderGestureDetectorState
    extends AutomaticGlobalState<_ReaderGestureDetector> {
  late TapGestureRecognizer _tapGestureRecognizer;

  static const _kDoubleTapMaxTime = Duration(milliseconds: 200);

  static const _kLongPressMinTime = Duration(milliseconds: 250);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  /// Taps longer than this count as a press-and-hold and do not toggle the
  /// toolbar. A quick tap is a deliberate action, while the tap used to stop
  /// a coasting list is usually slower, so this filters the latter out.
  static const _kTapMaxDuration = Duration(milliseconds: 150);

  /// After the toolbar toggles, center taps within this window are ignored so
  /// a quick double tap in the center cannot flash the toolbar open and shut.
  static const _kMenuToggleCooldown = Duration(milliseconds: 400);

  final _dragListeners = <_DragListener>[];

  int fingers = 0;

  late _ReaderState reader;

  bool ignoreNextTag = false;

  void ignoreNextTap() {
    ignoreNextTag = true;
  }

  void clearIgnoreNextTap() {
    ignoreNextTag = false;
  }

  @override
  void initState() {
    _tapGestureRecognizer = TapGestureRecognizer()
      ..onTapUp = onTapUp
      ..onSecondaryTapUp = (details) {
        onSecondaryTapUp(details.globalPosition);
      };
    super.initState();
    context.readerScaffold._gestureDetectorState = this;
    reader = context.reader;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _lastTapDownTime = event.timeStamp;
        if (event.position == Offset.zero) {
          _previousEvent = null;
          return;
        }
        fingers++;
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        _lastTapPointer = event.pointer;
        _lastTapMoveDistance = Offset.zero;
        _tapGestureRecognizer.addPointer(event);
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onStart?.call(event.position);
          }
          _dragInProgress = false;
        }
        Future.delayed(_kLongPressMinTime, () {
          if (_lastTapPointer == event.pointer && fingers == 1) {
            if (_lastTapMoveDistance!.distanceSquared < 20.0 * 20.0) {
              onLongPressedDown(event.position);
              _longPressInProgress = true;
            } else {
              _dragInProgress = true;
              for (var dragListener in _dragListeners) {
                dragListener.onStart?.call(event.position);
                dragListener.onMove?.call(_lastTapMoveDistance!);
              }
            }
          }
        });
      },
      onPointerMove: (event) {
        if (event.pointer == _lastTapPointer) {
          _lastTapMoveDistance = event.delta + _lastTapMoveDistance!;
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onMove?.call(event.delta);
          }
        }
      },
      onPointerUp: (event) {
        _lastTapUpTime = event.timeStamp;
        fingers--;
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerCancel: (event) {
        fingers--;
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: widget.child,
    );
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage() &&
            !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter();
        }
      } else {
        if (!context.reader.toPrevPage() &&
            !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(toLastPage: true);
        }
      }
    }
  }

  TapUpDetails? _previousEvent;

  int? _lastTapPointer;

  Offset? _lastTapMoveDistance;

  /// Time stamps of the most recent pointer down/up, used to tell a quick tap
  /// from a press-and-hold.
  Duration? _lastTapDownTime;

  Duration? _lastTapUpTime;

  /// Whether the previous single tap was quick, used when a double tap is
  /// missed and the first tap's action fires immediately.
  bool _previousTapWasQuick = false;

  /// Event time stamp of the last toolbar toggle, used to suppress center
  /// taps within [_kMenuToggleCooldown].
  Duration? _lastMenuToggleTime;

  bool _longPressInProgress = false;

  bool _dragInProgress = false;

  bool get _enableDoubleTapToZoom => appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'enableDoubleTapToZoom',
  );

  void onTapUp(TapUpDetails event) {
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      _previousEvent = null;
      return;
    }
    if (_longPressInProgress) {
      _longPressInProgress = false;
      return;
    }
    final location = event.globalPosition;
    final eventTime = _lastTapUpTime;
    if (eventTime == null) {
      return;
    }
    final isQuickTap =
        eventTime - (_lastTapDownTime ?? eventTime) < _kTapMaxDuration;
    if (!_enableDoubleTapToZoom) {
      onTap(location, eventTime: eventTime, isQuickTap: isQuickTap);
      return;
    }
    final previousLocation = _previousEvent?.globalPosition;
    if (previousLocation != null) {
      if ((location - previousLocation).distanceSquared <
          _kDoubleTapMaxDistanceSquared) {
        onDoubleTap(location);
        _previousEvent = null;
        return;
      } else {
        onTap(
          previousLocation,
          eventTime: eventTime,
          isQuickTap: _previousTapWasQuick,
        );
      }
    }
    _previousEvent = event;
    _previousTapWasQuick = isQuickTap;
    Future.delayed(_kDoubleTapMaxTime, () {
      if (_previousEvent == event) {
        onTap(location, eventTime: eventTime, isQuickTap: isQuickTap);
        _previousEvent = null;
      }
    });
  }

  void onTap(
    Offset location, {
    required Duration eventTime,
    required bool isQuickTap,
  }) {
    // The routing decision consults the scroll guard before anything else, so a
    // tap that arrives around a user drag is consumed once for the whole
    // surface: an edge tap cannot turn a page (or change a chapter) behind the
    // guard's back, and a center tap cannot toggle the toolbar. The consumed tap
    // performs no scroll action of its own — it is swallowed, never used to stop
    // or nudge a coasting list.
    final action = routeReaderSingleTap(
      ReaderTapDecisionInput(
        guardArmed: reader._imageViewController!.handleOnTap(location),
        toolbarOpen: context.readerScaffold.isOpen,
        // Don't open toolbar on chapter comments page
        onChapterCommentsPage: reader.isOnChapterCommentsPage,
        tapToTurnEnabled: appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'enableTapToTurnPages',
        ),
        reverseTapToTurn: appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'reverseTapToTurnPages',
        ),
        mode: context.reader.mode,
        position: location,
        size: Size(context.width, context.height),
        eventTime: eventTime,
        isQuickTap: isQuickTap,
        lastMenuToggleTime: _lastMenuToggleTime,
      ),
    );
    switch (action) {
      case ReaderTapAction.consume:
        return;
      case ReaderTapAction.previous:
        context.reader.toPrevPage();
        return;
      case ReaderTapAction.next:
        context.reader.toNextPage();
        return;
      case ReaderTapAction.toggleToolbar:
        _handleMenuToggleTap(location, eventTime, isQuickTap);
        return;
      case ReaderTapAction.none:
        return;
    }
  }

  /// Handles a tap whose only purpose is toggling the toolbar: a center tap,
  /// or any tap when tap-to-turn is off. Suppressed while a user drag was
  /// recent (continuous mode), when the tap is a press-and-hold, or shortly
  /// after the toolbar already toggled (so a quick double tap in the center
  /// cannot flash the toolbar open and shut).
  ///
  /// The routing decision already applies the same rules; this method performs
  /// the toggle and re-checks the guard as the toolbar toggle's own last line
  /// of defence.
  void _handleMenuToggleTap(
    Offset location,
    Duration eventTime,
    bool isQuickTap,
  ) {
    if (reader._imageViewController!.handleOnTap(location)) {
      return;
    }
    if (context.readerScaffold.isOpen) {
      // Closing an open toolbar keeps its original unconditional behaviour.
      _lastMenuToggleTime = eventTime;
      context.readerScaffold.openOrClose();
      return;
    }
    if (!isQuickTap) {
      return;
    }
    final lastToggle = _lastMenuToggleTime;
    if (lastToggle != null && eventTime - lastToggle < _kMenuToggleCooldown) {
      return;
    }
    _lastMenuToggleTime = eventTime;
    context.readerScaffold.openOrClose();
  }

  void onDoubleTap(Offset location) {
    context.reader._imageViewController?.handleDoubleTap(location);
  }

  void onSecondaryTapUp(Offset location) {
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.settings,
        text: "Settings".tl,
        onClick: () {
          context.readerScaffold.openSetting();
        },
      ),
      MenuEntry(
        icon: Icons.menu,
        text: "Chapters".tl,
        onClick: () {
          context.readerScaffold.openChapterDrawer();
        },
      ),
      MenuEntry(
        icon: Icons.fullscreen,
        text: "Fullscreen".tl,
        onClick: () {
          context.reader.fullscreen();
        },
      ),
      MenuEntry(
        icon: Icons.exit_to_app,
        text: "Exit".tl,
        onClick: () {
          context.pop();
        },
      ),
      if (App.isDesktop && !reader.isLoading)
        MenuEntry(
          icon: Icons.copy,
          text: "Copy Image".tl,
          onClick: () => copyImage(location),
        ),
      if (!reader.isLoading)
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Save Image".tl,
          onClick: () => saveImage(location),
        ),
    ]);
  }

  void onLongPressedUp(Offset location) {
    context.reader._imageViewController?.handleLongPressUp(location);
  }

  void onLongPressedDown(Offset location) {
    context.reader._imageViewController?.handleLongPressDown(location);
  }

  void addDragListener(_DragListener listener) {
    _dragListeners.add(listener);
  }

  void removeDragListener(_DragListener listener) {
    _dragListeners.remove(listener);
  }

  @override
  Object? get key => "reader_gesture";

  void copyImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      writeImageToClipboard(image);
    } else {
      context.showMessage(message: "No Image");
    }
  }

  void saveImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      var filetype = detectFileType(image);
      saveFile(filename: "image${filetype.ext}", data: image);
    } else {
      context.showMessage(message: "No Image");
    }
  }
}

class _DragListener {
  void Function(Offset point)? onStart;
  void Function(Offset offset)? onMove;
  void Function()? onEnd;

  _DragListener({this.onMove, this.onEnd});
}
