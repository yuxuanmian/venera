import 'dart:convert';

/// No-execution identity discovery for legacy JavaScript source files.
///
/// Cloud admission cannot use [ComicSourceParser] for migration: parsing a
/// source executes its top-level code and constructs the source object.  This
/// lexer therefore accepts only a literal `key` class field on a class that
/// directly extends `ComicSource`.  Comments, strings, nested objects, and
/// expressions are never evaluated.
class LegacySourceIdentity {
  const LegacySourceIdentity({required this.sourceKey});

  final String sourceKey;

  factory LegacySourceIdentity.fromSource(String source) {
    final tokens = _LegacyLexer(source).scan();
    final classes = <_TokenRange>[];
    for (var index = 0; index < tokens.length; index++) {
      if (tokens[index].kind != _TokenKind.identifier ||
          tokens[index].value != 'class') {
        continue;
      }
      final classBody = _findComicSourceClassBody(tokens, index);
      if (classBody != null) classes.add(classBody);
    }
    if (classes.isEmpty) {
      throw const FormatException(
        'ComicSource class with literal key not found',
      );
    }
    if (classes.length != 1) {
      throw const FormatException('multiple ComicSource classes are ambiguous');
    }

    final classBody = classes.single;
    final values = <String>[];
    var depth = 0;
    var parenDepth = 0;
    var bracketDepth = 0;
    for (var cursor = classBody.start + 1; cursor < classBody.end; cursor++) {
      final token = tokens[cursor];
      if (token.isPunctuation('{')) {
        depth++;
        continue;
      }
      if (token.isPunctuation('}')) {
        depth--;
        continue;
      }
      if (token.isPunctuation('(')) {
        parenDepth++;
        continue;
      }
      if (token.isPunctuation(')')) {
        parenDepth--;
        continue;
      }
      if (token.isPunctuation('[')) {
        bracketDepth++;
        continue;
      }
      if (token.isPunctuation(']')) {
        bracketDepth--;
        continue;
      }
      if (depth != 0 ||
          parenDepth != 0 ||
          bracketDepth != 0 ||
          token.kind != _TokenKind.identifier ||
          token.value != 'key') {
        continue;
      }
      final next = cursor + 1 < classBody.end ? tokens[cursor + 1] : null;
      if (next == null || !next.isPunctuation('=')) {
        throw const FormatException('legacy source key is not a literal');
      }
      final literal = cursor + 2 < classBody.end ? tokens[cursor + 2] : null;
      if (literal == null || literal.kind != _TokenKind.string) {
        throw const FormatException('legacy source key is not a literal');
      }
      final afterLiteral = cursor + 3 < classBody.end
          ? tokens[cursor + 3]
          : null;
      if (afterLiteral != null &&
          !afterLiteral.isPunctuation(';') &&
          !(afterLiteral.precededByNewline &&
              afterLiteral.kind == _TokenKind.identifier &&
              afterLiteral.value != 'in' &&
              afterLiteral.value != 'instanceof')) {
        throw const FormatException('legacy source key is not a literal');
      }
      if (literal.value.trim().isEmpty) {
        throw const FormatException('legacy source key is empty');
      }
      values.add(literal.value.trim());
      cursor += 2;
    }
    if (values.length != 1) {
      throw const FormatException('legacy source key is missing or ambiguous');
    }
    final key = values.single;
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key)) {
      throw const FormatException('legacy source key is invalid');
    }
    return LegacySourceIdentity(sourceKey: key);
  }

  factory LegacySourceIdentity.fromBytes(List<int> bytes) =>
      LegacySourceIdentity.fromSource(_decodeUtf8(bytes));
}

String _decodeUtf8(List<int> bytes) {
  // Keep this file independent of the runtime parser while still rejecting
  // malformed source bytes before identity discovery.
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const FormatException('legacy source is not valid UTF-8');
  }
}

