part of 'reader.dart';

class _AlbumSelection {
  _AlbumSelection({
    required this.view,
    required this.chapter,
    required this.galleryPage,
    required this.viewportSize,
    required this.readChoices,
    required this.releaseScroll,
    required this.choices,
  });

  final State<StatefulWidget> view;
  final int chapter;
  final int? galleryPage;
  final Size viewportSize;
  final List<AlbumImageChoice> Function(RenderBox) readChoices;
  final VoidCallback? releaseScroll;
  final result = Completer<int?>();
  List<AlbumImageChoice> choices;
  int? selectedIndex;

  bool matches(_ReaderState reader, Size size) =>
      identical(view, reader._imageViewController) &&
      view.mounted &&
      reader.chapter == chapter &&
      (galleryPage == null || reader.page == galleryPage) &&
      viewportSize == size;

  void cancel() {
    if (!result.isCompleted) result.complete(null);
  }
}

enum _AlbumSaveAction { retry, saveFile }

class _ReaderScaffold extends StatefulWidget {
  const _ReaderScaffold({required this.child});

  final Widget child;

  @override
  State<_ReaderScaffold> createState() => _ReaderScaffoldState();
}

class _ReaderScaffoldState extends State<_ReaderScaffold> {
  bool _isOpen = false;
  bool _albumSaving = false;
  bool _albumChoiceRefreshScheduled = false;
  _AlbumSelection? _albumSelection;

  static const kTopBarHeight = 56.0;

  static const kBottomBarHeight = 105.0;

  bool get isOpen => _isOpen;

  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  int showFloatingButtonValue = 0;

  var lastValue = 0;

  _ReaderGestureDetectorState? _gestureDetectorState;

