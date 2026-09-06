import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  test('user-data export excludes Catalog runtime and device-only fields', () {
    final oldRuntime = appdata.catalogRuntime;
    final oldServer = appdata.settings['serverUrl'];
    final oldEnabled = appdata.settings['enabledSources'];
    final oldToken = appdata.settings['cloudTrackingAccessToken'];
    appdata.catalogRuntime = {'active': 'device-only'};
    appdata.settings['serverUrl'] = 'https://server.example/';
    appdata.settings['enabledSources'] = ['source'];
    appdata.settings['cloudTrackingAccessToken'] = 'secret';
    addTearDown(() {
      appdata.catalogRuntime = oldRuntime;
      appdata.settings['serverUrl'] = oldServer;
      appdata.settings['enabledSources'] = oldEnabled;
      appdata.settings['cloudTrackingAccessToken'] = oldToken;
    });

    final projected = appdata.toUserDataJson();
    final settings = projected['settings'] as Map;
    expect(projected, isNot(contains('catalogRuntime')));
    expect(settings['enabledSources'], ['source']);
    expect(settings, isNot(contains('serverUrl')));
    expect(settings, isNot(contains('cloudTrackingAccessToken')));
  });
}
