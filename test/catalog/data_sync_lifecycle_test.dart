import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  test(
    'WebDAV has no automatic work before Catalog Runtime is ready',
    () async {
      final oldWebdav = appdata.settings['webdav'];
      final oldAuto = appdata.implicitData['webdavAutoSync'];
      appdata.settings['webdav'] = [
        'https://webdav.example/',
        'user',
        'password',
      ];
      appdata.implicitData['webdavAutoSync'] = true;
      DataSync.resetForTesting();
      addTearDown(() {
        appdata.settings['webdav'] = oldWebdav;
        if (oldAuto == null) {
          appdata.implicitData.remove('webdavAutoSync');
        } else {
          appdata.implicitData['webdavAutoSync'] = oldAuto;
        }
        DataSync.resetForTesting();
      });

      final result = await DataSync().uploadData();
      expect(result.success, isTrue);
      expect(DataSync().isUploading, isFalse);
    },
  );
}