_TokenRange? _findComicSourceClassBody(
  List<_LegacyToken> tokens,
  int classIndex,
) {
  var cursor = classIndex + 1;
  if (cursor >= tokens.length || tokens[cursor].kind != _TokenKind.identifier) {
    return null;
  }
  cursor++;
  if (cursor >= tokens.length ||
      tokens[cursor].kind != _TokenKind.identifier ||
      tokens[cursor].value != 'extends') {
    return null;
  }
  cursor++;
  if (cursor >= tokens.length ||
      tokens[cursor].kind != _TokenKind.identifier ||
      tokens[cursor].value != 'ComicSource') {
    return null;
  }
  cursor++;
  if (cursor >= tokens.length || !tokens[cursor].isPunctuation('{')) {
    return null;
  }
  final start = cursor;
  var depth = 0;
  for (; cursor < tokens.length; cursor++) {
    if (tokens[cursor].isPunctuation('{')) depth++;
    if (tokens[cursor].isPunctuation('}')) {
      depth--;
      if (depth == 0) return _TokenRange(start, cursor);
    }
  }
  throw const FormatException('legacy source class body is incomplete');
}

enum _TokenKind { identifier, string, template, punctuation }

class _LegacyToken {
  const _LegacyToken(this.kind, this.value, {this.precededByNewline = false});

  final _TokenKind kind;
  final String value;
  final bool precededByNewline;

  bool isPunctuation(String text) =>
      kind == _TokenKind.punctuation && value == text;
}

class _TokenRange {
  const _TokenRange(this.start, this.end);

  final int start;
  final int end;
}

class _LegacyLexer {
  _LegacyLexer(this.source);

  final String source;

  List<_LegacyToken> scan() {
    final result = <_LegacyToken>[];
    var index = 0;
    var precededByNewline = false;
    while (index < source.length) {
      final code = source.codeUnitAt(index);
      if (_isWhitespace(code)) {
        if (code == 0x0a || code == 0x0d) precededByNewline = true;
        index++;
        continue;
      }
      if (code == 0x2f && index + 1 < source.length) {
        final next = source.codeUnitAt(index + 1);
        if (next == 0x2f) {
          index += 2;
          while (index < source.length && source.codeUnitAt(index) != 0x0a) {
            index++;
          }
          precededByNewline = true;
          continue;
        }
        if (next == 0x2a) {
          index += 2;
          var closed = false;
          while (index + 1 < source.length) {
            if (source.codeUnitAt(index) == 0x2a &&
                source.codeUnitAt(index + 1) == 0x2f) {
              index += 2;
              closed = true;
              break;
            }
            index++;
          }
          if (!closed) {
            throw const FormatException('legacy source comment is incomplete');
          }
          precededByNewline =
              precededByNewline ||
              source.substring(index - 2, index).contains('\n');
          continue;
        }
      }
      if (code == 0x22 || code == 0x27 || code == 0x60) {
        final quote = code;
        final value = StringBuffer();
        var literalSafe = true;
        index++;
        var closed = false;
        while (index < source.length) {
          final current = source.codeUnitAt(index);
          if (current == quote) {
            index++;
            closed = true;
            break;
          }
          if (quote == 0x60 &&
              current == 0x24 &&
              index + 1 < source.length &&
              source.codeUnitAt(index + 1) == 0x7b) {
            index = _skipTemplateExpression(index + 2);
            continue;
          }
          if (current == 0x5c) {
            if (index + 1 >= source.length) break;
            final escaped = source.codeUnitAt(index + 1);
            if (escaped == 0x78 ||
                escaped == 0x75 ||
                escaped == 0x0a ||
                escaped == 0x0d ||
                escaped >= 0x30 && escaped <= 0x39) {
              literalSafe = false;
            }
            value.write(_decodeEscape(escaped));
            index += 2;
            continue;
          }
          value.writeCharCode(current);
          index++;
        }
        if (!closed) {
          throw const FormatException('legacy source string is incomplete');
        }
        result.add(
          _LegacyToken(
            quote == 0x60 || !literalSafe
                ? _TokenKind.template
                : _TokenKind.string,
            value.toString(),
            precededByNewline: precededByNewline,
          ),
        );
        precededByNewline = false;
        continue;
      }
      if (code == 0x2f && _startsRegex(result)) {
        index = _skipRegex(index);
        result.add(
          _LegacyToken(
            _TokenKind.punctuation,
            '/regex/',
            precededByNewline: precededByNewline,
          ),
        );
        precededByNewline = false;
        continue;
      }
      if (_isIdentifierStart(code)) {
        final start = index++;
        while (index < source.length &&
            _isIdentifierPart(source.codeUnitAt(index))) {
          index++;
        }
        result.add(
          _LegacyToken(
            _TokenKind.identifier,
            source.substring(start, index),
            precededByNewline: precededByNewline,
          ),
        );
        precededByNewline = false;
        continue;
      }
      result.add(
        _LegacyToken(
          _TokenKind.punctuation,
          String.fromCharCode(code),
          precededByNewline: precededByNewline,
        ),
      );
      precededByNewline = false;
      index++;
    }
    return result;
  }

