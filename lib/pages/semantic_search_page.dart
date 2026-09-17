import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/semantic_search/controller.dart';
import 'package:venera/foundation/semantic_search/models.dart';
import 'package:venera/foundation/semantic_search/source_resolver.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/translations.dart';

/// The independent Tag semantic result page.
///
/// It fixes the source, the kind (`tag`) and the opaque value produced by the
/// source. It deliberately has no search field, no value editing, no source
/// switch, no history, no suggestions and no automatic language filter. Only the
/// sorting option definition and the comic grid/card presentation are shared
/// with ordinary search.
class SemanticSearchPage extends StatefulWidget {
  const SemanticSearchPage({
    super.key,
    required this.sourceKey,
    required this.value,
    this.controller,
    this.initialOptions,
    this.onControllerCreated,
  });

  /// The comic source that produced the value. It never changes on this page.
  final String sourceKey;

  /// Opaque source-produced token. Never trimmed, re-cased or reparsed.
  final String value;

  /// Injected controller for tests. When present the page never builds its own
  /// resolver and never disposes it.
  @visibleForTesting
  final SemanticSearchController? controller;

  @visibleForTesting
  final List<String>? initialOptions;

  @visibleForTesting
  final ValueChanged<SemanticSearchController>? onControllerCreated;

  @override
  State<SemanticSearchPage> createState() => _SemanticSearchPageState();
}

class _SemanticSearchPageState extends State<SemanticSearchPage> {
  SemanticSearchController? _controller;

  ComicSourceSemanticResolver? _resolver;

  ComicSource? _source;

  late List<String> _options;

  bool _ownsController = false;

  /// A gesture epoch exists only between a `ScrollStartNotification` that
  /// carries non-null `dragDetails` and its `ScrollEndNotification`. One epoch
  /// may open at most one cycle, even if the load finishes immediately.
  bool _epochOpen = false;

  bool _epochConsumed = false;

