part of 'components.dart';

class AnimatedImage extends StatefulWidget {
  /// show animation when loading is complete.
  AnimatedImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.sweepOnReplacement = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    this.part,
    this.onError,
    this.onFirstFrame,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  /// Sweep over the visible frame while its replacement loads and fades in.
  final bool sweepOnReplacement;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final ImagePart? part;

  final Function? onError;

  final void Function(ImageInfo imageInfo)? onFirstFrame;

  static void clear() => _AnimatedImageState.clear();

  @override
  State<AnimatedImage> createState() => _AnimatedImageState();
}

class _AnimatedImageState extends State<AnimatedImage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageInfo? _outgoingImage;
  int _sweepRevision = 0;
  AnimationController? _replacementSweep;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<AnimatedImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;

  static final Map<int, Size> _cache = {};
  static const _replacementFadeDuration = Duration(milliseconds: 220);

  AnimationController get _sweepController =>
      _replacementSweep ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 800),
      );

  static clear() => _cache.clear();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<AnimatedImage>>(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replacementSweep?.dispose();
    _releaseOutgoingImage();
    _replaceImage(info: null);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    if (_replacementSweep != null && MediaQuery.disableAnimationsOf(context)) {
      _replacementSweep!.stop();
    }
    _resolveImage();

    if (TickerMode.of(context)) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(AnimatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    } else if (oldWidget.onFirstFrame == null &&
        _frameNumber != null &&
        _outgoingImage == null) {
      // An already-visible cover can gain its detail callback after loading.
      widget.onFirstFrame?.call(_imageInfo!);
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: widget.width != null && widget.height != null
            ? Size(widget.width!, widget.height!)
            : null,
      ),
    );
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          // 图片加错错误回调
          widget.onError?.call(error, stackTrace);
          setState(() {
            _lastException = error;
            _replacementSweep?.stop();
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    final isFirst = _frameNumber == null;
    final previous = _imageInfo;
    final sweep =
        widget.sweepOnReplacement &&
        isFirst &&
        previous != null &&
        !imageInfo.isCloneOf(previous) &&
        !MediaQuery.disableAnimationsOf(context);
    setState(() {
      if (isFirst) {
        _releaseOutgoingImage();
        if (sweep) {
          _outgoingImage = previous.clone();
          _sweepRevision++;
          _sweepController.animateTo(
            1,
            duration: _replacementFadeDuration,
            curve: Curves.easeOut,
          );
        } else {
          _replacementSweep?.stop();
        }
      }
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
    if (isFirst && !sweep) {
      widget.onFirstFrame?.call(imageInfo);
    }
  }

  void _handleImageChunk(ImageChunkEvent event) {
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
  }

  void _releaseOutgoingImage() {
    final outgoing = _outgoingImage;
    _outgoingImage = null;
    if (outgoing != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => outgoing.dispose());
    }
  }

  void _finishSweep(int revision) {
    if (!mounted || _outgoingImage == null || revision != _sweepRevision) {
      return;
    }
    setState(_releaseOutgoingImage);
    // The next provider may still be pending. Only report its own first frame.
    if (_frameNumber != null) {
      _replacementSweep?.stop();
      widget.onFirstFrame?.call(_imageInfo!);
    }
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (widget.sweepOnReplacement &&
        _imageInfo != null &&
        !MediaQuery.disableAnimationsOf(context)) {
      _sweepController.repeat();
    } else {
      _replacementSweep?.stop();
    }

    if (!widget.gaplessPlayback && !widget.sweepOnReplacement) {
      setState(() {
        _releaseOutgoingImage();
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
      _lastException = null;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  Widget _buildFrame(ImageInfo frame) {
    if (widget.part != null) {
      return CustomPaint(
        isComplex: true,
        painter: ImagePainter(
          image: frame.image,
          part: widget.part!,
          fit: widget.fit ?? BoxFit.cover,
        ),
        child: SizedBox(width: widget.width, height: widget.height),
      );
    }
    return RawImage(
      image: frame.image,
      width: widget.width,
      height: widget.height,
      debugImageLabel: frame.debugLabel,
      scale: frame.scale,
      color: widget.color,
      opacity: widget.opacity,
      colorBlendMode: widget.colorBlendMode,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      repeat: widget.repeat,
      centerSlice: widget.centerSlice,
      matchTextDirection: widget.matchTextDirection,
      invertColors: _invertColors,
      isAntiAlias: widget.isAntiAlias,
      filterQuality: widget.filterQuality,
    );
  }

  Widget _buildReplacement(ImageInfo frame) {
    final current = _buildFrame(frame);
    final outgoing = _outgoingImage;
    final sweep = _replacementSweep;
    final revision = _sweepRevision;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (outgoing != null) _buildFrame(outgoing),
        // Keep the incoming frame mounted when the old frame is removed.
        TweenAnimationBuilder<double>(
          key: ValueKey(revision),
          tween: Tween(begin: outgoing == null ? 1 : 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : _replacementFadeDuration,
          curve: Curves.easeOut,
          onEnd: () => SchedulerBinding.instance.addPostFrameCallback(
            (_) => _finishSweep(revision),
          ),
          child: current,
          builder: (context, progress, child) =>
              Opacity(opacity: progress, child: child),
        ),
        if (sweep != null && sweep.isAnimating)
          Positioned.fill(child: _buildSweep(sweep)),
      ],
    );
  }

  Widget _buildSweep(Animation<double> sweep) {
    final color = Color.lerp(
      context.colorScheme.primaryContainer,
      Colors.white,
      .65,
    )!.withValues(alpha: .13);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: sweep,
        builder: (context, child) {
          final x = ui.lerpDouble(-1.6, 1.6, sweep.value)!;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(x - .34, -.55),
                end: Alignment(x + .34, .55),
                colors: [Colors.transparent, color, Colors.transparent],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget result;

    if (_imageInfo case final frame?) {
      result = widget.sweepOnReplacement
          ? _buildReplacement(frame)
          : _buildFrame(frame);
    } else if (_lastException != null) {
      result = const Center(child: Icon(Icons.error));

      if (!widget.excludeFromSemantics) {
        result = Semantics(
          container: widget.semanticLabel != null,
          image: true,
          label: widget.semanticLabel ?? '',
          child: result,
        );
      }
    } else {
      result = const Center();
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 200),
      child: result,
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    description.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    description.add(
      DiagnosticsProperty<ImageChunkEvent>('loadingProgress', _loadingProgress),
    );
    description.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    description.add(
      DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded',
        _wasSynchronouslyLoaded,
      ),
    );
  }
}

class ImagePart {
  final double? x1;
  final double? y1;
  final double? x2;
  final double? y2;

  const ImagePart({this.x1, this.y1, this.x2, this.y2});
}

class ImagePainter extends CustomPainter {
  final ui.Image image;

  final ImagePart part;

  final BoxFit fit;

  /// Render a part of the image.
  const ImagePainter({
    required this.image,
    this.part = const ImagePart(),
    this.fit = BoxFit.cover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Rect src = Rect.fromPoints(
      Offset(part.x1 ?? 0, part.y1 ?? 0),
      Offset(
        part.x2 ?? image.width.toDouble(),
        part.y2 ?? image.height.toDouble(),
      ),
    );
    var fitted = applyBoxFit(
      fit,
      Size(src.width, src.height),
      size,
    ).destination;
    var dst = Alignment.center.inscribe(fitted, Offset.zero & size);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! ImagePainter ||
        oldDelegate.image != image ||
        oldDelegate.part.x1 != part.x1 ||
        oldDelegate.part.y1 != part.y1 ||
        oldDelegate.part.x2 != part.x2 ||
        oldDelegate.part.y2 != part.y2;
  }
}