  String _decodeEscape(int code) {
    return switch (code) {
      0x6e => '\n',
      0x72 => '\r',
      0x74 => '\t',
      0x62 => '\b',
      0x66 => '\f',
      0x76 => '\v',
      _ => String.fromCharCode(code),
    };
  }

  // Interpolation is irrelevant to a literal class key. Skip only syntax we
  // can delimit without evaluation; ambiguous nested templates fail closed.
  int _skipTemplateExpression(int index) {
    var depth = 1;
    while (index < source.length) {
      final code = source.codeUnitAt(index++);
      if (code == 0x60 || code == 0x2f) {
        throw const FormatException('unsupported legacy template expression');
      }
      if (code == 0x22 || code == 0x27) {
        var closed = false;
        while (index < source.length) {
          final char = source.codeUnitAt(index++);
          if (char == 0x5c) {
            index++;
            continue;
          }
          if (char == code) {
            closed = true;
            break;
          }
        }
        if (!closed) break;
      } else if (code == 0x7b) {
        depth++;
      } else if (code == 0x7d && --depth == 0) {
        return index;
      }
    }
    throw const FormatException('legacy template expression is incomplete');
  }

  bool _startsRegex(List<_LegacyToken> tokens) {
    if (tokens.isEmpty) return true;
    final previous = tokens.last.value;
    return previous == '=' ||
        previous == ':' ||
        previous == ',' ||
        previous == '(' ||
        previous == '[' ||
        previous == '{' ||
        previous == ';' ||
        previous == '!' ||
        previous == '?' ||
        previous == 'return' ||
        previous == 'case';
  }

  int _skipRegex(int start) {
    var index = start + 1;
    var inClass = false;
    while (index < source.length) {
      final code = source.codeUnitAt(index);
      if (code == 0x5c) {
        index += 2;
        continue;
      }
      if (code == 0x5b) inClass = true;
      if (code == 0x5d) inClass = false;
      if (code == 0x2f && !inClass) {
        index++;
        while (index < source.length &&
            _isIdentifierPart(source.codeUnitAt(index))) {
          index++;
        }
        return index;
      }
      if (code == 0x0a || code == 0x0d) break;
      index++;
    }
    return start + 1;
  }
}

bool _isWhitespace(int code) =>
    code == 0x09 || code == 0x0a || code == 0x0d || code == 0x20;

bool _isIdentifierStart(int code) =>
    code == 0x24 ||
    code == 0x5f ||
    code >= 0x41 && code <= 0x5a ||
    code >= 0x61 && code <= 0x7a;

bool _isIdentifierPart(int code) =>
    _isIdentifierStart(code) || code >= 0x30 && code <= 0x39;
