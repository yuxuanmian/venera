part of 'reader.dart';

class _ReaderChapterSheet extends StatefulWidget {
  const _ReaderChapterSheet({required this.child});

  final Widget child;

  @override
  State<_ReaderChapterSheet> createState() => _ReaderChapterSheetState();
}

class _ReaderChapterSheetState extends State<_ReaderChapterSheet> {
  static const _collapsedExtent = 2 / 3;
  bool _expanded = false;
  bool _dragging = false;
  double _extent = _collapsedExtent;

  void _snap(bool expanded) {
    setState(() {
      _dragging = false;
      _expanded = expanded;
      _extent = expanded ? 1 : _collapsedExtent;
    });
  }

  void _endDrag(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (!_expanded && (velocity > 500 || _extent < _collapsedExtent - .105)) {
      Navigator.of(context).pop();
      return;
    }
    final expand = _expanded
        ? velocity < 500 && _extent > .89
        : velocity < -500 || _extent > _collapsedExtent + .105;
    _snap(expand);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedContainer(
        duration: _dragging || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: constraints.maxHeight * _extent,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Semantics(
                expanded: _expanded,
                button: true,
                label: 'Chapters'.tl,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _snap(!_expanded),
                  onVerticalDragStart: (_) => setState(() => _dragging = true),
                  onVerticalDragUpdate: (details) {
                    setState(() {
                      _extent =
                          (_extent - details.delta.dy / constraints.maxHeight)
                              .clamp(.4, 1.0);
                    });
                  },
                  onVerticalDragEnd: _endDrag,
                  onVerticalDragCancel: () => _snap(_expanded),
                  child: SizedBox(
                    height: 36,
                    width: double.infinity,
                    child: Center(
                      child: Container(
                        width: 34,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.colorScheme.onSurfaceVariant
                              .withValues(alpha: .45),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChaptersView extends StatefulWidget {
  const _ChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_ChaptersView> createState() => _ChaptersViewState();
}

class _ChaptersViewState extends State<_ChaptersView> {
  bool desc = false;

  late final ScrollController _scrollController;

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int epIndex = widget.reader.chapter - 2;
    _scrollController = ScrollController(
      initialScrollOffset: (epIndex * 48.0 + 52).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var chapters = widget.reader.widget.chapters!;
    var current = widget.reader.chapter - 1;
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text("Chapters".tl),
            actions: [
              Tooltip(
                message: "Click to change the order".tl,
                child: TextButton.icon(
                  icon: Icon(
                    !desc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(!desc ? "Ascending".tl : "Descending".tl),
                  onPressed: () {
                    setState(() {
                      desc = !desc;
                    });
                  },
                ),
              ),
            ],
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (desc) {
                index = chapters.length - 1 - index;
              }
              var chapter = chapters.titles.elementAt(index);
              return _ChapterListTile(
                onTap: () {
                  widget.reader.toChapter(index + 1);
                  Navigator.of(context).pop();
                },
                title: chapter,
                isActive: current == index,
                isDownloaded: downloaded.contains(
                  chapters.ids.elementAt(index),
                ),
              );
            }, childCount: chapters.length),
          ),
        ],
      ),
    );
  }
}

class _GroupedChaptersView extends StatefulWidget {
  const _GroupedChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_GroupedChaptersView> createState() => _GroupedChaptersViewState();
}

class _GroupedChaptersViewState extends State<_GroupedChaptersView>
    with SingleTickerProviderStateMixin {
  ComicChapters get chapters => widget.reader.widget.chapters!;

  late final TabController tabController;

  late final ScrollController _scrollController;

  late final String initialGroupName;

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int index = 0;
    int epIndex = widget.reader.chapter - 1;
    while (epIndex >= 0) {
      epIndex -= chapters.getGroupByIndex(index).length;
      index++;
    }
    tabController = TabController(
      length: chapters.groups.length,
      vsync: this,
      initialIndex: index - 1,
    );
    initialGroupName = chapters.groups.elementAt(index - 1);
    var epIndexAtGroup = widget.reader.chapter - 1;
    for (var i = 0; i < index - 1; i++) {
      epIndexAtGroup -= chapters.getGroupByIndex(i).length;
    }
    _scrollController = ScrollController(
      initialScrollOffset: (epIndexAtGroup * 48.0).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  void dispose() {
    tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Appbar(title: Text("Chapters".tl)),
        AppTabBar(
          controller: tabController,
          tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
        ),
        Expanded(
          child: TabViewBody(
            controller: tabController,
            children: chapters.groups.map(buildGroup).toList(),
          ),
        ),
      ],
    );
  }

  Widget buildGroup(String groupName) {
    var group = chapters.getGroup(groupName);
    return SmoothCustomScrollView(
      controller: initialGroupName == groupName ? _scrollController : null,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            var name = group.values.elementAt(index);
            var i = 0;
            for (var g in chapters.groups) {
              if (g == groupName) {
                break;
              }
              i += chapters.getGroup(g).length;
            }
            i += index + 1;
            return _ChapterListTile(
              onTap: () {
                widget.reader.toChapter(i);
                context.pop();
              },
              title: name,
              isActive: widget.reader.chapter == i,
              isDownloaded: downloaded.contains(group.keys.elementAt(index)),
            );
          }, childCount: group.length),
        ),
      ],
    );
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    required this.title,
    required this.isActive,
    required this.isDownloaded,
    required this.onTap,
  });

  final String title;

  final bool isActive;

  final bool isDownloaded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isActive
                  ? context.colorScheme.primary
                  : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              title,
              style: isActive
                  ? ts.withColor(context.colorScheme.primary).bold.s16
                  : ts.s16,
            ),
            const Spacer(),
            if (isDownloaded)
              Icon(
                Icons.download_done_rounded,
                color: context.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );
  }
}
