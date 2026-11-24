part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps>
    with TickerProviderStateMixin {
  late final _ReaderOpening _opening = _ReaderOpening(this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _opening.reduceMotion = MediaQuery.disableAnimationsOf(context);
    _opening.waitForEntry(ModalRoute.of(context));
  }

  @override
  void dispose() {
    _opening.dispose();
    super.dispose();
  }

  @override
  void retry() {
    _opening.begin();
    super.retry();
  }

  @override
  void onLoadError(String message) => _opening.reveal(animate: false);

  @override
  Widget buildLoading() => _ReaderLoadingVeil(opening: _opening);

  @override
  Widget buildFrame(BuildContext context, Widget child) => _ReaderOpeningScope(
    opening: _opening,
    child: ColoredBox(color: context.colorScheme.surface, child: child),
  );

  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = HistoryManager().find(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    if (comicSource == null) {
      var localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ?? History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      var comic = await comicSource.loadComicInfo!(widget.id);
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history:
              history ?? History.fromModel(model: comic.data, ep: 0, page: 0),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
        ),
      );
    }
  }
}

class _ReaderOpeningScope extends InheritedWidget {
  const _ReaderOpeningScope({required this.opening, required super.child});

  final _ReaderOpening opening;

  @override
  bool updateShouldNotify(_ReaderOpeningScope oldWidget) =>
      opening != oldWidget.opening;
}

/// One presentation for the metadata, chapter list, and current image.
class _ReaderOpening {
  _ReaderOpening(TickerProvider vsync)
    : veil = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 150),
      ),
      turn = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 1260),
      ) {
    veil.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) showBook.value = false;
    });
    begin();
  }

  final AnimationController veil;
  final AnimationController turn;
  final showBook = ValueNotifier(false);
  Timer? _showDelay;
  Animation<double>? _entryAnimation;
  bool _waiting = false;
  bool _showDelayElapsed = false;
  bool _reduceMotion = false;
  ImageProvider? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  bool get waiting => _waiting;

  void waitForEntry(ModalRoute<dynamic>? route) {
    if (_entryAnimation != null ||
        route is! ReaderEntryRoute ||
        !route.isEntering) {
      return;
    }
    _entryAnimation = route.entryAnimation;
    _entryAnimation!.addStatusListener(_onEntryStatus);
  }

  void _onEntryStatus(AnimationStatus status) {
    if (!status.isCompleted) return;
    _entryAnimation!.removeStatusListener(_onEntryStatus);
    _entryAnimation = null;
    _showBookIfReady();
  }

  void _showBookIfReady() {
    if (!_waiting || !_showDelayElapsed || _entryAnimation != null) return;
    showBook.value = true;
    if (!_reduceMotion) turn.repeat();
  }

  set reduceMotion(bool value) {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    if (value) {
      turn.value = 0;
      if (!_waiting && veil.isAnimating) veil.value = 0;
    } else if (_waiting && showBook.value) {
      turn.repeat();
    }
  }

  void begin() {
    _stopWatching();
    _showDelay?.cancel();
    _waiting = true;
    _showDelayElapsed = false;
    veil.value = 1;
    turn.value = 0;
    showBook.value = false;
    _showDelay = Timer(const Duration(milliseconds: 250), () {
      _showDelayElapsed = true;
      _showBookIfReady();
    });
  }

  void watch(ImageProvider image) {
    if (!_waiting || image == _image) return;
    _stopWatching();
    // The reader uses the same provider key for its own image stream.
    final stream = image.resolve(const ImageConfiguration());
    void finish({required bool failed}) {
      // Give the image widget a frame to lay out the decoded image or error
      // beneath the veil before exposing it.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (identical(stream, _stream)) reveal(animate: !failed);
      });
    }

    final listener = ImageStreamListener((frame, _) {
      frame.dispose();
      finish(failed: false);
    }, onError: (_, _) => finish(failed: true));
    _image = image;
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stopWatching() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _image = null;
  }

  void reveal({required bool animate}) {
    if (!_waiting) return;
    _waiting = false;
    _showDelay?.cancel();
    _stopWatching();
    turn.stop();
    if (animate && !_reduceMotion && showBook.value) {
      veil.animateBack(0, curve: Curves.easeOut);
    } else {
      veil.value = 0;
    }
  }

  void dispose() {
    _showDelay?.cancel();
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    _stopWatching();
    veil.dispose();
    turn.dispose();
    showBook.dispose();
  }
}

class _ReaderLoadingVeil extends StatelessWidget {
  const _ReaderLoadingVeil({required this.opening});

  final _ReaderOpening opening;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return IgnorePointer(
      child: FadeTransition(
        key: const ValueKey('reader-loading-veil'),
        opacity: opening.veil,
        child: ColoredBox(
          color: colors.surface,
          child: ValueListenableBuilder<bool>(
            valueListenable: opening.showBook,
            builder: (context, visible, _) {
              if (!visible) return const SizedBox.expand();
              return Align(
                alignment: const Alignment(0, .08),
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey('reader-page-turn'),
                    size: const Size(80, 56),
                    painter: _ReaderBookPainter(
                      turn: opening.turn,
                      ink: Color.lerp(
                        colors.onSurfaceVariant,
                        colors.primary,
                        .55,
                      )!,
                      paper: colors.surfaceContainer,
                      leaf: colors.surfaceContainerLow,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ReaderBookPainter extends CustomPainter {
  static const _designSize = Size(60, 42);

  _ReaderBookPainter({
    required this.turn,
    required this.ink,
    required this.paper,
    required this.leaf,
  }) : super(repaint: turn);

  final Animation<double> turn;
  final Color ink;
  final Color paper;
  final Color leaf;

  Path _page(double edge, double lift) => Path()
    ..moveTo(30, 12)
    ..quadraticBezierTo((30 + edge) / 2, 4 - lift, edge, 8 - lift)
    ..lineTo(edge, 33 - lift)
    ..quadraticBezierTo((30 + edge) / 2, 30 - lift, 30, 37)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / _designSize.width,
      size.height / _designSize.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - _designSize.width * scale) / 2,
      (size.height - _designSize.height * scale) / 2,
    );
    canvas.scale(scale);
    final fill = Paint()..color = paper;
    final outline = Paint()
      ..color = ink
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final edge in [6.0, 54.0]) {
      final page = _page(edge, 0);
      canvas.drawPath(page, fill);
      canvas.drawPath(page, outline);
      final middle = (30 + edge) / 2;
      final rule = Paint()
        ..color = ink.withValues(alpha: .35)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(middle - 5, 16), Offset(middle + 5, 17), rule);
      canvas.drawLine(Offset(middle - 5, 21), Offset(middle + 5, 22), rule);
    }
    final progress = const Interval(
      .12,
      .77,
      curve: Curves.easeInOut,
    ).transform(turn.value);
    final visibility = 1 - const Interval(.81, .96).transform(turn.value);
    final angle = progress * math.pi;
    final sheet = _page(30 + 24 * math.cos(angle), 5 * math.sin(angle));
    canvas.drawPath(sheet, fill..color = leaf.withValues(alpha: visibility));
    canvas.drawPath(sheet, outline..color = ink.withValues(alpha: visibility));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReaderBookPainter oldDelegate) =>
      turn != oldDelegate.turn ||
      ink != oldDelegate.ink ||
      paper != oldDelegate.paper ||
      leaf != oldDelegate.leaf;
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
