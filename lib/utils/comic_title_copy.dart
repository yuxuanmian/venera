// Pure title candidate extraction for the smart-copy action.
//
// This file deliberately has no Flutter, application, or source imports. It
// is also intentionally conservative: a bracketed phrase is only removed
// when it is unambiguous metadata, while the complete source fields remain
// available as raw candidates.

enum ComicTitleField { title, subtitle }

enum ComicTitleCandidateKind { cleaned, raw }

class ComicTitleCopyCandidate {
  const ComicTitleCopyCandidate({
    required this.text,
    required this.field,
    required this.kind,
    required this.recommended,
    required this.containsKana,
    required this.explicitlyTranslated,
    required this.isKnownAuthor,
  });

  final String text;
  final ComicTitleField field;
  final ComicTitleCandidateKind kind;
  final bool recommended;
  final bool containsKana;
  final bool explicitlyTranslated;
  final bool isKnownAuthor;

  bool get isRaw => kind == ComicTitleCandidateKind.raw;
  bool get isCleaned => kind == ComicTitleCandidateKind.cleaned;
}

class ComicTitleCopyResolution {
  const ComicTitleCopyResolution(this.candidates);

  final List<ComicTitleCopyCandidate> candidates;

  ComicTitleCopyCandidate? get recommendedOrNull {
    for (final candidate in candidates) {
      if (candidate.recommended) return candidate;
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  ComicTitleCopyCandidate get recommended => recommendedOrNull!;
}

ComicTitleCopyResolution resolveComicTitleCopyCandidates({
  required String title,
  String? subtitle,
  Iterable<String> knownAuthors = const [],
}) {
  final authors = knownAuthors
      .map(_normalizeForComparison)
      .where((author) => author.isNotEmpty)
      .toSet();
  final generated = <_GeneratedCandidate>[];
  var generation = 0;

  void addField(String value, ComicTitleField field) {
    if (value.trim().isEmpty) return;

    final raw = _GeneratedCandidate(
      text: value,
      field: field,
      kind: ComicTitleCandidateKind.raw,
      containsKana: _containsKana(value),
      explicitlyTranslated: false,
      isKnownAuthor: authors.contains(_normalizeForComparison(value)),
      segmentIndex: 1 << 20,
      generation: generation++,
    );
    generated.add(raw);

    final segments = _splitTopLevel(value);
    for (var index = 0; index < segments.length; index++) {
      final cleaned = _cleanSegment(segments[index], authors);
      if (cleaned.text.isEmpty) continue;
      generated.add(
        _GeneratedCandidate(
          text: cleaned.text,
          field: field,
          kind: ComicTitleCandidateKind.cleaned,
          containsKana: _containsKana(cleaned.text),
          explicitlyTranslated: cleaned.explicitlyTranslated,
          isKnownAuthor: authors.contains(
            _normalizeForComparison(cleaned.text),
          ),
          segmentIndex: index,
          generation: generation++,
        ),
      );
    }
  }

  addField(title, ComicTitleField.title);
  if (subtitle != null) addField(subtitle, ComicTitleField.subtitle);

  // Compare the exact text after only the approved trim/whitespace folding.
  // Do not fold case, punctuation, or simplified/traditional Chinese. When a
  // cleaned value equals a raw value, keep the cleaned one because its
  // provenance is more useful to the menu and caller.
  final deduped = <String, _GeneratedCandidate>{};
  for (final candidate in generated) {
    final key = _normalizeCleaned(candidate.text);
    final previous = deduped[key];
    if (previous == null ||
        (previous.kind == ComicTitleCandidateKind.raw &&
            candidate.kind == ComicTitleCandidateKind.cleaned)) {
      deduped[key] = candidate;
    }
  }

  final sorted = deduped.values.toList()..sort(_compareCandidates);
  final recommendedIndex = sorted.indexWhere(
    (candidate) => !candidate.isKnownAuthor,
  );
  final finalCandidates = <ComicTitleCopyCandidate>[];
  for (var index = 0; index < sorted.length; index++) {
    final candidate = sorted[index];
    finalCandidates.add(
      ComicTitleCopyCandidate(
        text: candidate.text,
        field: candidate.field,
        kind: candidate.kind,
        recommended: index == (recommendedIndex < 0 ? 0 : recommendedIndex),
        containsKana: candidate.containsKana,
        explicitlyTranslated: candidate.explicitlyTranslated,
        isKnownAuthor: candidate.isKnownAuthor,
      ),
    );
  }
  return ComicTitleCopyResolution(List.unmodifiable(finalCandidates));
}

class _GeneratedCandidate {
  const _GeneratedCandidate({
    required this.text,
    required this.field,
    required this.kind,
    required this.containsKana,
    required this.explicitlyTranslated,
    required this.isKnownAuthor,
    required this.segmentIndex,
    required this.generation,
  });

  final String text;
  final ComicTitleField field;
  final ComicTitleCandidateKind kind;
  final bool containsKana;
  final bool explicitlyTranslated;
  final bool isKnownAuthor;
  final int segmentIndex;
  final int generation;
}

class _CleanedSegment {
  const _CleanedSegment(this.text, this.explicitlyTranslated);

  final String text;
  final bool explicitlyTranslated;
}

class _BracketSpan {
  const _BracketSpan(this.start, this.end, this.open, this.close);

  final int start;
  final int end;
  final String open;
  final String close;
}

class _OpenBracket {
  const _OpenBracket(this.index, this.character);

  final int index;
  final String character;
}

class _ScannedText {
  const _ScannedText(
    this.characters,
    this.blocks,
    this.separators,
    this.malformed,
  );

  final List<String> characters;
  final List<_BracketSpan> blocks;
  final List<int> separators;
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

final _metadataPattern = RegExp(
  r'^(?:chinese|english|中文|中国翻译|中國翻譯|中国翻訳|英訳|汉化|漢化|翻译|翻譯|翻訳|机翻|機翻|ai翻译|ai翻譯|ai翻訳|汉化组|漢化組|翻译组|翻譯組|翻訳組|digital|dl版|decensored|uncensored|無修正|无修正)$',
  caseSensitive: false,
);

final _translationGroupSuffixPattern = RegExp(
  r'(?:汉化组|漢化組|翻译组|翻譯組|翻訳組)$',
  caseSensitive: false,
);

final _eventPattern = RegExp(r'^c\s*\d{2,3}$', caseSensitive: false);

String _normalizeCleaned(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _normalizeForComparison(String value) =>
    _normalizeCleaned(value).toLowerCase();

bool _containsKana(String value) {
  for (final rune in value.runes) {
    if ((rune >= 0x3040 && rune <= 0x30ff) ||
        (rune >= 0x31f0 && rune <= 0x31ff) ||
        (rune >= 0xff66 && rune <= 0xff9f)) {
      return true;
    }
  }
  return false;
}

int _compareCandidates(_GeneratedCandidate a, _GeneratedCandidate b) {
  int compareBool(bool left, bool right) {
    if (left == right) return 0;
    return left ? -1 : 1;
  }

  var result = compareBool(!a.isKnownAuthor, !b.isKnownAuthor);
  if (result != 0) return result;
  result = compareBool(
    a.kind == ComicTitleCandidateKind.cleaned,
    b.kind == ComicTitleCandidateKind.cleaned,
  );
  if (result != 0) return result;
  if (a.kind == ComicTitleCandidateKind.raw) {
    result = compareBool(
      a.field == ComicTitleField.title,
      b.field == ComicTitleField.title,
    );
    if (result != 0) return result;
    return a.generation.compareTo(b.generation);
  }
  result = compareBool(a.containsKana, b.containsKana);
  if (result != 0) return result;
  result = compareBool(!a.explicitlyTranslated, !b.explicitlyTranslated);
  if (result != 0) return result;
  result = compareBool(
    a.field == ComicTitleField.title,
    b.field == ComicTitleField.title,
  );
  if (result != 0) return result;
  result = a.segmentIndex.compareTo(b.segmentIndex);
  if (result != 0) return result;
  return a.generation.compareTo(b.generation);
}

List<String> _splitTopLevel(String value) {
  final scanned = _scan(value);
  if (scanned.malformed || scanned.separators.isEmpty) {
    return [_normalizeCleaned(value)];
  }

  final result = <String>[];
  var start = 0;
  for (final separator in scanned.separators) {
    final segment = _join(scanned.characters, start, separator);
    if (segment.trim().isNotEmpty) result.add(_normalizeCleaned(segment));
    start = separator + 1;
  }
  final last = _join(scanned.characters, start, scanned.characters.length);
  if (last.trim().isNotEmpty) result.add(_normalizeCleaned(last));
  return result.isEmpty ? [_normalizeCleaned(value)] : result;
}

_CleanedSegment _cleanSegment(String value, Set<String> knownAuthors) {
  final original = _normalizeCleaned(value);
  if (original.isEmpty) return const _CleanedSegment('', false);

  var characters = original.runes.map(String.fromCharCode).toList();
  var explicitlyTranslated = false;
  var metadataRemoved = false;

  while (true) {
    final scanned = _scan(characters.join());
    if (scanned.malformed) break;
    final end = _trimRightIndex(characters);
    final block = scanned.blocks
        .where((span) => span.end == end - 1)
        .firstOrNull;
    if (block == null) break;

    final marker = _normalizeCleaned(
      _join(scanned.characters, block.start + 1, block.end),
    );
    if (!_isMetadataMarker(marker)) break;

    if (_isTranslationMarker(marker)) explicitlyTranslated = true;
    metadataRemoved = true;
    characters = [...characters.take(block.start), ...characters.skip(end)];
    while (characters.isNotEmpty && _isWhitespace(characters.last)) {
      characters.removeLast();
    }
  }

  var removedEvent = false;
  var prefixEvidence = metadataRemoved;
  while (true) {
    final scanned = _scan(characters.join());
    if (scanned.malformed) break;
    final leading = scanned.blocks.where((span) {
      return span.start == _firstNonWhitespaceIndex(characters);
    }).firstOrNull;
    if (leading == null) break;

    final marker = _normalizeCleaned(
      _join(scanned.characters, leading.start + 1, leading.end),
    );
    final isEvent = _eventPattern.hasMatch(marker);
    final isTranslation = _isTranslationMarker(marker);
    final isKnownAuthorBlock =
        leading.open == '[' &&
        leading.close == ']' &&
        knownAuthors.contains(_normalizeForComparison(marker));
    final isGenericAsciiBlock = leading.open == '[' && leading.close == ']';
    final remove =
        isEvent ||
        isTranslation ||
        isKnownAuthorBlock ||
        (isGenericAsciiBlock && prefixEvidence);
    if (!remove) break;

    if (isEvent) {
      removedEvent = true;
      prefixEvidence = true;
    }
    if (isTranslation) explicitlyTranslated = true;
    characters = [
      ...characters.take(leading.start),
      ...characters.skip(leading.end + 1),
    ];
    while (characters.isNotEmpty && _isWhitespace(characters.first)) {
      characters.removeAt(0);
    }
  }

  // `removedEvent` is kept as an explicit condition above for readability and
  // to make the archive-name rule clear. It also prevents a future prefix
  // rule from treating an arbitrary bracket as evidence by accident.
  if (removedEvent) prefixEvidence = true;
  var result = _normalizeCleaned(characters.join());
  if (result.isEmpty) result = original;
  return _CleanedSegment(result, explicitlyTranslated);
}

bool _isTranslationMarker(String value) {
  final lower = value.toLowerCase();
  return _translationGroupSuffixPattern.hasMatch(lower) ||
      lower == 'chinese' ||
      lower == 'english' ||
      lower == '中文' ||
      lower == '中国翻译' ||
      lower == '中國翻譯' ||
      lower == '中国翻訳' ||
      lower == '英訳' ||
      lower == '汉化' ||
      lower == '漢化' ||
      lower == '翻译' ||
      lower == '翻譯' ||
      lower == '翻訳' ||
      lower == '机翻' ||
      lower == '機翻' ||
      lower == 'ai翻译' ||
      lower == 'ai翻譯' ||
      lower == 'ai翻訳' ||
      lower == '汉化组' ||
      lower == '漢化組' ||
      lower == '翻译组' ||
      lower == '翻譯組' ||
      lower == '翻訳組';
}

bool _isMetadataMarker(String value) =>
    _metadataPattern.hasMatch(value) ||
    _translationGroupSuffixPattern.hasMatch(value);

int _trimRightIndex(List<String> characters) {
  var index = characters.length;
  while (index > 0 && _isWhitespace(characters[index - 1])) {
    index--;
  }
  return index;
}

int _firstNonWhitespaceIndex(List<String> characters) {
  var index = 0;
  while (index < characters.length && _isWhitespace(characters[index])) {
    index++;
  }
  return index;
}

bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);

String _join(List<String> characters, int start, int end) =>
    characters.sublist(start, end).join();

_ScannedText _scan(String value) {
  final characters = value.runes.map(String.fromCharCode).toList();
  return _scanCharacters(characters);
}

_ScannedText _scanCharacters(List<String> characters) {
  final stack = <_OpenBracket>[];
  final blocks = <_BracketSpan>[];
  final separators = <int>[];

  for (var index = 0; index < characters.length; index++) {
    final character = characters[index];
    final expectedClose = _openingBrackets[character];
    if (expectedClose != null) {
      stack.add(_OpenBracket(index, character));
      continue;
    }
    final matchingOpen = _closingBrackets[character];
    if (matchingOpen != null) {
      if (stack.isEmpty || stack.last.character != matchingOpen) {
        return _ScannedText(characters, const [], const [], true);
      }
      final opening = stack.removeLast();
      if (stack.isEmpty) {
        blocks.add(
          _BracketSpan(opening.index, index, opening.character, character),
        );
      }
      continue;
    }
    if (stack.isEmpty && (character == '|' || character == '｜')) {
      separators.add(index);
    }
  }

  if (stack.isNotEmpty) {
    return _ScannedText(characters, const [], const [], true);
  }
  return _ScannedText(characters, blocks, separators, false);
}
