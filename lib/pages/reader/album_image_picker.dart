import 'package:flutter/material.dart';
import 'package:venera/utils/translations.dart';

typedef AlbumImageChoice = ({int index, Rect rect, bool ready, bool failed});

Rect? visibleAlbumImageRect(
  RenderBox image,
  RenderBox viewport,
  Rect paintedBounds, {
  Rect? contentClip,
}) {
  final rect = MatrixUtils.transformRect(
    image.getTransformTo(viewport),
    paintedBounds,
  ).intersect(Offset.zero & viewport.size);
  final visible = contentClip == null ? rect : rect.intersect(contentClip);
  return visible.isFinite && !visible.isEmpty ? visible : null;
}

class AlbumImagePicker extends StatelessWidget {
  const AlbumImagePicker({
    super.key,
    required this.choices,
    required this.selectedIndex,
    required this.onSelect,
    required this.onCancel,
  });

  final List<AlbumImageChoice> choices;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final picking = selectedIndex == null;
    return Stack(
      children: [
        const Positioned.fill(
          child: ModalBarrier(dismissible: false, color: Color(0x33000000)),
        ),
        for (final choice in choices)
          Positioned.fromRect(
            rect: choice.rect,
            child: _buildChoice(context, choice, picking),
          ),
        Align(
          alignment: Alignment.topCenter,
          child: SafeArea(
            bottom: false,
            minimum: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Material(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          picking ? 'Tap the image to save'.tl : 'Saving…'.tl,
                        ),
                      ),
                    ),
                    if (picking)
                      TextButton(onPressed: onCancel, child: Text('Cancel'.tl)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChoice(
    BuildContext context,
    AlbumImageChoice choice,
    bool picking,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = choice.index == selectedIndex;
    final enabled = picking && choice.ready;
    final label = 'Image @number'.tlParams({'number': choice.index + 1});
    final status = choice.ready
        ? null
        : choice.failed
        ? 'Image unavailable'.tl
        : 'Loading image…'.tl;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: status == null ? label : '$label, $status',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onSelect(choice.index) : null,
        child: ClipRect(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: colors.onPrimary),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  width: selected ? 3.5 : 2,
                  color: colors.primary,
                ),
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.primary
                          : colors.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? colors.onPrimary : colors.primary,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          status == null ? label : '$label · $status',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: selected
                                ? colors.onPrimary
                                : colors.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
