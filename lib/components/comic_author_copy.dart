part of 'components.dart';

class ComicAuthorCopyTarget extends StatelessWidget {
  const ComicAuthorCopyTarget({
    super.key,
    required this.text,
    required this.resolution,
    required this.onTap,
    required this.child,
    required this.borderRadius,
  });

  final String text;
  final ComicAuthorCopyResolution? resolution;
  final VoidCallback onTap;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final hasAlternatives = resolution?.hasAlternatives ?? false;
    return InkWell(
      borderRadius: borderRadius,
      onTap: onTap,
      onLongPress: () {
        if (hasAlternatives) {
          showComicAuthorCopyMenu(context, text: text);
        } else {
          _copyComicAuthorText(context, text);
        }
      },
      onSecondaryTapDown: (details) {
        showMenuX(context, details.globalPosition, [
          MenuEntry(
            icon: Icons.remove_red_eye,
            text: "View".tl,
            onClick: onTap,
          ),
          MenuEntry(
            icon: Icons.copy,
            text: "Copy".tl,
            onClick: () {
              if (hasAlternatives) {
                showComicAuthorCopyMenu(context, text: text);
              } else {
                _copyComicAuthorText(context, text);
              }
            },
          ),
        ]);
      },
      child: child,
    );
  }
}

void _copyComicAuthorText(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  context.showMessage(message: "Copied".tl);
}

Future<void> showComicAuthorCopyMenu(
  BuildContext context, {
  required String text,
}) async {
  final resolution = resolveComicAuthorCopyCandidates(text);
  if (!resolution.hasAlternatives || !context.mounted) return;

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
                  'Choose an author to copy'.tl,
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
                      return _ComicAuthorCopyCandidateTile(
                        candidate: candidate,
                        onTap: () => _copyComicAuthorCandidate(
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

Future<void> _copyComicAuthorCandidate(
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

class _ComicAuthorCopyCandidateTile extends StatelessWidget {
  const _ComicAuthorCopyCandidateTile({
    required this.candidate,
    required this.onTap,
  });

  final ComicAuthorCopyCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch (candidate.kind) {
      ComicAuthorCandidateKind.bracketInner => 'Bracketed Part'.tl,
      ComicAuthorCandidateKind.outside => 'Outside Part'.tl,
      ComicAuthorCandidateKind.full => 'Full Author Info'.tl,
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
        key: ValueKey('comic-author-copy-candidate-${candidate.text}'),
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
