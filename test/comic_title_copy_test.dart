import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_title_copy.dart';

void main() {
  test('keeps recognized tags on both ends in their source order', () {
    const title = '(C105) [某某汉化]  日本語の原名（副章） [DL版] (Digital)';
    final group = resolveComicTitleCopyGroups(title: title).single;
    expect(_texts(group), [
      '(C105)',
      '[某某汉化]',
      '日本語の原名（副章）',
      '[DL版]',
      '(Digital)',
    ]);
    expect(group.recommendedPart.text, '日本語の原名（副章）');
    expect(group.compose(group.parts.toSet()), title);
    expect(
      group.compose({group.parts[3], group.parts[2], group.parts[1]}),
      '[某某汉化]  日本語の原名（副章） [DL版]',
    );
    expect(group.compose({group.parts[4], group.parts[0]}), '(C105) (Digital)');
  });

  test(
    'keeps unknown bracket blocks attached even with recognized markers',
    () {
      final group = resolveComicTitleCopyGroups(
        title: '(C105) [重生] 纯中文标题 (作品名) [DL版]',
      ).single;
      expect(_texts(group), ['(C105)', '[重生] 纯中文标题 (作品名)', '[DL版]']);
      expect(group.recommendedPart.text, '[重生] 纯中文标题 (作品名)');
    },
  );

  test('recognizes authors and translation markers in either position', () {
    final group = resolveComicTitleCopyGroups(
      title: '（Team 翻譯組） 原名 (山田太郎)',
      knownAuthors: ['山田太郎'],
    ).single;
    expect(_texts(group), ['（Team 翻譯組）', '原名', '(山田太郎)']);

    final prefix = resolveComicTitleCopyGroups(
      title: '[山田太郎] 純中文標題',
      knownAuthors: ['山田太郎'],
    ).single;
    expect(_texts(prefix), ['[山田太郎]', '純中文標題']);
  });

  test('preserves unknown and malformed brackets verbatim', () {
    for (final title in [
      '  标题 | [作者 原名  ',
      '标题 (系列|版本)',
      '种马（救世主）として召喚された異世界',
      '标题【特别篇】后续',
      '纯中文标题（完结）',
      '【重生】纯中文标题',
      '[重生] 纯中文标题',
      '[Team 翻译] 原名',
      '[某某汉化小组] 原名',
      '[异世界汉化计划] 纯中文标题',
    ]) {
      final group = resolveComicTitleCopyGroups(title: title).single;
      expect(_texts(group), [title], reason: title);
      expect(group.compose(group.parts.toSet()), title);
    }
  });

  test('splits only top-level pipes and preserves emoji and spacing', () {
    const title = '[A|B] 标题🌙 ｜ 中文译名（翻译）';
    final group = resolveComicTitleCopyGroups(title: title).single;
    expect(_texts(group), ['[A|B] 标题🌙', '中文译名', '（翻译）']);
    expect(group.recommendedPart.text, '[A|B] 标题🌙');
    expect(
      group.compose({group.parts[0], group.parts[1]}),
      '[A|B] 标题🌙 ｜ 中文译名',
    );
  });

  test('handles empty pipe fragments and metadata-only titles', () {
    final split = resolveComicTitleCopyGroups(title: 'A || B').single;
    expect(_texts(split), ['A', 'B']);
    expect(split.compose(split.parts.toSet()), 'A || B');

    for (final title in [' A | ', ' | ', '[汉化] (Digital)']) {
      final group = resolveComicTitleCopyGroups(title: title).single;
      expect(group.parts, hasLength(1));
      expect(group.raw, title);
    }
  });

  test('ranks title parts using kana and explicit translation markers', () {
    final group = resolveComicTitleCopyGroups(
      title: '中文译名 [中文] | 日本語の原名',
    ).single;
    expect(group.recommendedPart.text, '日本語の原名');

    final chinese = resolveComicTitleCopyGroups(title: '纯中文甲 | 纯中文乙').single;
    expect(chinese.recommendedPart.text, '纯中文甲');

    final translated = resolveComicTitleCopyGroups(title: '纯中文标题（翻译）').single;
    expect(translated.recommendedPart.text, '纯中文标题');
  });

  test('keeps distinct main titles and subtitles in separate groups', () {
    final groups = resolveComicTitleCopyGroups(
      title: 'English Parent [Digital]',
      subtitle: '[山田太郎] 日本語の原名 [中国翻訳]',
      knownAuthors: ['山田太郎'],
    );
    expect(groups.map((group) => group.field), ComicTitleField.values);
    expect(_texts(groups[0]), ['English Parent', '[Digital]']);
    expect(_texts(groups[1]), ['[山田太郎]', '日本語の原名', '[中国翻訳]']);
    expect(groups[1].compose(groups[0].parts.toSet()), '');
  });

  test('omits identical subtitles and subtitles known to be author labels', () {
    final duplicate = resolveComicTitleCopyGroups(
      title: ' 同名 ',
      subtitle: '同名',
    ).single;
    expect(duplicate.field, ComicTitleField.title);
    expect(duplicate.raw, ' 同名 ');

    final withAuthor = resolveComicTitleCopyGroups(
      title: '纯中文标题',
      subtitle: '山田太郎',
      knownAuthors: [' 山田太郎 '],
    ).single;
    expect(withAuthor.raw, '纯中文标题');

    final subtitleOnly = resolveComicTitleCopyGroups(
      title: '',
      subtitle: '日本語',
    ).single;
    expect(subtitleOnly.field, ComicTitleField.subtitle);
    expect(subtitleOnly.raw, '日本語');
    expect(resolveComicTitleCopyGroups(title: '  '), isEmpty);
  });

  test('keeps a long unsplit title intact', () {
    final title = List.filled(5000, '原').join();
    final group = resolveComicTitleCopyGroups(title: title).single;
    expect(_texts(group), [title]);
  });
}

List<String> _texts(ComicTitleCopyGroup group) =>
    group.parts.map((part) => part.text).toList();
