part of 'comic_page.dart';

class _ComicChapters extends StatelessWidget {
  const _ComicChapters({this.history, required this.groupedMode});

  final History? history;

  final bool groupedMode;

  @override
  Widget build(BuildContext context) {
    return groupedMode
        ? _GroupedComicChapters(history)
        : _NormalComicChapters(history);
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.title,
    required this.isRead,
    required this.backgroundColor,
    required this.borderRadius,
    required this.onTap,
  });

  final String title;
  final bool isRead;
  final Color backgroundColor;
  final BorderRadius borderRadius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final readColor = context.useTextColor(Colors.green);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: isRead ? BorderSide(color: readColor) : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: isRead ? 22 : 8),
                child: Center(
                  child: Text(
                    title,
                    semanticsLabel: isRead
                        ? '$title, ${'Already read'.tl}'
                        : null,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (isRead)
                PositionedDirectional(
                  top: 4,
                  end: 6,
                  child: Icon(Icons.check_rounded, size: 14, color: readColor),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NormalComicChapters extends StatefulWidget {
  const _NormalComicChapters(this.history);

  final History? history;

  @override
  State<_NormalComicChapters> createState() => _NormalComicChaptersState();
}

class _NormalComicChaptersState extends State<_NormalComicChapters> {
  late _ComicPageState state;

  late bool reverse;

  bool showAll = false;

  late History? history;

  late ComicChapters chapters;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant _NormalComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        int length = chapters.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == chapters.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: ListTile(
                title: Text("Chapters".tl),
                trailing: Tooltip(
                  message: "Order".tl,
                  child: IconButton(
                    icon: Icon(
                      reverse
                          ? Icons.vertical_align_top
                          : Icons.vertical_align_bottom_outlined,
                    ),
                    onPressed: () {
                      setState(() {
                        reverse = !reverse;
                      });
                    },
                  ),
                ),
              ),
            ),
            SliverGrid(
              delegate: SliverChildBuilderDelegate(childCount: length, (
                context,
                i,
              ) {
                if (reverse) {
                  i = chapters.length - i - 1;
                }
                var key = chapters.ids.elementAt(i);
                var value = chapters[key]!;
                final visited =
                    state.comic.readChapterIds.contains(key) ||
                    (history?.readEpisode.contains('${i + 1}') ?? false);
                return _ChapterTile(
                  title: value,
                  isRead: visited,
                  backgroundColor: context.colorScheme.surfaceContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  onTap: () => state.read(i + 1),
                );
              }),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: 48,
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${chapters.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}

class _GroupedComicChapters extends StatefulWidget {
  const _GroupedComicChapters(this.history);

  final History? history;

  @override
  State<_GroupedComicChapters> createState() => _GroupedComicChaptersState();
}

class _GroupedComicChaptersState extends State<_GroupedComicChapters>
    with SingleTickerProviderStateMixin {
  late _ComicPageState state;

  late bool reverse;

  bool showAll = false;

  late History? history;

  late ComicChapters chapters;

  late TabController tabController;

  late int index;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
    if (history?.group != null) {
      index = history!.group! - 1;
    } else {
      index = 0;
    }
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    tabController = TabController(
      initialIndex: index,
      length: chapters.ids.length,
      vsync: this,
    );
    tabController.addListener(onTabChange);
    super.didChangeDependencies();
  }

  void onTabChange() {
    if (index != tabController.index) {
      setState(() {
        index = tabController.index;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _GroupedComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        var group = chapters.getGroupByIndex(index);
        int length = group.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == group.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: ListTile(
                title: Text("Chapters".tl),
                trailing: Tooltip(
                  message: "Order".tl,
                  child: IconButton(
                    icon: Icon(
                      reverse
                          ? Icons.vertical_align_top
                          : Icons.vertical_align_bottom_outlined,
                    ),
                    onPressed: () {
                      setState(() {
                        reverse = !reverse;
                      });
                    },
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: AppTabBar(
                withUnderLine: false,
                controller: tabController,
                tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
              ),
            ),
            SliverPadding(padding: const EdgeInsets.only(top: 8)),
            SliverGrid(
              delegate: SliverChildBuilderDelegate(childCount: length, (
                context,
                i,
              ) {
                if (reverse) {
                  i = group.length - i - 1;
                }
                var key = group.keys.elementAt(i);
                var value = group[key]!;
                var chapterIndex = 0;
                for (var j = 0; j < chapters.groupCount; j++) {
                  if (j == index) {
                    chapterIndex += i;
                    break;
                  }
                  chapterIndex += chapters.getGroupByIndex(j).length;
                }
                String rawIndex = (chapterIndex + 1).toString();
                String groupedIndex = "${index + 1}-${i + 1}";
                final localReadEpisodes =
                    history?.readEpisode ?? const <String>{};
                final visited =
                    state.comic.readChapterIds.contains(key) ||
                    localReadEpisodes.contains(groupedIndex) ||
                    localReadEpisodes.contains(rawIndex);
                return _ChapterTile(
                  title: value,
                  isRead: visited,
                  backgroundColor: context.colorScheme.surfaceContainerLow,
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  onTap: () => state.read(chapterIndex + 1),
                );
              }),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: 48,
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${group.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}
