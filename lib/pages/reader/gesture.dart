part of 'reader.dart';

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
    if (context.readerScaffold.isOpen) {
      context.readerScaffold.openOrClose();
      _lastMenuToggleTime = eventTime;
      return;
    }
    // Don't open toolbar on chapter comments page
    if (reader.isOnChapterCommentsPage) {
      return;
    }
    if (appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'enableTapToTurnPages',
    )) {
      bool isLeft = false, isRight = false, isTop = false, isBottom = false;
      final width = context.width;
      final height = context.height;
      final x = location.dx;
      final y = location.dy;
      if (x < width * _kTapToTurnPagePercent) {
        isLeft = true;
      } else if (x > width * (1 - _kTapToTurnPagePercent)) {
        isRight = true;
      }
      if (y < height * _kTapToTurnPagePercent) {
        isTop = true;
      } else if (y > height * (1 - _kTapToTurnPagePercent)) {
        isBottom = true;
      }
      bool isCenter = false;
      var prev = () => context.reader.toPrevPage();
      var next = () => context.reader.toNextPage();
      if (appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'reverseTapToTurnPages',
      )) {
        prev = () => context.reader.toNextPage();
        next = () => context.reader.toPrevPage();
      }
      switch (context.reader.mode) {
        case ReaderMode.galleryLeftToRight:
        case ReaderMode.continuousLeftToRight:
          if (isLeft) {
            prev();
          } else if (isRight) {
            next();
          } else {
            isCenter = true;
          }
        case ReaderMode.galleryRightToLeft:
        case ReaderMode.continuousRightToLeft:
          if (isLeft) {
            next();
          } else if (isRight) {
            prev();
          } else {
            isCenter = true;
          }
        case ReaderMode.galleryTopToBottom:
        case ReaderMode.continuousTopToBottom:
          if (isTop) {
            prev();
          } else if (isBottom) {
            next();
          } else {
            isCenter = true;
          }
      }
      if (isCenter) {
        _handleMenuToggleTap(location, eventTime, isQuickTap);
      }
    } else {
      _handleMenuToggleTap(location, eventTime, isQuickTap);
    }
  }

  /// Handles a tap whose only purpose is toggling the toolbar: a center tap,
  /// or any tap when tap-to-turn is off. Suppressed while a user drag was
  /// recent (continuous mode), when the tap is a press-and-hold, or shortly
  /// after the toolbar already toggled (so a quick double tap in the center
  /// cannot flash the toolbar open and shut).
  void _handleMenuToggleTap(
    Offset location,
    Duration eventTime,
    bool isQuickTap,
  ) {
    if (reader._imageViewController!.handleOnTap(location)) {
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