  @override
  void initState() {
    super.initState();
    _source = ComicSource.find(widget.sourceKey);
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      _options = List<String>.from(widget.initialOptions ?? const <String>[]);
    } else {
      final source = _source;
      if (source != null) {
        _options = List<String>.from(
          widget.initialOptions ?? _defaultOptions(source),
        );
        _resolver = ComicSourceSemanticResolver(source);
        final controller = SemanticSearchController(
          query: SemanticQuery(
            sourceKey: source.key,
            value: widget.value,
            options: _options,
          ),
          resolver: _resolver!,
        );
        _controller = controller;
        _ownsController = true;
      }
    }
    final controller = _controller;
    if (controller != null) {
      controller.addListener(_onControllerChanged);
      widget.onControllerCreated?.call(controller);
      controller.start();
    }
  }

  /// The same defaults the ordinary search page builds from `optionList`.
  static List<String> _defaultOptions(ComicSource source) {
    final declared =
        source.searchPageData?.searchOptions ?? const <SearchOptions>[];
    return declared.map((option) => option.defaultValue).toList();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final controller = _controller;
    controller?.removeListener(_onControllerChanged);
    if (_ownsController) {
      // The controller cancels its lane and retires the generation before the
      // widget releases its own listeners.
      controller?.dispose();
      _resolver?.dispose();
    }
    super.dispose();
  }

  // --- gesture epoch gate -------------------------------------------------

  bool _nearEnd(ScrollNotification notification) =>
      notification.metrics.extentAfter <=
      notification.metrics.viewportDimension * 0.5;

  bool _acceptsIntent(ScrollNotification notification) {
    if (_epochOpen && !_epochConsumed) return true;
    return false;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    final controller = _controller;
    if (controller == null) return false;
    if (controller.status == SemanticSearchStatus.finished ||
        controller.status == SemanticSearchStatus.unsupported) {
      _epochOpen = false;
      return false;
    }
    if (notification is ScrollStartNotification) {
      // Near-end or short-content status alone never opens an epoch; only a
      // real user drag does.
      if (notification.dragDetails != null) {
        _epochOpen = true;
        _epochConsumed = false;
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      _epochOpen = false;
      _epochConsumed = false;
      return false;
    }
    if (notification.depth != 0) return false;

    var forward = false;
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      // `ClampingScrollPhysics` additionally reports a real trailing
      // `OverscrollNotification`; the metrics check keeps the same intent
      // detectable on a platform whose physics only bounce.
      final beyondEnd =
          notification.metrics.pixels > notification.metrics.maxScrollExtent;
      forward = delta > 0 && (_nearEnd(notification) || beyondEnd);
    } else if (notification is OverscrollNotification) {
      final overscroll = notification.overscroll;
      final waiting =
          controller.status == SemanticSearchStatus.waitingForContinue;
      // An undersized or empty list can still express a trailing overscroll
      // intent, which is why the scrollable is always scrollable.
      forward =
          overscroll > 0 &&
          (_nearEnd(notification) || waiting || controller.visible.isEmpty);
    }
    if (!forward || !_acceptsIntent(notification)) return false;
    _epochConsumed = true;
    controller.continueWithUserIntent();
    return false;
  }

  // --- rendering ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final controller = _controller;
    // A missing source or a missing controller is the unsupported terminal
    // state. An injected controller keeps the page usable without a published
    // source, which is what the widget tests rely on.
    final unsupported =
        controller == null ||
        controller.mode == SemanticCapabilityMode.unsupported;
    // The declared option groups are the single source of truth for the option
    // entry: zero groups mean no entry at all, exactly one group can live in the
    // title's secondary area, and two or more keep the dedicated Settings entry.
    // Nothing here branches on the source key.
    final declaredOptions =
        source?.searchPageData?.searchOptions ?? const <SearchOptions>[];
    final optionCount = unsupported ? 0 : declaredOptions.length;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: Appbar(
        title: _buildTitle(context, source, optionCount == 1),
        actions: [
          if (optionCount >= 2)
            Tooltip(
              message: "Settings".tl,
              child: IconButton(
                icon: const Icon(Icons.tune),
                onPressed: _openOptions,
              ),
            ),
        ],
      ),
      body: unsupported
          ? _buildUnsupported(context)
          : _buildBody(context, controller),
    );
  }

  Widget _buildTitle(
    BuildContext context,
    ComicSource? source,
    bool singleOption,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Tag: @a'.tlParams({'a': widget.value}), maxLines: 1),
        if (singleOption)
          // The one declared option replaces the source subtitle with its own
          // current, human-readable value, and tapping it opens the same dialog
          // the tune action used to open.
          InkWell(
            onTap: _openOptions,
            child: Text(
              _singleOptionValue(source),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          )
        else if (source != null)
          Text(
            source.name.tl,
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
      ],
    );
  }

  /// The display value of the only declared option group.
  ///
  /// It uses the same display semantics as [SearchOptionWidget], so a raw
  /// encoded value (for example `dd-New to old`, stored as the key `dd`) is
  /// never shown verbatim: the map value is translated with the source
  /// translations. A multi-select value is a JSON list, and each element is
  /// resolved the same way so the title stays readable.
  String _singleOptionValue(ComicSource? source) {
    final declared =
        source?.searchPageData?.searchOptions ?? const <SearchOptions>[];
    if (declared.isEmpty) return '';
    final option = declared.first;
    final key = source?.key ?? _source?.key ?? '';
    final current = _controller?.query.options.firstOrNull;
    final value = current ?? option.defaultValue;
    if (value.isEmpty) return '';
    if (option.type == 'multi-select') {
      return value
          .split(',')
          .map((entry) => _optionValueLabel(option, entry, key))
          .join(', ');
    }
    return _optionValueLabel(option, value, key);
  }

  String _optionValueLabel(SearchOptions option, String value, String key) {
    final label = option.options[value];
    return label == null ? value : label.ts(key);
  }

  Widget _buildUnsupported(BuildContext context) {
    return NetworkError(
      withAppbar: false,
      message: "This comic source cannot search by tag".tl,
    );
  }

  Widget _buildBody(BuildContext context, SemanticSearchController controller) {
    final topPadding = context.padding.top + 56.0;
    if (controller.status == SemanticSearchStatus.error &&
        controller.visible.isEmpty) {
      return NetworkError(
        withAppbar: false,
        message: controller.errorMessage ?? "Network Error".tl,
        retry: controller.retry,
      );
    }
    final slivers = <Widget>[
      SliverPadding(padding: EdgeInsets.only(top: topPadding)),
      if (controller.mode == SemanticCapabilityMode.ordinaryFallback)
        SliverToBoxAdapter(child: _buildFallbackNotice(context)),
      SliverGridComics(comics: controller.visible),
      SliverToBoxAdapter(child: _buildFooter(context, controller)),
    ];
    final scrollView = SmoothCustomScrollView(
      // Always scrollable so an empty or undersized result set can still
      // express a trailing overscroll intent; the clamping parent is what makes
      // that overscroll observable as a notification.
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      slivers: slivers,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: RefreshIndicator(onRefresh: controller.refresh, child: scrollView),
    );
  }

  /// The compatibility mode never claims exact Tag semantics.
  Widget _buildFallbackNotice(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: color.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "This source has no exact tag search; results are not guaranteed to be exact."
                  .tl,
              style: TextStyle(fontSize: 13, color: color.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    SemanticSearchController controller,
  ) {
    final color = Theme.of(context).colorScheme;
    switch (controller.status) {
      case SemanticSearchStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        );
      case SemanticSearchStatus.waitingForContinue:
        // Never "No results" and never "Finished": the current range is empty
        // but the source still has more candidates to scan.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Center(
            child: Text(
              "No matches in the current range. Continue scrolling to search further."
                  .tl,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: color.outline),
            ),
          ),
        );
      case SemanticSearchStatus.finished:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              "Finished".tl,
              style: TextStyle(fontSize: 13, color: color.outline),
            ),
          ),
        );
      case SemanticSearchStatus.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.error_outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(controller.errorMessage ?? "Network Error".tl),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.retry,
                child: Text("Retry".tl),
              ),
            ],
          ),
        );
      case SemanticSearchStatus.initial:
      case SemanticSearchStatus.idle:
      case SemanticSearchStatus.disposed:
      case SemanticSearchStatus.unsupported:
        return const SizedBox(height: 24);
    }
  }

  Future<void> _openOptions() async {
    final source = _source;
    final controller = _controller;
    if (source == null || controller == null) return;
    final declared =
        source.searchPageData?.searchOptions ?? const <SearchOptions>[];
    if (declared.isEmpty) return;
    final current = List<String>.from(controller.query.options);
    while (current.length < declared.length) {
      current.add(declared[current.length].defaultValue);
    }
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => _SemanticOptionsDialog(
        sourceKey: source.key,
        options: declared,
        values: current,
      ),
    );
    if (confirmed != true || !mounted) return;
    // Sorting is applied before the source request: the controller cancels the
    // old attempt and restarts from the initial cursor with the new snapshot.
    await controller.updateOptions(current);
  }
}

class _SemanticOptionsDialog extends StatefulWidget {
  const _SemanticOptionsDialog({
    required this.sourceKey,
    required this.options,
    required this.values,
  });

  final String sourceKey;

  final List<SearchOptions> options;

  final List<String> values;

  @override
  State<_SemanticOptionsDialog> createState() => _SemanticOptionsDialogState();
}

class _SemanticOptionsDialogState extends State<_SemanticOptionsDialog> {
  @override
  Widget build(BuildContext context) {
    // `ContentDialog` gives its content no horizontal padding and
    // `SearchOptionWidget` provides none of its own, so the caller must inset
    // the rows. This mirrors the ordinary search settings dialog's 16dp, which
    // is what keeps the labels and the option chips off the dialog edge.
    return ContentDialog(
      title: "Settings".tl,
      content: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.options.length; i++)
              SearchOptionWidget(
                option: widget.options[i],
                value: widget.values[i],
                sourceKey: widget.sourceKey,
                onChanged: (value) {
                  setState(() {
                    widget.values[i] = value;
                  });
                },
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => context.pop(true),
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
