import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_author_copy.dart';

void main() {
  ComicAuthorCopyResolution resolve(String value) {
    return resolveComicAuthorCopyCandidates(value);
  }

  List<String> texts(String value) =>
      resolve(value).candidates.map((candidate) => candidate.text).toList();

  test('plain author names remain one complete candidate', () {
    expect(texts('作者名'), ['作者名']);
    expect(texts('作者かな'), ['作者かな']);
    expect(texts('Author Name'), ['Author Name']);
    expect(resolve('作者名').hasAlternatives, isFalse);
  });

  test('supports ASCII and full-width bracket pairs', () {
    expect(texts('Circle (Author)'), ['Author', 'Circle', 'Circle (Author)']);
    expect(texts('社团（作者）'), ['作者', '社团', '社团（作者）']);
    expect(texts('[Circle] (Author)'), [
      'Author',
      'Circle',
      '[Circle] (Author)',
    ]);
    expect(texts('【社团】【作者】'), ['作者', '社团', '【社团】【作者】']);
    expect(texts('{Circle}{Author}'), ['Author', 'Circle', '{Circle}{Author}']);
  });

  test('unwraps nested bracket envelopes safely', () {
    expect(texts('{社团}（{作者}）'), ['作者', '社团', '{社团}（{作者}）']);
    expect(texts('（（作者））'), ['作者', '（（作者））']);
  });

  test('uses neutral candidates and stable source order', () {
    final result = resolve('作者名（别名）');
    expect(texts('作者名（别名）'), ['别名', '作者名', '作者名（别名）']);
    expect(result.candidates[0].kind, ComicAuthorCandidateKind.bracketInner);
    expect(result.candidates[1].kind, ComicAuthorCandidateKind.outside);
    expect(result.candidates[0].recommended, isTrue);
    expect(result.candidates[1].recommended, isFalse);
  });

  test('merges outside text and folds only whitespace', () {
    expect(texts('  社团  （作者）  '), ['作者', '社团', '  社团  （作者）  ']);
    expect(texts('社团（）（作者）'), ['作者', '社团', '社团（）（作者）']);
  });

  test('malformed bracket structures fall back to the full original', () {
    for (final value in ['作者名（未闭合', '作者名)', '作者（别名]', '作者{别名）']) {
      final result = resolve(value);
      expect(texts(value), [value]);
      expect(result.hasAlternatives, isFalse);
    }
  });

  test('does not split joint credits or unsupported punctuation', () {
    expect(texts('作者A & 作者B'), ['作者A & 作者B']);
    expect(texts('作者A × 作者B'), ['作者A × 作者B']);
    expect(texts('作者A / 作者B'), ['作者A / 作者B']);
    expect(texts('《作者（别名）》'), ['别名', '《作者》', '《作者（别名）》']);
  });

  test('deduplicates candidates and keeps complete text last', () {
    final result = resolve('作者（作者）');
    expect(texts('作者（作者）'), ['作者', '作者（作者）']);
    expect(result.candidates.last.kind, ComicAuthorCandidateKind.full);
    expect(result.candidates.last.recommended, isFalse);
  });

  test('keeps pure CJK text and handles long input linearly', () {
    expect(texts('纯中文作者信息'), ['纯中文作者信息']);
    final value = '社团（作者）' * 500;
    final result = resolve(value);
    expect(result.candidates, isNotEmpty);
    expect(result.candidates.last.kind, ComicAuthorCandidateKind.full);
  });

  test('empty input is safe', () {
    expect(resolve('').candidates, isEmpty);
    expect(resolve('   ').candidates, isEmpty);
  });
}
