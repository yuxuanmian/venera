import "package:flutter/material.dart";
import "package:venera/components/components.dart";
import "package:venera/foundation/app.dart";
import "package:venera/foundation/catalog/source_preferences.dart";
import "package:venera/foundation/comic_source/comic_source.dart";
import "package:venera/utils/translations.dart";

class RankingPage extends StatefulWidget {
  const RankingPage({required this.sourceKey, super.key});

  final String sourceKey;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  late final RankingData ranking;
  late String optionValue;

  void findData() {
    final data = ComicSource.find(widget.sourceKey)?.categoryComicsData;
    final sourceRanking = data?.rankingData;
    if (sourceRanking == null ||
        sourceRanking.options.isEmpty ||
        !isSourceEnabled(widget.sourceKey)) {
      throw StateError(
        "Ranking is unavailable for source: ${widget.sourceKey}",
      );
    }
    ranking = sourceRanking;
    optionValue = ranking.options.keys.first;
  }

  @override
  void initState() {
    findData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var topPadding = context.padding.top + 56;
    final option = optionValue;
    final load = ranking.load;
    final loadWithNext = ranking.loadWithNext;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: Appbar(title: Text("Ranking".tl)),
      body: ComicList(
        key: Key(option),
        showRankingMedals: true,
        errorLeading: SizedBox(height: topPadding),
        leadingSliver: buildOptions().sliverPadding(
          EdgeInsets.only(top: topPadding),
        ),
        loadPage: load == null ? null : (page) => load(option, page),
        loadNext: loadWithNext == null
            ? null
            : (next) => loadWithNext(option, next),
      ),
    );
  }

  Widget buildOptionItem(String text, String value, BuildContext context) {
    return OptionChip(
      text: text,
      isSelected: value == optionValue,
      onTap: () {
        if (value == optionValue) return;
        setState(() {
          optionValue = value;
        });
      },
    );
  }

  Widget buildOptions() {
    List<Widget> children = [];
    children.add(
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var option in ranking.options.entries)
            buildOptionItem(option.value.tl, option.key, context),
        ],
      ),
    );
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [...children, const Divider()],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}
