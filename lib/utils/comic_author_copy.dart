// Pure candidate extraction for copying author and artist tag text.
//
// Author parsing is deliberately independent from title parsing. It only
// recognizes balanced bracket structure and never guesses an author's role
// from the text itself.

enum ComicAuthorCandidateKind { bracketInner, outside, full }

class ComicAuthorCopyCandidate {
  const ComicAuthorCopyCandidate({
    required this.text,
    required this.kind,
    required this.recommended,
    required this.sourceOrder,
  });

  final String text;
  final ComicAuthorCandidateKind kind;
  final bool recommended;
  final int sourceOrder;
}

class ComicAuthorCopyResolution {
  const ComicAuthorCopyResolution(this.candidates);

  final List<ComicAuthorCopyCandidate> candidates;

  bool get hasAlternatives => candidates.length > 1;

  ComicAuthorCopyCandidate? get recommendedOrNull {
    for (final candidate in candidates) {
      if (candidate.recommended) return candidate;
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  ComicAuthorCopyCandidate get recommended => recommendedOrNull!;
}

ComicAuthorCopyResolution resolveComicAuthorCopyCandidates(String value) {
  if (value.trim().isEmpty) {
    return const ComicAuthorCopyResolution([]);
  }

  final scanned = _scan(value);
  if (scanned.malformed || scanned.blocks.isEmpty) {
    return ComicAuthorCopyResolution([
      ComicAuthorCopyCandidate(
        text: value,
        kind: ComicAuthorCandidateKind.full,
        recommended: true,
        sourceOrder: 0,
      ),
    ]);
  }

  final innerCandidates = <_GeneratedAuthorCandidate>[];
  for (var index = 0; index < scanned.blocks.length; index++) {
    final block = scanned.blocks[index];
    final blockInner = _join(scanned.characters, block.start + 1, block.end);
    final inner = _unwrapNestedBrackets(blockInner);
    final normalized = _normalize(inner);
    if (normalized.isNotEmpty) {
      innerCandidates.add(
        _GeneratedAuthorCandidate(
          text: normalized,
          kind: ComicAuthorCandidateKind.bracketInner,
          sourceOrder: index,
        ),
      );
    }
  }

  final outside = _joinOutside(scanned);
  final outsideText = _normalize(outside);
  final generated = <_GeneratedAuthorCandidate>[];
  generated.addAll(innerCandidates);
  if (outsideText.isNotEmpty) {
    generated.add(
      _GeneratedAuthorCandidate(
        text: outsideText,
        kind: ComicAuthorCandidateKind.outside,
        sourceOrder: scanned.blocks.length,
      ),
    );
  }
  generated.add(
    _GeneratedAuthorCandidate(
      text: value,
      kind: ComicAuthorCandidateKind.full,
      sourceOrder: scanned.characters.length,
    ),
  );

  final deduped = <String, _GeneratedAuthorCandidate>{};
  for (final candidate in generated) {
    final key = _normalize(candidate.text);
    final previous = deduped[key];
    if (previous == null ||
        _candidatePriority(candidate.kind) <
            _candidatePriority(previous.kind)) {
      deduped[key] = candidate;
    }
  }

  final uniqueInner = <_GeneratedAuthorCandidate>[];
  for (final candidate in innerCandidates) {
    if (deduped[_normalize(candidate.text)] == candidate &&
        !uniqueInner.any((item) => item.text == candidate.text)) {
      uniqueInner.add(candidate);
    }
  }
  final recommendedInner = innerCandidates.isEmpty
      ? null
      : innerCandidates.lastWhere(
          (candidate) => deduped[_normalize(candidate.text)] == candidate,
          orElse: () => uniqueInner.first,
        );
  final recommended =
      recommendedInner ??
      (outsideText.isNotEmpty
          ? deduped[outsideText]
          : deduped[_normalize(value)]);

  final ordered = <_GeneratedAuthorCandidate>[];
  if (recommended != null &&
      recommended.kind == ComicAuthorCandidateKind.bracketInner) {
    ordered.add(recommended);
  }
  for (final candidate in uniqueInner) {
    if (!ordered.contains(candidate)) ordered.add(candidate);
  }
  final outsideCandidate = deduped[outsideText];
  if (outsideCandidate != null && !ordered.contains(outsideCandidate)) {
    ordered.add(outsideCandidate);
  }
  final fullCandidate = deduped[_normalize(value)];
  if (fullCandidate != null && !ordered.contains(fullCandidate)) {
    ordered.add(fullCandidate);
  }
  if (ordered.isEmpty) {
    ordered.add(
      _GeneratedAuthorCandidate(
        text: value,
        kind: ComicAuthorCandidateKind.full,
        sourceOrder: 0,
      ),
    );
  }

  final candidates = <ComicAuthorCopyCandidate>[];
  for (var index = 0; index < ordered.length; index++) {
    final candidate = ordered[index];
    candidates.add(
      ComicAuthorCopyCandidate(
        text: candidate.text,
        kind: candidate.kind,
        recommended:
            identical(candidate, recommended) ||
            (recommended == null && index == 0),
        sourceOrder: candidate.sourceOrder,
      ),
    );
  }
  return ComicAuthorCopyResolution(List.unmodifiable(candidates));
}

class _GeneratedAuthorCandidate {
  const _GeneratedAuthorCandidate({
    required this.text,
    required this.kind,
    required this.sourceOrder,
  });

  final String text;
  final ComicAuthorCandidateKind kind;
  final int sourceOrder;
}

class _BracketSpan {
  const _BracketSpan(this.start, this.end);

  final int start;
  final int end;
}

class _OpenBracket {
  const _OpenBracket(this.index, this.character);

  final int index;
  final String character;
}

class _ScannedAuthorText {
  const _ScannedAuthorText(this.characters, this.blocks, this.malformed);

  final List<String> characters;
  final List<_BracketSpan> blocks;
  final bool malformed;
}

const _openingBrackets = <String, String>{
  '(': ')',
  '（': '）',
  '[': ']',
  '【': '】',
  '{': '}',
};

const _closingBrackets = <String, String>{
  ')': '(',
  '）': '（',
  ']': '[',
  '】': '【',
  '}': '{',
};

int _candidatePriority(ComicAuthorCandidateKind kind) {
  return switch (kind) {
    ComicAuthorCandidateKind.bracketInner => 0,
    ComicAuthorCandidateKind.outside => 1,
    ComicAuthorCandidateKind.full => 2,
  };
}

String _normalize(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _unwrapNestedBrackets(String value) {
  var characters = value.runes.map(String.fromCharCode).toList();
  while (characters.isNotEmpty) {
    final scanned = _scanCharacters(characters);
    if (scanned.malformed || scanned.blocks.length != 1) break;
    final block = scanned.blocks.single;
    var first = 0;
    while (first < characters.length && _isWhitespace(characters[first])) {
      first++;
    }
    var last = characters.length - 1;
    while (last >= 0 && _isWhitespace(characters[last])) {
      last--;
    }
    if (block.start != first || block.end != last) break;
    characters = characters.sublist(block.start + 1, block.end);
  }
  return characters.join();
}

String _joinOutside(_ScannedAuthorText scanned) {
  final outside = <String>[];
  var start = 0;
  for (final block in scanned.blocks) {
    outside.addAll(scanned.characters.sublist(start, block.start));
    start = block.end + 1;
  }
  outside.addAll(scanned.characters.sublist(start));
  return outside.join();
}

String _join(List<String> characters, int start, int end) =>
    characters.sublist(start, end).join();

bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);

_ScannedAuthorText _scan(String value) {
  return _scanCharacters(value.runes.map(String.fromCharCode).toList());
}

_ScannedAuthorText _scanCharacters(List<String> characters) {
  final stack = <_OpenBracket>[];
  final blocks = <_BracketSpan>[];
  for (var index = 0; index < characters.length; index++) {
    final character = characters[index];
    if (_openingBrackets.containsKey(character)) {
      stack.add(_OpenBracket(index, character));
      continue;
    }
    final matchingOpen = _closingBrackets[character];
    if (matchingOpen == null) continue;
    if (stack.isEmpty || stack.last.character != matchingOpen) {
      return _ScannedAuthorText(characters, const [], true);
    }
    final opening = stack.removeLast();
    if (stack.isEmpty) {
      blocks.add(_BracketSpan(opening.index, index));
    }
  }
  if (stack.isNotEmpty) {
    return _ScannedAuthorText(characters, const [], true);
  }
  return _ScannedAuthorText(characters, blocks, false);
}
