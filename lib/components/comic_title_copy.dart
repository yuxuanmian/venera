part of 'components.dart';

/// Opens the candidate chooser used by the card and detail page smart-copy
/// actions. The caller retains the ordinary full-title copy action separately.
Future<void> showComicTitleCopyMenu(
  BuildContext context, {
  required String title,
  String? subtitle,
  Iterable<String> knownAuthors = const [],
}) async {
  final resolution = resolveComicTitleCopyCandidates(
    title: title,
    subtitle: subtitle,
    knownAuthors: knownAuthors,
  );
  if (resolution.candidates.isEmpty || !context.mounted) return;

  final dialogContext = _comicCopyDialogContext(context);
  if (dialogContext == null || !dialogContext.mounted) return;

  await showDialog<void>(
    context: dialogContext,
    useRootNavigator: true,
    builder: (dialogContext) {
      return Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: (MediaQuery.sizeOf(dialogContext).height - 80)
                .clamp(120.0, 560.0)
                .toDouble(),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose a title to copy'.tl,
                  style: Theme.of(dialogContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: resolution.candidates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final candidate = resolution.candidates[index];
                      return _ComicTitleCopyCandidateTile(
                        candidate: candidate,
                        onTap: () => _copyComicTitleCandidate(
                          dialogContext,
                          candidate.text,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

BuildContext? _comicCopyDialogContext(BuildContext context) {
  // SelectableText's context-menu builder can be invoked from Flutter's root
  // selection overlay, whose context is not below a Navigator. Use the
  // supplied context when possible, and fall back to the app root navigator
  // for that overlay case.
  return Navigator.maybeOf(context) == null
      ? App.rootNavigatorKey.currentContext
      : context;
}

Future<void> _copyComicTitleCandidate(
  BuildContext dialogContext,
  String text,
) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (!dialogContext.mounted) return;
    Navigator.of(dialogContext).pop();
    App.rootContext.showMessage(message: 'Copied'.tl);
  } catch (_) {
    if (dialogContext.mounted) {
      dialogContext.showMessage(message: 'Error'.tl);
    }
  }
}

class _ComicTitleCopyCandidateTile extends StatelessWidget {
  const _ComicTitleCopyCandidateTile({
    required this.candidate,
    required this.onTap,
  });

  final ComicTitleCopyCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch ((candidate.field, candidate.kind)) {
      (ComicTitleField.title, ComicTitleCandidateKind.cleaned) =>
        'Main Title'.tl,
      (ComicTitleField.subtitle, ComicTitleCandidateKind.cleaned) =>
        'Subtitle'.tl,
      (ComicTitleField.title, ComicTitleCandidateKind.raw) => 'Full Title'.tl,
      (ComicTitleField.subtitle, ComicTitleCandidateKind.raw) =>
        'Full Subtitle'.tl,
    };
    final semanticsLabel = [
      if (candidate.recommended) 'Recommended'.tl,
      label,
      candidate.text,
    ].join(': ');
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: InkWell(
        key: ValueKey('comic-title-copy-candidate-${candidate.text}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        if (candidate.recommended) ...[
                          const SizedBox(width: 8),
                          _ComicTitleCopyBadge(text: 'Recommended'.tl),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      candidate.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.copy_outlined, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComicTitleCopyBadge extends StatelessWidget {
  const _ComicTitleCopyBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

/// A selectable title that keeps Flutter's normal selection/copy controls and
/// clears its selection when the user taps elsewhere.
class ComicTitleSelectableText extends StatefulWidget {
  const ComicTitleSelectableText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<ComicTitleSelectableText> createState() =>
      _ComicTitleSelectableTextState();
}

class _ComicTitleSelectableTextState extends State<ComicTitleSelectableText> {
  late final FocusNode _focusNode;
  var _selectionEpoch = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(skipTraversal: true);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _clearSelection() {
    _focusNode.unfocus();
    if (mounted) {
      setState(() {
        _selectionEpoch++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      // Keep the native selection toolbar in the same group so tapping Copy
      // is not mistaken for an outside tap.
      groupId: EditableText,
      onTapOutside: (_) => _clearSelection(),
      child: SelectableText(
        key: ValueKey(_selectionEpoch),
        widget.text,
        focusNode: _focusNode,
        style: widget.style,
      ),
    );
  }
}

class ComicTitleCopyButton extends StatelessWidget {
  const ComicTitleCopyButton({
    super.key,
    required this.title,
    this.subtitle,
    this.knownAuthors = const [],
  });

  final String title;
  final String? subtitle;
  final Iterable<String> knownAuthors;

  @override
  Widget build(BuildContext context) {
    final label = 'Copy Original Title'.tl;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: IconButton(
          key: const ValueKey('comic-title-copy-button'),
          icon: Icon(
            Icons.copy_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          iconSize: 14,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => showComicTitleCopyMenu(
            context,
            title: title,
            subtitle: subtitle,
            knownAuthors: knownAuthors,
          ),
        ),
      ),
    );
  }
}
