// Identifies title text and recognized edge markers while keeping their
// original positions for copying selected parts.
enum ComicTitleField { title, subtitle }

class ComicTitleCopyPart {
  ComicTitleCopyPart._(
    String raw,
    this._start,
    this._end, {
    bool isMetadata = false,
    bool explicitlyTranslated = false,
  }) : _isMetadata = isMetadata,
       _explicitlyTranslated = explicitlyTranslated,
       text = raw.substring(_start, _end);

  final String text;
  final int _start;
  final int _end;
  final bool _isMetadata;
  final bool _explicitlyTranslated;
}

class ComicTitleCopyGroup {
  ComicTitleCopyGroup._(this.field, this.raw, List<ComicTitleCopyPart> parts)
    : parts = List.unmodifiable(parts);

  final ComicTitleField field;
  final String raw;
  final List<ComicTitleCopyPart> parts;

  ComicTitleCopyPart get recommendedPart {
    ComicTitleCopyPart? best;
    var bestScore = -1;
    for (final part in parts) {
      if (part._isMetadata) continue;
      final score =
          (_containsKana(part.text) ? 2 : 0) +
          (part._explicitlyTranslated ? 0 : 1);
      if (score > bestScore) {
        best = part;
        bestScore = score;
      }
    }
    return best ?? parts.first;
  }

  String compose(Set<ComicTitleCopyPart> selected) {
    if (parts.every(selected.contains)) return raw;
    final result = StringBuffer();
    int? previousIndex;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (!selected.contains(part)) continue;
      if (previousIndex != null) {
        // Keep the original separator between neighboring parts. An omitted
        // part leaves a single space between the remaining selections.
        result.write(
          index == previousIndex + 1
              ? raw.substring(parts[previousIndex]._end, part._start)
              : ' ',
        );
      }
      result.write(part.text);
      previousIndex = index;
    }
    return result.toString();
  }
}

List<ComicTitleCopyGroup> resolveComicTitleCopyGroups({
  required String title,
  String? subtitle,
  Iterable<String> knownAuthors = const [],
}) {
  final authors = knownAuthors
      .map(_authorKey)
      .where((name) => name.isNotEmpty)
      .toSet();
  final mainKey = _normalize(title);
  final subtitleKey = subtitle == null ? '' : _normalize(subtitle);

  return [
    if (mainKey.isNotEmpty) _parseGroup(title, ComicTitleField.title, authors),
    if (subtitle != null &&
        subtitleKey.isNotEmpty &&
        subtitleKey != mainKey &&
        (mainKey.isEmpty || !authors.contains(_authorKey(subtitleKey))))
      _parseGroup(subtitle, ComicTitleField.subtitle, authors),
  ];
}

ComicTitleCopyGroup _parseGroup(
  String raw,
  ComicTitleField field,
  Set<String> authors,
) {
  final scan = _scan(raw);
  if (scan == null) {
    return ComicTitleCopyGroup._(field, raw, [
      ComicTitleCopyPart._(raw, 0, raw.length),
    ]);
  }

  final parts = <ComicTitleCopyPart>[];
  var segmentStart = 0;
  for (final segmentEnd in [...scan.separators, raw.length]) {
    var start = _trimStart(raw, segmentStart, segmentEnd);
    var end = _trimEnd(raw, start, segmentEnd);
    segmentStart = segmentEnd + 1;
    if (start == end) continue;

    final leading = <ComicTitleCopyPart>[];
    final trailing = <ComicTitleCopyPart>[];
    final originalStart = start;
    final originalEnd = end;
    var translated = false;

    // Only peel consecutive, recognized edge blocks. An unknown block
    // (or a bracket inside the title) stays with the title text.
    while (start < end) {
      final blockEnd = scan.endsByStart[start];
      if (blockEnd == null) break;
      final marker = _readMarker(raw, start, blockEnd, authors);
      if (marker == null) break;
      leading.add(ComicTitleCopyPart._(raw, start, blockEnd, isMetadata: true));
      translated = translated || marker == _TitleMarker.translation;
      start = _trimStart(raw, blockEnd, end);
    }

    while (start < end) {
      final blockStart = scan.startsByEnd[end];
      if (blockStart == null || blockStart < start) break;
      final marker = _readMarker(raw, blockStart, end, authors);
      if (marker == null) break;
      trailing.add(
        ComicTitleCopyPart._(raw, blockStart, end, isMetadata: true),
      );
      translated = translated || marker == _TitleMarker.translation;
      end = _trimEnd(raw, start, blockStart);
    }

    if (start == end) {
      // Marker-only text has no identifiable title within it.
      parts.add(ComicTitleCopyPart._(raw, originalStart, originalEnd));
      continue;
    }
    parts.addAll(leading);
    parts.add(
      ComicTitleCopyPart._(
        raw,
        start,
        end,
        isMetadata: authors.contains(_authorKey(raw.substring(start, end))),
        explicitlyTranslated: translated,
      ),
    );
    parts.addAll(trailing.reversed);
  }
  if (parts.isEmpty) parts.add(ComicTitleCopyPart._(raw, 0, raw.length));
  return ComicTitleCopyGroup._(field, raw, parts);
}

