part of 'components.dart';

class _SearchTextField extends StatefulWidget {
  const _SearchTextField({
    required this.controller,
    required this.inputFormatters,
    required this.onChanged,
    required this.onSubmitted,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController controller;
  final List<TextInputFormatter> inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<_SearchTextField> createState() => _SearchTextFieldState();
}

class _SearchTextFieldState extends State<_SearchTextField> {
  bool _pasting = false;
  late final _imePasteFormatter = TextInputFormatter.withFunction(
    _formatImeInsertion,
  );

  EditableTextState? get _focusedEditable {
    final editable = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    return editable?.widget.controller == widget.controller ? editable : null;
  }

  Object? _pasteFromKeyboard(PasteTextIntent intent) {
    final editable = _focusedEditable;
    if (editable != null) unawaited(_paste(editable, intent.cause));
    return null;
  }

  TextEditingValue _formatImeInsertion(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final range = oldValue.selection;
    final end = newValue.selection.extentOffset;
    if (_pasting ||
        !oldValue.composing.isCollapsed ||
        !newValue.composing.isCollapsed ||
        !range.isValid ||
        range.end > oldValue.text.length ||
        !newValue.selection.isCollapsed ||
        end > newValue.text.length ||
        end - range.start < 3 ||
        !newValue.text.startsWith(oldValue.text.substring(0, range.start)) ||
        newValue.text.substring(end) != oldValue.text.substring(range.end)) {
      return newValue;
    }

    // An IME can commit its clipboard history directly as a text edit.
    final groups = resolveComicTitleCopyGroups(
      title: newValue.text.substring(range.start, end),
    );
    final editable = _focusedEditable;
    if (editable == null || (groups.singleOrNull?.parts.length ?? 0) <= 1) {
      return newValue;
    }
    unawaited(
      _paste(editable, SelectionChangedCause.keyboard, imeGroups: groups),
    );
    return oldValue;
  }

  Widget _buildContextMenu(BuildContext context, EditableTextState editable) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: [
        for (final item in editable.contextMenuButtonItems)
          if (item.type == ContextMenuButtonType.paste)
            item.copyWith(
              onPressed: () => _paste(editable, SelectionChangedCause.toolbar),
            )
          else
            item,
      ],
    );
  }

  Future<void> _paste(
    EditableTextState editable,
    SelectionChangedCause cause, {
    List<ComicTitleCopyGroup>? imeGroups,
  }) async {
    final initial = editable.textEditingValue;
    if (_pasting || !initial.selection.isValid) return;
    final route = ModalRoute.of(context);
    bool canInsert() =>
        mounted &&
        editable.mounted &&
        editable.widget.controller == widget.controller &&
        route?.isCurrent != false &&
        editable.textEditingValue.text == initial.text &&
        editable.textEditingValue.selection == initial.selection;

    _pasting = true;
    try {
      // Yield for an IME edit so its formatter returns before showing a dialog.
      final text = imeGroups == null
          ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
          : await Future.value(imeGroups.single.raw);
      if (text == null ||
          text.isEmpty ||
          !canInsert() ||
          !editable.widget.focusNode.hasFocus) {
        return;
      }

      editable.hideToolbar();
      final groups = imeGroups ?? resolveComicTitleCopyGroups(title: text);
      final hasChoices = (groups.singleOrNull?.parts.length ?? 0) > 1;
      final selected = hasChoices
          ? await showDialog<String>(
              context: context,
              builder: (_) => _TitlePartsDialog(groups: groups, paste: true),
            )
          : text;
      if (!canInsert()) return;
      if (hasChoices && !editable.widget.focusNode.hasFocus) {
        // Restore editing without the desktop field selecting all on focus.
        editable.requestKeyboard();
      }
      if (selected == null) return;

      final value = editable.textEditingValue;
      final collapsed = value.copyWith(
        selection: TextSelection.collapsed(offset: value.selection.end),
      );
      editable.userUpdateTextEditingValue(
        collapsed.replaced(value.selection, selected),
        cause,
      );
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription('while pasting text in the search field'),
        ),
      );
    } finally {
      _pasting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: _pasteFromKeyboard,
        ),
      },
      child: TextField(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        controller: widget.controller,
        inputFormatters: [_imePasteFormatter, ...widget.inputFormatters],
        contextMenuBuilder: _buildContextMenu,
        decoration: InputDecoration(
          hintText: 'Search'.tl,
          border: InputBorder.none,
        ),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}
