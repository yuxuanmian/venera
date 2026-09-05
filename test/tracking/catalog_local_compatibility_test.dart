import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

void main() {
  test('ordinary FavoriteData remains valid without updateCheck', () {
    const data = FavoriteData(
      key: 'ordinary-source',
      title: 'Ordinary source',
      multiFolder: false,
      loadComic: null,
      loadNext: null,
    );
    expect(data.updateCheck, isNull);
    expect(data.key, 'ordinary-source');
  });

  test(
    'FavoriteUpdateCheckData keeps scan interval independent of legacy scheme',
    () {
      final data = FavoriteUpdateCheckData(
        scanInterval: const Duration(hours: 1),
        load: ([_]) async => const Res.error('unused'),
      );
      expect(data.scanInterval, const Duration(hours: 1));
      expect(data.markerScheme, isNull);
    },
  );
}
