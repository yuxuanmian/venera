import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_title_copy.dart';

void main() {
  test('removes only known metadata and keeps raw title', () {
    final result = resolveComicTitleCopyCandidates(
      title: '[作者] 原名 [中国翻訳] [DL版]',
    );

    expect(result.recommended.text, '原名');
    expect(result.recommended.kind, ComicTitleCandidateKind.cleaned);
    expect(
      result.candidates.any((e) => e.text == '[作者] 原名 [中国翻訳] [DL版]' && e.isRaw),
      isTrue,
    );
  });

  test('recognizes explicit translation-group suffixes', () {
    final simplified = resolveComicTitleCopyCandidates(title: '[某某汉化组] 原名');
    final traditional = resolveComicTitleCopyCandidates(title: '原名 [Team 翻譯組]');

    expect(simplified.recommended.text, '原名');
    expect(traditional.recommended.text, '原名');
    expect(
      traditional.candidates
          .where((candidate) => candidate.text == '原名')
          .single
          .explicitlyTranslated,
      isTrue,
    );
  });

  test('does not remove unknown bracket markers that resemble metadata', () {
    for (final title in ['[某某汉化] 原名', '[Team 翻译] 原名', '[某某汉化小组] 原名']) {
      final result = resolveComicTitleCopyCandidates(title: title);
      expect(result.recommended.text, _normalized(title), reason: title);
    }
  });

  test(
    'protects internal parentheses while removing prefix and tail metadata',
    () {
      final result = resolveComicTitleCopyCandidates(
        title: '(C105) [作者] 原名 (作品名) [Chinese] [Digital]',
      );

      expect(result.recommended.text, '原名 (作品名)');
    },
  );

  test('preserves unknown and malformed brackets conservatively', () {
    for (final title in [
      '种马（救世主）として召喚された異世界',
      '标题【特别篇】后续',
      '纯中文标题（完结）',
      '[作者 原名',
      '【重生】纯中文标题',
      '[重生] 纯中文标题',
    ]) {
      final result = resolveComicTitleCopyCandidates(title: title);
      expect(result.recommended.text, _normalized(title), reason: title);
    }
  });

  test('splits only top-level pipes', () {
    final result = resolveComicTitleCopyCandidates(
      title: '[A|B] 标题 | 中文译名（翻译）',
    );

    expect(result.candidates.where((e) => e.isCleaned).map((e) => e.text), [
      '[A|B] 标题',
      '中文译名',
    ]);
    expect(result.recommended.text, '[A|B] 标题');
  });

  test('keeps nested pipes and drops empty top-level fragments', () {
    final nested = resolveComicTitleCopyCandidates(title: '标题 (系列|版本)');
    expect(nested.candidates.where((e) => e.isCleaned).map((e) => e.text), [
      '标题 (系列|版本)',
    ]);

    final fragments = resolveComicTitleCopyCandidates(title: 'A || B');
    expect(fragments.candidates.where((e) => e.isCleaned).map((e) => e.text), [
      'A',
      'B',
    ]);
  });

  test('marks a translated right-hand segment without losing the left one', () {
    final result = resolveComicTitleCopyCandidates(title: '原名｜中文译名（翻译）');

    expect(result.recommended.text, '原名');
    final translated = result.candidates.singleWhere((e) => e.text == '中文译名');
    expect(translated.explicitlyTranslated, isTrue);
  });

  test('does not penalize pure Chinese titles and keeps all segments', () {
    final result = resolveComicTitleCopyCandidates(title: '纯中文甲 | 纯中文乙');

    expect(result.recommended.text, '纯中文甲');
    expect(result.candidates.where((e) => e.isCleaned).map((e) => e.text), [
      '纯中文甲',
      '纯中文乙',
    ]);
  });

  test('prefers a Japanese subtitle over an English parent title', () {
    final result = resolveComicTitleCopyCandidates(
      title: 'English Parent',
      subtitle: '[作者] 日本語の原名 [中国翻訳]',
    );

    expect(result.recommended.text, '日本語の原名');
    expect(result.candidates.any((e) => e.text == 'English Parent'), isTrue);
  });

  test('known author subtitle is not recommended', () {
    final result = resolveComicTitleCopyCandidates(
      title: '纯中文标题',
      subtitle: '山田太郎',
      knownAuthors: ['山田太郎'],
    );

    expect(result.recommended.text, '纯中文标题');
    expect(
      result.candidates
          .where((e) => e.text == '山田太郎')
          .every((e) => e.isKnownAuthor),
      isTrue,
    );
  });

  test(
    'removes a known author prefix but preserves unknown bracket prefixes',
    () {
      final known = resolveComicTitleCopyCandidates(
        title: '[山田太郎] 日本語タイトル',
        knownAuthors: ['山田太郎'],
      );
      expect(known.recommended.text, '日本語タイトル');

      final unknown = resolveComicTitleCopyCandidates(title: '[重生] 纯中文标题');
      expect(unknown.recommended.text, '[重生] 纯中文标题');
    },
  );

  test('keeps the body when a pure Chinese title has a translation marker', () {
    final result = resolveComicTitleCopyCandidates(title: '纯中文标题（翻译）');

    expect(result.recommended.text, '纯中文标题');
    expect(result.recommended.explicitlyTranslated, isTrue);
  });

  test('deduplicates equal title and subtitle values and handles fallback', () {
    final duplicate = resolveComicTitleCopyCandidates(
      title: '同名',
      subtitle: '同名',
    );
    expect(duplicate.candidates.where((e) => e.text == '同名'), hasLength(1));
    expect(duplicate.recommended.field, ComicTitleField.title);

    final fallback = resolveComicTitleCopyCandidates(
      title: '',
      subtitle: '日本語',
    );
    expect(fallback.recommended.text, '日本語');
  });

  test('is stable and bounded for a long input', () {
    final title = List.filled(5000, '原').join();
    final first = resolveComicTitleCopyCandidates(title: title);
    final second = resolveComicTitleCopyCandidates(title: title);

    expect(
      first.candidates.map((e) => e.text),
      second.candidates.map((e) => e.text),
    );
    expect(first.recommended.text, title);
  });
}

String _normalized(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');