  void setFloatingButton(int value) {
    lastValue = showFloatingButtonValue;
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  _DragListener? _imageFavoriteDragListener;

  void addDragListener() async {
    if (!mounted) return;
    var readerMode = context.reader.mode;

    // 横向阅读的时候, 如果纵向滑就触发收藏, 纵向阅读的时候, 如果横向滑动就触发收藏
    if (appdata.settings['quickCollectImage'] == 'Swipe') {
      if (_imageFavoriteDragListener == null) {
        double distance = 0;
        _imageFavoriteDragListener = _DragListener(
          onMove: (offset) {
            switch (readerMode) {
              case ReaderMode.continuousTopToBottom:
              case ReaderMode.galleryTopToBottom:
                distance += offset.dx;
              case ReaderMode.continuousLeftToRight:
              case ReaderMode.galleryLeftToRight:
              case ReaderMode.galleryRightToLeft:
              case ReaderMode.continuousRightToLeft:
                distance += offset.dy;
            }
          },
          onEnd: () {
            if (distance.abs() > 150) {
              addImageFavorite();
            }
            distance = 0;
          },
        );
      }
      _gestureDetectorState!.addDragListener(_imageFavoriteDragListener!);
    } else if (_imageFavoriteDragListener != null) {
      _gestureDetectorState!.removeDragListener(_imageFavoriteDragListener!);
    }
  }

  @override
  void initState() {
    sliderFocus.canRequestFocus = false;
    sliderFocus.addListener(() {
      if (sliderFocus.hasFocus) {
        sliderFocus.nextFocus();
      }
    });
    if (rotation != null) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), addDragListener);
  }

  @override
  void dispose() {
    _albumSelection?.cancel();
    sliderFocus.dispose();
    super.dispose();
  }

  void openOrClose() {
    if (!_isOpen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      if (!appdata.settings['showSystemStatusBar']) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    setState(() {
      _isOpen = !_isOpen;
    });
  }

  bool? rotation;

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    final isOnChapterCommentsPage = reader.isOnChapterCommentsPage;
    final selection = _albumSelection;
    final showChoices =
        selection?.matches(reader, MediaQuery.sizeOf(context)) ?? false;
    if (selection != null && !showChoices) _scheduleAlbumChoiceRefresh();
    // The reader page must always paint an opaque background. Relying on the
    // route's Material behind the reader leaves transparent areas while the
    // page is loading or during interactive route transitions (e.g. the held
    // system back gesture), where the layer below shows through and text/icon
    // layers render incorrectly.
    return ColoredBox(
      color: context.colorScheme.surface,
      child: Stack(
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: reader.isPageAnimating,
              child: widget.child,
            ),
          ),
          if (appdata.settings['showPageNumberInReader'] == true &&
              !isOnChapterCommentsPage)
            buildPageInfoText(),
          if (!isOnChapterCommentsPage) buildStatusInfo(),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            right: 16,
            bottom: showFloatingButtonValue == 0 ? -58 : 36,
            child: buildEpChangeButton(),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            top: _isOpen ? 0 : -(kTopBarHeight + context.padding.top),
            left: 0,
            right: 0,
            height: kTopBarHeight + context.padding.top,
            child: buildTop(),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            bottom: _isOpen
                ? 0
                : -(kBottomBarHeight + MediaQuery.of(context).padding.bottom),
            left: 0,
            right: 0,
            child: buildBottom(),
          ),
          if (selection != null)
            Positioned.fill(
              child: PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) selection.cancel();
                },
                child: AlbumImagePicker(
                  choices: showChoices ? selection.choices : const [],
                  selectedIndex: selection.selectedIndex,
                  onCancel: selection.cancel,
                  onSelect: (index) {
                    if (selection.result.isCompleted ||
                        !selection.matches(
                          reader,
                          MediaQuery.sizeOf(context),
                        )) {
                      selection.cancel();
                      return;
                    }
                    setState(() => selection.selectedIndex = index);
                    selection.result.complete(index);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildTop() {
    final epName = context.reader.widget.chapters?.titles.elementAtOrNull(
      context.reader.chapter - 1,
    );

    // No BackdropFilter here: the bar background is 0.92 opaque, so the blur
    // is invisible but still re-rendered on every frame of the 180ms open/
    // close animation, burning GPU for nothing on large windows.
    return Container(
      padding: EdgeInsets.only(top: context.padding.top),
      decoration: BoxDecoration(
        color: context.colorScheme.surface.toOpacity(0.92),
        border: Border(
          bottom: BorderSide(color: Colors.grey.toOpacity(0.5), width: 0.5),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: context.padding.left,
          right: context.padding.right,
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            const BackButton(),
            const SizedBox(width: 8),
            Expanded(
              child: epName == null
                  ? Text(
                      context.reader.widget.name,
                      style: ts.s18,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          context.reader.widget.name,
                          style: ts.s16,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          epName,
                          style: ts.s12,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 8),
            if (shouldShowChapterComments())
              Tooltip(
                message: "Chapter Comments".tl,
                child: IconButton(
                  icon: const Icon(Icons.comment),
                  onPressed: openChapterComments,
                ),
              ),
            Tooltip(
              message: "Settings".tl,
              child: IconButton(
                icon: const Icon(Icons.settings),
                onPressed: openSetting,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  bool isLiked() {
    return ImageFavoriteManager().has(
      context.reader.cid,
      context.reader.type.sourceKey,
      context.reader.eid,
      context.reader.page,
      context.reader.chapter,
    );
  }

  void addImageFavorite() async {
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      String id = context.reader.cid;
      int ep = context.reader.chapter;
      String eid = context.reader.eid;
      String title = context.reader.history!.title;
      String subTitle = context.reader.history!.subtitle;
      int maxPage = context.reader.images!.length;
      int? page = await selectImage();
      if (page == null) return;
      page += 1;
      String sourceKey = context.reader.type.sourceKey;
      String imageKey = context.reader.images![page - 1];
      List<String> tags = context.reader.widget.tags;
      String author = context.reader.widget.author;

      var epName =
          context.reader.widget.chapters?.titles.elementAtOrNull(
            context.reader.chapter - 1,
          ) ??
          "E${context.reader.chapter}";
      var translatedTags = tags.map((e) => e.translateTagsToCN).toList();

      if (isLiked()) {
        if (page == firstPage) {
          showToast(
            message: "The cover cannot be uncollected here".tl,
            context: context,
          );
          return;
        }
        ImageFavoriteManager().deleteImageFavorite([
          ImageFavorite(page, imageKey, null, eid, id, ep, sourceKey, epName),
        ]);
        showToast(
          message: "Uncollected the image".tl,
          context: context,
          seconds: 1,
        );
      } else {
        var imageFavoritesComic =
            ImageFavoriteManager().find(id, sourceKey) ??
            ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              tags,
              translatedTags,
              DateTime.now(),
              author,
              {},
              subTitle,
              maxPage,
            );
        ImageFavorite imageFavorite = ImageFavorite(
          page,
          imageKey,
          null,
          eid,
          id,
          ep,
          sourceKey,
          epName,
        );
        ImageFavoritesEp? imageFavoritesEp = imageFavoritesComic
            .imageFavoritesEp
            .firstWhereOrNull((e) {
              return e.ep == ep;
            });
        if (imageFavoritesEp == null) {
          if (page != firstPage) {
            var copy = imageFavorite.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: context.reader.images![0],
            );
            // 不是第一页的话, 自动塞一个封面进去
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [copy, imageFavorite],
              epName,
              maxPage,
            );
          } else {
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [imageFavorite],
              epName,
              maxPage,
            );
          }
          imageFavoritesComic.imageFavoritesEp.add(imageFavoritesEp);
        } else {
          if (imageFavoritesEp.eid != eid) {
            // 空字符串说明是从pica导入的, 那我们就手动刷一遍保证一致
            if (imageFavoritesEp.eid == "") {
              imageFavoritesEp.eid == eid;
            } else {
              // 避免多章节漫画源的章节顺序发生变化, 如果情况比较多, 做一个以eid为准更新ep的功能
              showToast(
                message:
                    "The chapter order of the comic may have changed, temporarily not supported for collection"
                        .tl,
                context: context,
              );
              return;
            }
          }
          imageFavoritesEp.imageFavorites.add(imageFavorite);
        }

        ImageFavoriteManager().addOrUpdateOrDelete(imageFavoritesComic);
        showToast(
          message: "Successfully collected".tl,
          context: context,
          seconds: 1,
        );
      }
      update();
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
    }
  }

  Widget buildBottom() {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var text = "E${context.reader.chapter} : P$displayPage";
    if (context.reader.widget.chapters == null) {
      text = "P$displayPage";
    }

    final buttons = [
      Tooltip(
        message: "Collect the image".tl,
        child: IconButton(
          icon: Icon(isLiked() ? Icons.favorite : Icons.favorite_border),
          onPressed: addImageFavorite,
        ),
      ),
      if (App.isDesktop)
        Tooltip(
          message: "${"Full Screen".tl}(F12)",
          child: IconButton(
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              context.reader.fullscreen();
            },
          ),
        ),
      if (App.isAndroid)
        Tooltip(
          message: "Screen Rotation".tl,
          child: IconButton(
            icon: () {
              if (rotation == null) {
                return const Icon(Icons.screen_rotation);
              } else if (rotation == false) {
                return const Icon(Icons.screen_lock_portrait);
              } else {
                return const Icon(Icons.screen_lock_landscape);
              }
            }.call(),
            onPressed: () {
              if (rotation == null) {
                setState(() {
                  rotation = false;
                });
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                ]);
              } else if (rotation == false) {
                setState(() {
                  rotation = true;
                });
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              } else {
                setState(() {
                  rotation = null;
                });
                SystemChrome.setPreferredOrientations(DeviceOrientation.values);
              }
            },
          ),
        ),
      Tooltip(
        message: "Auto Page Turning".tl,
        child: IconButton(
          icon: context.reader.autoPageTurningTimer != null
              ? const Icon(Icons.timer)
              : const Icon(Icons.timer_sharp),
          onPressed: () {
            context.reader.autoPageTurning(
              context.reader.cid,
              context.reader.type,
            );
            update();
          },
        ),
      ),
      if (context.reader.widget.chapters != null)
        Tooltip(
          message: "Chapters".tl,
          child: IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: openChapterDrawer,
          ),
        ),
      Tooltip(
        message: App.isMobile ? 'Save to Album'.tl : 'Save Image'.tl,
        child: IconButton(
          icon: _albumSaving && _albumSelection == null
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          onPressed: !App.isMobile || _canSaveToAlbum ? saveCurrentImage : null,
        ),
      ),
      Tooltip(
        message: "Share".tl,
        child: IconButton(icon: const Icon(Icons.share), onPressed: share),
      ),
    ];

    Widget child = SizedBox(
      height: kBottomBarHeight,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: () => !isReversed
                    ? context.reader.chapter > 1
                          ? context.reader.toPrevChapter()
                          : context.reader.toPage(1)
                    : context.reader.chapter < context.reader.maxChapter
                    ? context.reader.toNextChapter()
                    : context.reader.toPage(context.reader.maxPage),
                icon: const Icon(Icons.first_page),
              ),
              Expanded(child: buildSlider()),
              IconButton.filledTonal(
                onPressed: () => !isReversed
                    ? context.reader.chapter < context.reader.maxChapter
                          ? context.reader.toNextChapter()
                          : context.reader.toPage(context.reader.maxPage)
                    : context.reader.chapter > 1
                    ? context.reader.toPrevChapter()
                    : context.reader.toPage(1),
                icon: const Icon(Icons.last_page),
              ),
              const SizedBox(width: 8),
            ],
          ),
          LayoutBuilder(
            builder: (context, constrains) {
              final small = (constrains.maxWidth - buttons.length * 50) < 120;
              return Row(
                children: [
                  if (!small)
                    Container(
                      height: 24,
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: Text(text)),
                    ).paddingLeft(16),
                  const Spacer(),
                  for (var button in buttons)
                    if (!small)
                      button.paddingHorizontal(4)
                    else ...[
                      button,
                      const Spacer(),
                    ],
                  if (!small) const SizedBox(width: 4),
                ],
              );
            },
          ),
        ],
      ),
    );

    // No BackdropFilter here: the bar background is 0.92 opaque, so the blur
    // is invisible but still re-rendered on every frame of the 180ms open/
    // close animation, burning GPU for nothing on large windows.
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surface.toOpacity(0.92),
        border: isOpen
            ? Border(
                top: BorderSide(color: Colors.grey.toOpacity(0.5), width: 0.5),
              )
            : null,
      ),
      padding: EdgeInsets.only(bottom: context.padding.bottom),
      child: Padding(
        padding: EdgeInsets.only(
          left: context.padding.left,
          right: context.padding.right,
        ),
        child: child,
      ),
    );
  }

  var sliderFocus = FocusNode();

  Widget buildSlider() {
    // Clamp page to maxPage (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    return CustomSlider(
      focusNode: sliderFocus,
      value: displayPage.toDouble(),
      min: 1,
      max: context.reader.maxPage.clamp(displayPage, 1 << 16).toDouble(),
      reversed: isReversed,
      divisions: (context.reader.maxPage - 1).clamp(2, 1 << 16),
      onChanged: (i) {
        context.reader.toPage(i.toInt());
      },
    );
  }

  Widget buildPageInfoText() {
    var epName =
        context.reader.widget.chapters?.titles.elementAtOrNull(
          context.reader.chapter - 1,
        ) ??
        "E${context.reader.chapter}";
    if (epName.length > 8) {
      epName = "${epName.substring(0, 8)}...";
    }
    var pageText = "${context.reader.page}/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return Positioned(
      bottom: 13,
      left: 25,
      child: Stack(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..color = context.colorScheme.onInverseSurface,
            ),
          ),
          Text(text),
        ],
      ),
    );
  }

  Widget buildStatusInfo() {
    if (appdata.settings['enableClockAndBatteryInfoInReader']) {
      return Positioned(
        bottom: 13,
        right: 25,
        child: Row(
          children: [
            _ClockWidget(),
            const SizedBox(width: 10),
            _BatteryWidget(),
          ],
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  void openChapterDrawer() {
    _openSideBar(
      context.reader.widget.chapters!.isGrouped
          ? _GroupedChaptersView(context.reader)
          : _ChaptersView(context.reader),
      width: 400,
    );
  }

  void saveCurrentImage() async {
    if (App.isMobile) {
      await _saveCurrentImageToAlbum();
      return;
    }
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    // Save file name: ComicName_EP{chapter}_P{page}.{ext} to avoid conflict.
    // The chapter index of different group is continuous, so we use chapter number is enough.
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    saveFile(data: data, filename: filename);
  }

  bool get _canSaveToAlbum {
    final reader = context.reader;
    return !_albumSaving &&
        !reader.isLoading &&
        !reader.isPageAnimating &&
        !reader.isOnChapterCommentsPage &&
        (reader.images?.isNotEmpty ?? false);
  }

  Future<int?> _selectAlbumImage(_ReaderState reader) async {
    final controller = reader._imageViewController;
    final State<StatefulWidget> view;
    final List<AlbumImageChoice> Function(RenderBox) readChoices;
    int? galleryPage;
    VoidCallback? releaseScroll;
    if (controller is _ContinuousModeState && controller.mounted) {
      view = controller;
      readChoices = controller._albumChoices;
      releaseScroll = controller._holdAlbumScroll();
    } else if (controller is _GalleryModeState &&
        controller.mounted &&
        controller.controller.hasClients &&
        !controller.controller.position.isScrollingNotifier.value) {
      final range = controller.getCurrentPageImageRange();
      if (range == null) return null;
      final (start, end) = range;
      if (end - start == 1) return start;
      view = controller;
      galleryPage = reader.page;
      readChoices = (viewport) =>
          controller._albumChoices(viewport, start, end);
    } else {
      return null;
    }

    try {
      final viewport = context.findRenderObject() as RenderBox;
      final choices = readChoices(viewport);
      if (choices.isEmpty) {
        context.showMessage(message: 'Image unavailable'.tl);
        return null;
      }
      if (choices.length == 1 && choices.single.ready) {
        return choices.single.index;
      }
      final selection = _AlbumSelection(
        view: view,
        chapter: reader.chapter,
        galleryPage: galleryPage,
        viewportSize: MediaQuery.sizeOf(context),
        readChoices: readChoices,
        releaseScroll: releaseScroll,
        choices: choices,
      );
      if (_isOpen) openOrClose();
      reader._albumSelectionActive = true;
      setState(() => _albumSelection = selection);
      _scheduleAlbumChoiceRefresh();
      return await selection.result.future;
    } finally {
      if (_albumSelection == null) releaseScroll?.call();
    }
  }

  void _scheduleAlbumChoiceRefresh() {
    final selection = _albumSelection;
    if (!mounted ||
        selection == null ||
        selection.result.isCompleted ||
        _albumChoiceRefreshScheduled) {
      return;
    }
    _albumChoiceRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _albumChoiceRefreshScheduled = false;
      if (!mounted ||
          _albumSelection != selection ||
          selection.result.isCompleted) {
        return;
      }
      if (!selection.matches(context.reader, MediaQuery.sizeOf(context))) {
        selection.cancel();
        return;
      }
      final viewport = context.findRenderObject() as RenderBox;
      setState(() {
        selection.choices = selection.readChoices(viewport);
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _saveCurrentImageToAlbum() async {
    if (!_canSaveToAlbum) return;
    final reader = context.reader;
    final images = reader.images!;
    final cid = reader.cid;
    final eid = reader.eid;
    final sourceKey = reader.type.sourceKey;
    final chapter = reader.chapter;
    final title = String.fromCharCodes(reader.widget.name.runes.take(52));
    setState(() => _albumSaving = true);
    try {
      final index = await _selectAlbumImage(reader);
      final imageKey = index == null ? null : images.elementAtOrNull(index);
      if (!mounted || index == null || imageKey == null) return;
      final number = index + 1;
      final filename = sanitizeFileName(
        '${title}_EP${chapter}_P$number'.replaceAll(
          RegExp(r'[\x00-\x1f]'),
          ' ',
        ),
      );
      Uint8List? bytes;
      while (mounted && bytes == null) {
        try {
          bytes = await _readAlbumSource(imageKey, sourceKey, cid, eid);
        } catch (_) {
          if (!mounted ||
              await _showAlbumSaveOptions(
                    'Could not read the selected image.'.tl,
                    canSaveFile: false,
                  ) !=
                  _AlbumSaveAction.retry) {
            return;
          }
        }
      }
      if (!mounted || bytes == null) return;
      final originalType = detectFileType(bytes);
      var failure = await _writeAlbumImage(
        filename,
        number,
        originalType,
        bytes,
      );
      while (mounted && failure != null) {
        final action = await _showAlbumSaveOptions(
          failure.message,
          canRetry: failure.canRetry,
        );
        if (!mounted || action == null) return;
        if (action == _AlbumSaveAction.retry) {
          failure = await _writeAlbumImage(
            filename,
            number,
            originalType,
            bytes,
          );
          continue;
        }
        try {
          final saved = await saveFile(
            filename: '$filename${originalType.ext}',
            data: bytes,
          );
          if (saved) {
            if (mounted) {
              context.showMessage(
                message: 'Image @number saved to a file'.tlParams({
                  'number': number,
                }),
              );
            }
            return;
          }
        } catch (_) {
          if (mounted) {
            context.showMessage(message: 'Could not save the file.'.tl);
          }
        }
      }
    } finally {
      reader._albumSelectionActive = false;
      _albumSelection?.releaseScroll?.call();
      if (mounted) {
        setState(() {
          _albumSelection = null;
          _albumSaving = false;
        });
      }
    }
  }

  Future<Uint8List> _readAlbumSource(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async {
    if (imageKey.startsWith('file://')) {
      return File(imageKey.substring(7)).readAsBytes();
    }
    final cacheKey = ImageDownloader.comicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
    );
    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) return cached.readAsBytes();
    await for (final event in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
    )) {
      if (event.imageBytes != null) return event.imageBytes!;
    }
    throw StateError('Reader image bytes unavailable');
  }

  Future<({String message, bool canRetry})?> _writeAlbumImage(
    String filename,
    int number,
    FileType originalType,
    Uint8List bytes,
  ) async {
    final ({FileType type, Uint8List bytes})? image;
    try {
      image = await prepareImageForAlbum(originalType, bytes);
    } catch (_) {
      return (
        message: 'Could not convert the selected image to PNG.'.tl,
        canRetry: true,
      );
    }
    if (image == null) {
      return (
        message: 'Save animated WebP as a file to preserve the animation.'.tl,
        canRetry: false,
      );
    }
    if (!mounted) return null;
    try {
      await saveImageToAlbum(
        filename: '$filename${image.type.ext}',
        type: image.type,
        bytes: image.bytes,
      );
    } catch (error) {
      if (error is PlatformException &&
          error.code == 'album_permission_denied') {
        return (
          message: 'Photo library permission was denied.'.tl,
          canRetry: false,
        );
      }
      return (
        message: 'Could not save the image to the album.'.tl,
        canRetry: true,
      );
    }
    if (mounted) {
      final message = originalType.mime == 'image/webp'
          ? 'Image @number saved to the album as PNG'
          : 'Image @number saved to the album';
      context.showMessage(message: message.tlParams({'number': number}));
    }
    return null;
  }

  Future<_AlbumSaveAction?> _showAlbumSaveOptions(
    String message, {
    bool canRetry = true,
    bool canSaveFile = true,
  }) {
    return showDialog<_AlbumSaveAction>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          if (canRetry)
            TextButton(
              onPressed: () => Navigator.pop(context, _AlbumSaveAction.retry),
              child: Text('Retry'.tl),
            ),
          if (canSaveFile)
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _AlbumSaveAction.saveFile),
              child: Text('Save as File'.tl),
            ),
        ],
      ),
    );
  }

  void share() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    Share.shareFile(data: data, filename: filename, mime: fileType.mime);
  }

  void openSetting() {
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.mode = ReaderMode.fromKey(
              appdata.settings.getReaderSetting(
                context.reader.cid,
                context.reader.type.sourceKey,
                key,
              ),
            );
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (appdata.settings.getReaderSetting(
              context.reader.cid,
              context.reader.type.sourceKey,
              key,
            )) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key == "quickCollectImage") {
            addDragListener();
          }
          if (key == "showChapterComments" ||
              key == "showChapterCommentsAtEnd") {
            update();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    _gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        widget,
        width: width,
        dismissible: true,
      ).whenComplete(() {
        _gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      'showChapterComments',
    );
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    if (App.isAndroid) {
      context.to(
        () => ChapterCommentsPage(
          comicId: context.reader.cid,
          epId: epId,
          source: source,
          comicTitle: context.reader.widget.name,
          chapterTitle: chapterTitle,
        ),
      );
    } else {
      showSideBar(
        context,
        ChapterCommentsPage(
          comicId: context.reader.cid,
          epId: epId,
          source: source,
          comicTitle: context.reader.widget.name,
          chapterTitle: chapterTitle,
        ),
      );
    }
  }

  Widget buildEpChangeButton() {
    final extraWidth = context.padding.left + context.padding.right;
    if (context.reader.widget.chapters == null) return const SizedBox();
    switch (showFloatingButtonValue) {
      case 0:
        return Container(
          width: 58 + extraWidth,
          height: 58,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            lastValue == 1
                ? Icons.arrow_forward_ios
                : Icons.arrow_back_ios_outlined,
            size: 24,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        );
      case -1:
      case 1:
        return SizedBox(
          width: 58 + extraWidth,
          height: 58,
          child: Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            elevation: 2,
            child: InkWell(
              onTap: () {
                if (showFloatingButtonValue == 1) {
                  context.reader.toNextChapter();
                } else if (showFloatingButtonValue == -1) {
                  context.reader.toPrevChapter();
                }
                setFloatingButton(0);
              },
              borderRadius: BorderRadius.circular(16),
              child: Center(
                child: Icon(
                  _getArrowIcon(isReversed, showFloatingButtonValue),
                  size: 24,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        );
    }
    return const SizedBox();
  }

  IconData _getArrowIcon(bool reversed, int value) {
    if (reversed) {
      return value == 1
          ? Icons.arrow_back_ios_outlined
          : Icons.arrow_forward_ios;
    } else {
      return value == 1
          ? Icons.arrow_forward_ios
          : Icons.arrow_back_ios_outlined;
    }
  }

  /// If there is only one image on screen, return it.
  ///
  /// If there are multiple images on screen,
  /// show an overlay to let the user select an image.
  ///
  /// The return value is the index of the selected image.
  Future<int?> selectImage() async {
    var reader = context.reader;
    var imageViewController = context.reader._imageViewController;

    bool needsSelection = false;
    int? singleImageIndex;

    if (imageViewController is _GalleryModeState) {
      var range = imageViewController.getCurrentPageImageRange();
      if (range != null) {
        var (startIndex, endIndex) = range;
        int actualImageCount = endIndex - startIndex;
        if (actualImageCount == 1) {
          needsSelection = false;
          singleImageIndex = startIndex;
        } else {
          needsSelection = true;
        }
      }
    } else if (imageViewController is _ContinuousModeState) {
      needsSelection = false;
      singleImageIndex = reader.page - 1;
    }

    if (!needsSelection && singleImageIndex != null) {
      return singleImageIndex;
    } else {
      var location = await _showSelectImageOverlay();
      if (location == null) {
        return null;
      }
      var imageKey = imageViewController!.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      return reader.images!.indexOf(imageKey);
    }
  }

  /// Same as [selectImage], but return the image data with its index.
  /// Returns (imageIndex, imageData) or null if cancelled.
  Future<(int, Uint8List)?> selectImageToData() async {
    var i = await selectImage();
    if (i == null) {
      return null;
    }
    var imageKey = context.reader.images![i];
    Uint8List data;
    if (imageKey.startsWith("file://")) {
      data = await File(imageKey.substring(7)).readAsBytes();
    } else {
      data = await (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
    return (i, data);
  }

  Future<Offset?> _showSelectImageOverlay() {
    if (_isOpen) {
      openOrClose();
    }

    var completer = Completer<Offset?>();

    var overlay = Overlay.of(context);
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: _SelectImageOverlayContent(
            onTap: (offset) {
              completer.complete(offset);
              entry!.remove();
            },
            onDispose: () {
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            },
          ),
        );
      },
    );
    overlay.insert(entry);

    return completer.future;
  }
}

class _BatteryWidget extends StatefulWidget {
  @override
  _BatteryWidgetState createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<_BatteryWidget> {
  late Battery _battery;
  late int _batteryLevel = 100;
  Timer? _timer;
  bool _hasBattery = false;
  BatteryState state = BatteryState.unknown;

  @override
  void initState() {
    super.initState();
    _battery = Battery();
    _checkBatteryAvailability();
  }

  void _checkBatteryAvailability() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      state = await _battery.batteryState;
      if (_batteryLevel > 0 && state != BatteryState.unknown) {
        setState(() {
          _hasBattery = true;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          _battery.batteryLevel.then((level) {
            if (_batteryLevel != level) {
              setState(() {
                _batteryLevel = level;
              });
            }
          });
        });
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBattery) {
      return const SizedBox.shrink(); //Empty Widget
    }
    return _batteryInfo(_batteryLevel);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (state == BatteryState.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      children: [
        Icon(
          batteryIcon,
          size: 16,
          color: batteryColor,
          // Stroke
          shadows: List.generate(9, (index) {
            if (index == 4) {
              return null;
            }
            double offsetX = (index % 3 - 1) * 0.8;
            double offsetY = ((index / 3).floor() - 1) * 0.8;
            return Shadow(
              color: context.colorScheme.onInverseSurface,
              offset: Offset(offsetX, offsetY),
            );
          }).whereType<Shadow>().toList(),
        ),
        Stack(
          children: [
            Text(
              '$batteryLevel%',
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text('$batteryLevel%'),
          ],
        ),
      ],
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  _ClockWidgetState createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late String _currentTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = _getCurrentTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final time = _getCurrentTime();
      if (_currentTime != time) {
        setState(() {
          _currentTime = time;
        });
      }
    });
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(
          _currentTime,
          style: TextStyle(
            fontSize: 14,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = context.colorScheme.onInverseSurface,
          ),
        ),
        Text(_currentTime),
      ],
    );
  }
}

class _SelectImageOverlayContent extends StatefulWidget {
  const _SelectImageOverlayContent({
    required this.onTap,
    required this.onDispose,
  });

  final void Function(Offset) onTap;

  final void Function() onDispose;

  @override
  State<_SelectImageOverlayContent> createState() =>
      _SelectImageOverlayContentState();
}

class _SelectImageOverlayContentState
    extends State<_SelectImageOverlayContent> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        widget.onTap(details.globalPosition);
      },
      child: Container(
        color: Colors.black.withAlpha(50),
        child: Align(
          alignment: Alignment(0, -0.8),
          child: Container(
            width: 232,
            height: 42,
            decoration: BoxDecoration(
              color: context.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.info_outline),
                const SizedBox(width: 16),
                Text(
                  "Click to select an image".tl,
                  style: TextStyle(
                    fontSize: 16,
                    color: context.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
