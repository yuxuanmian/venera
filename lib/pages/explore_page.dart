import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

class SourceExplorePage extends StatefulWidget {
  const SourceExplorePage({
    super.key,
    required this.source,
    required this.data,
  });

  final ComicSource source;
  final ExplorePageData data;

  @override
  State<SourceExplorePage> createState() => _SourceExplorePageState();
}

class _SourceExplorePageState extends State<SourceExplorePage> {
  final _changes = Listenable.merge([appdata.settings, ComicSourceManager()]);
  VoidCallback? _refresh;

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final data = widget.data;
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final available =
            isSourceEnabled(source.key) &&
            identical(ComicSource.find(source.key), source);
        return Scaffold(
          appBar: Appbar(
            title: Text(data.title.ts(source.key)),
            actions: [
              if (available)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh'.tl,
                  onPressed: () => _refresh?.call(),
                ),
            ],
          ),
          body: available
              ? _buildContent(data)
              : Center(child: Text('Not found'.tl)),
        );
      },
    );
  }

  Widget _buildContent(ExplorePageData data) {
    void registerRefresh(VoidCallback refresh) => _refresh = refresh;

    if (data.loadMultiPart != null) {
      return _MultiPartExplorePage(
        data: data,
        refreshHandlerCallback: registerRefresh,
      );
    }
    if (data.loadPage != null || data.loadNext != null) {
      return ComicList(
        loadPage: data.loadPage,
        loadNext: data.loadNext,
        refreshHandlerCallback: registerRefresh,
      );
    }
    if (data.loadMixed != null) {
      return _MixedExplorePage(data, refreshHandlerCallback: registerRefresh);
    }
    return Center(child: Text('Not found'.tl));
  }
}

class _MixedExplorePage extends StatefulWidget {
  const _MixedExplorePage(this.data, {required this.refreshHandlerCallback});

  final ExplorePageData data;

  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MixedExplorePage> createState() => _MixedExplorePageState();
}

class _MixedExplorePageState
    extends MultiPageLoadingState<_MixedExplorePage, Object> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.refreshHandlerCallback(refresh);
  }

  void refresh() {
    reset();
  }

  Iterable<Widget> buildSlivers(BuildContext context, List<Object> data) sync* {
    List<Comic> cache = [];
    for (var part in data) {
      if (part is ExplorePagePart) {
        if (cache.isNotEmpty) {
          yield SliverGridComics(comics: cache);
          yield const SliverToBoxAdapter(child: Divider());
          cache = [];
        }
        yield* _buildExplorePagePart(part, context);
        yield const SliverToBoxAdapter(child: Divider());
      } else {
        cache.addAll(part as List<Comic>);
      }
    }
    if (cache.isNotEmpty) {
      yield SliverGridComics(comics: cache);
    }
  }

  @override
  Widget buildContent(BuildContext context, List<Object> data) {
    return SmoothCustomScrollView(
      slivers: [
        ...buildSlivers(context, data),
        const SliverListLoadingIndicator(),
      ],
    );
  }

  @override
  Future<Res<List<Object>>> loadData(int page) async {
    var res = await widget.data.loadMixed!(page);
    if (res.error) {
      return res;
    }
    for (var element in res.data) {
      if (element is! ExplorePagePart && element is! List<Comic>) {
        return const Res.error("function loadMixed return invalid data");
      }
    }
    return res;
  }
}

Iterable<Widget> _buildExplorePagePart(
  ExplorePagePart part,
  BuildContext context,
) sync* {
  Widget buildTitle(ExplorePagePart part) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  part.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (part.viewMore != null)
                TextButton(
                  onPressed: () => part.viewMore!.jump(context),
                  child: Text("View more".tl),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildComics(ExplorePagePart part) {
    return SliverGridComics(comics: part.comics);
  }

  yield buildTitle(part);
  yield buildComics(part);
}

class _MultiPartExplorePage extends StatefulWidget {
  const _MultiPartExplorePage({
    required this.data,
    required this.refreshHandlerCallback,
  });

  final ExplorePageData data;

  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MultiPartExplorePage> createState() => _MultiPartExplorePageState();
}

class _MultiPartExplorePageState extends State<_MultiPartExplorePage> {
  late Future<Res<List<ExplorePagePart>>> _request;

  @override
  void initState() {
    super.initState();
    _request = widget.data.loadMultiPart!();
    widget.refreshHandlerCallback(_refresh);
  }

  void _refresh() {
    setState(() => _request = widget.data.loadMultiPart!());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final result = snapshot.data;
        if (result == null || result.error) {
          return NetworkError(
            message: result?.errorMessage ?? snapshot.error.toString(),
            retry: _refresh,
            withAppbar: false,
          );
        }

        return SmoothCustomScrollView(
          key: const PageStorageKey('scroll'),
          slivers: [
            for (final part in result.data)
              ..._buildExplorePagePart(part, context),
          ],
        );
      },
    );
  }
}
