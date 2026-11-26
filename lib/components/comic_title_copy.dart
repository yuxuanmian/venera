part of 'components.dart';

Future<void> copyComicTitle(
  BuildContext context, {
  required String title,
  String? subtitle,
  Iterable<String> knownAuthors = const [],
}) async {
  if (!context.mounted) return;
  final groups = resolveComicTitleCopyGroups(
    title: title,
    subtitle: subtitle,
    knownAuthors: knownAuthors,
  );
  if (groups.isEmpty) return;

  final dialogContext = _comicCopyDialogContext(context);
  if (dialogContext == null || !dialogContext.mounted) return;

  final text = groups.length == 1 && groups.single.parts.length == 1
      ? groups.single.raw
      : await showDialog<String>(
          context: dialogContext,
          builder: (_) => _TitlePartsDialog(groups: groups),
        );
  if (text == null) return;

  var message = 'Copied'.tl;
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    message = 'Error'.tl;
  }
  final messageContext = App.rootNavigatorKey.currentContext ?? dialogContext;
  if (messageContext.mounted) {
    messageContext.showMessage(message: message);
  }
}

BuildContext? _comicCopyDialogContext(BuildContext context) {
  // A selection overlay can sit above the nearest Navigator.
  return Navigator.maybeOf(context) == null
      ? App.rootNavigatorKey.currentContext
      : context;
}

class _TitlePartsDialog extends StatefulWidget {
  const _TitlePartsDialog({required this.groups, this.paste = false});

  final List<ComicTitleCopyGroup> groups;
  final bool paste;

  @override
  State<_TitlePartsDialog> createState() => _TitlePartsDialogState();
}

class _TitlePartsDialogState extends State<_TitlePartsDialog> {
  final _selected = <ComicTitleCopyPart>{};

  ComicTitleCopyGroup? get _activeGroup => widget.groups
      .where((group) => group.parts.any(_selected.contains))
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    if (widget.groups.length == 1) {
      _selected.add(widget.groups.single.recommendedPart);
    }
  }

  void _setSelected(
    ComicTitleCopyGroup group,
    ComicTitleCopyPart part,
    bool selected,
  ) {
    final activeGroup = _activeGroup;
    if (activeGroup != null && activeGroup != group) return;
    setState(() {
      if (selected) {
        _selected.add(part);
      } else {
        _selected.remove(part);
      }
    });
  }

  void _finish() {
    final group = _activeGroup;
    if (group == null || ModalRoute.isCurrentOf(context) != true) return;
    Navigator.of(context).pop(group.compose(_selected));
  }

  @override
  Widget build(BuildContext context) {
    final activeGroup = _activeGroup;
    final colors = Theme.of(context).colorScheme;
    final disabledText = colors.onSurfaceVariant.withValues(alpha: 0.65);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      title: Text((widget.paste ? 'Paste Title' : 'Copy Title').tl),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final group in widget.groups) ...[
                if (group != widget.groups.first) const SizedBox(height: 16),
                if (widget.groups.length > 1) ...[
                  Text(
                    group.field == ComicTitleField.title
                        ? 'Main Title'.tl
                        : 'Subtitle'.tl,
                    style: TextStyle(
                      color: activeGroup == null || activeGroup == group
                          ? colors.onSurfaceVariant
                          : disabledText,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final part in group.parts)
                      FilterChip(
                        label: Text(part.text),
                        selected: _selected.contains(part),
                        showCheckmark: false,
                        backgroundColor: colors.surfaceContainerHighest,
                        selectedColor: colors.primary,
                        disabledColor: colors.surfaceContainerLow,
                        side: BorderSide.none,
                        labelStyle: TextStyle(
                          color: _selected.contains(part)
                              ? colors.onPrimary
                              : activeGroup == null || activeGroup == group
                              ? colors.onSurface
                              : disabledText,
                        ),
                        onSelected: activeGroup != null && activeGroup != group
                            ? null
                            : (selected) => _setSelected(group, part, selected),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: activeGroup == null ? null : _finish,
          child: Text((widget.paste ? 'Paste' : 'Copy').tl),
        ),
      ],
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
          onPressed: () => copyComicTitle(
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