enum _TitleMarker { translation, metadata }

final _translationPattern = RegExp(
  r'^(?:chinese|english|中文|中国翻译|中國翻譯|中国翻訳|英訳|汉化|漢化|翻译|翻譯|翻訳|机翻|機翻|ai翻译|ai翻譯|ai翻訳)$|(?:汉化组|漢化組|翻译组|翻譯組|翻訳組)$',
  caseSensitive: false,
);
final _shortTranslationGroupPattern = RegExp(r'(?:汉化|漢化)$');
final _editionPattern = RegExp(
  r'^(?:digital|dl版|decensored|uncensored|無修正|无修正)$',
  caseSensitive: false,
);
final _eventPattern = RegExp(r'^c\s*\d{2,3}$', caseSensitive: false);
final _whitespace = RegExp(r'\s+');

_TitleMarker? _readMarker(String raw, int start, int end, Set<String> authors) {
  final text = _normalize(raw.substring(start + 1, end - 1));
  final squareBracket = const {'[', '［', '【'}.contains(raw[start]);
  if (_translationPattern.hasMatch(text) ||
      (squareBracket && _shortTranslationGroupPattern.hasMatch(text))) {
    return _TitleMarker.translation;
  }
  if (_editionPattern.hasMatch(text) ||
      _eventPattern.hasMatch(text) ||
      authors.contains(_authorKey(text))) {
    return _TitleMarker.metadata;
  }
  return null;
}

String _normalize(String text) => text.trim().replaceAll(_whitespace, ' ');

String _authorKey(String text) => _normalize(text).toLowerCase();

bool _containsKana(String text) => text.runes.any(
  (rune) =>
      (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x31f0 && rune <= 0x31ff) ||
      (rune >= 0xff66 && rune <= 0xff9f),
);

int _trimStart(String text, int start, int end) {
  while (start < end && text[start].trim().isEmpty) {
    start++;
  }
  return start;
}

int _trimEnd(String text, int start, int end) {
  while (end > start && text[end - 1].trim().isEmpty) {
    end--;
  }
  return end;
}

const _openingBrackets = <String, String>{
  '(': ')',
  '（': '）',
  '[': ']',
  '［': '］',
  '【': '】',
  '{': '}',
};

const _closingBrackets = {')', '）', ']', '］', '】', '}'};

class _ScannedTitle {
  final endsByStart = <int, int>{};
  final startsByEnd = <int, int>{};
  final separators = <int>[];
}

_ScannedTitle? _scan(String raw) {
  final scan = _ScannedTitle();
  final stack = <({int start, String close})>[];
  for (var index = 0; index < raw.length; index++) {
    final character = raw[index];
    final close = _openingBrackets[character];
    if (close != null) {
      stack.add((start: index, close: close));
    } else if (_closingBrackets.contains(character)) {
      if (stack.isEmpty || stack.last.close != character) return null;
      final opening = stack.removeLast();
      if (stack.isEmpty) {
        scan.endsByStart[opening.start] = index + 1;
        scan.startsByEnd[index + 1] = opening.start;
      }
    } else if (stack.isEmpty && (character == '|' || character == '｜')) {
      scan.separators.add(index);
    }
  }
  return stack.isEmpty ? scan : null;
}
