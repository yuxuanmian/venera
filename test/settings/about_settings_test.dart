import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/semantic_version.dart';
import 'package:venera/utils/translations.dart';

/// Contract: 009 US4 and US5 / FR-011 to FR-014.
///
/// The About page is the only user-visible place where the application's own
/// repository, update manifest and release destination appear, and the only
/// user-visible place where the runtime version and the update result are
/// shown. All of it is asserted without touching the network: the manifest
/// reader is an injectable seam.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String? previousVersion;
  late String? previousBuildNumber;
  late PackageInfoReader previousReader;
  late UpdateManifestReader previousManifestReader;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera-about-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    await LocalManager().init();
    previousVersion = App.packageVersion;
    previousBuildNumber = App.packageBuildNumber;
    previousReader = App.packageInfoReaderSeam;
    previousManifestReader = updateManifestReader;
  });

  tearDown(() {
    App.packageVersion = previousVersion;
    App.packageBuildNumber = previousBuildNumber;
    App.packageInfoReaderSeam = previousReader;
    updateManifestReader = previousManifestReader;
    try {
      tempDir.deleteSync(recursive: true);
    } on PathAccessException {
      // Windows may hold a handle briefly.
    }
  });

  /// Pins the runtime version to `version` (or to the unknown state when it is
  /// not a valid semantic version).
  Future<void> setRuntimeVersion(String version, {String build = '168'}) async {
    App.packageInfoReaderSeam = () async => PackageInfo(
      appName: 'Venera',
      packageName: 'com.example.venera',
      version: version,
      buildNumber: build,
    );
    await App.readPackageVersion();
  }

  Future<void> pumpAbout(WidgetTester tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
            // Index 5 is the About page in the settings list.
            builder: (_) => const SettingsPage(initialPage: 5),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('application destinations', () {
    test('every application-own URL points at the fork', () {
      // The About links and the update check share these constants, so the
      // destination cannot drift between the tile and the check.
      expect(appGithubUrl, 'https://github.com/yuxuanmian/venera');
      expect(appReleaseUrl, 'https://github.com/yuxuanmian/venera/releases');
      expect(
        autoUpdateManifestUrl,
        'https://cdn.jsdelivr.net/gh/yuxuanmian/venera@master/pubspec.yaml',
      );
    });

    test(
      'the About source no longer mentions Telegram or the upstream app',
      () {
        final source = File('lib/pages/settings/about.dart').readAsStringSync();
        expect(source, isNot(contains('t.me')));
        expect(source, isNot(contains('Telegram')));
        expect(source, isNot(contains('venera-app/venera')));
      },
    );

    testWidgets('the About page shows the fork Github entry and no Telegram', (
      tester,
    ) async {
      await pumpAbout(tester);

      expect(find.byType(AboutSettings), findsOneWidget);
      expect(find.text('Github'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);
    });
  });

  group('runtime version', () {
    test(
      'the package metadata supplies the semantic version and build number',
      () async {
        App.packageInfoReaderSeam = () async => PackageInfo(
          appName: 'Venera',
          packageName: 'com.example.venera',
          version: '2.0.0-beta.4+168',
          buildNumber: '168',
        );

        await App.readPackageVersion();

        // Build metadata is not part of the displayed version.
        expect(App.version, '2.0.0-beta.4');
        expect(App.packageBuildNumber, '168');
      },
    );

    test(
      'an unparsable version degrades to the explicit unknown state',
      () async {
        App.packageInfoReaderSeam = () async => PackageInfo(
          appName: 'Venera',
          packageName: 'com.example.venera',
          version: 'not-a-version',
          buildNumber: '168',
        );

        await App.readPackageVersion();

        expect(App.version, 'Unknown');
        expect(App.packageVersion, isNull);
        // No fabricated version and no leftover build number.
        expect(App.packageBuildNumber, isNull);
      },
    );

    test('an empty version degrades to the explicit unknown state', () async {
      App.packageInfoReaderSeam = () async => PackageInfo(
        appName: 'Venera',
        packageName: 'com.example.venera',
        version: '',
        buildNumber: '',
      );

      await App.readPackageVersion();

      expect(App.version, 'Unknown');
      expect(App.packageBuildNumber, isNull);
    });

    test('a throwing metadata reader does not propagate', () async {
      App.packageInfoReaderSeam = () async => throw StateError('no metadata');

      await expectLater(App.readPackageVersion(), completes);

      expect(App.version, 'Unknown');
      expect(App.packageVersion, isNull);
    });

    test('there is no second hardcoded real version in Dart', () {
      // FR-013: `pubspec.yaml` is the only real version source. A Dart constant
      // that looks like a release version is exactly the drift this forbids.
      final app = File('lib/foundation/app.dart').readAsStringSync();
      expect(
        RegExp(r'''["']\d+\.\d+\.\d+[^"']*["']''').hasMatch(app),
        isFalse,
        reason: 'lib/foundation/app.dart must not hardcode a version',
      );
    });

    testWidgets('About displays the version from package metadata', (
      tester,
    ) async {
      App.packageInfoReaderSeam = () async => PackageInfo(
        appName: 'Venera',
        packageName: 'com.example.venera',
        version: '2.0.0-beta.4+168',
        buildNumber: '168',
      );
      await App.readPackageVersion();

      await pumpAbout(tester);

      expect(find.text('V2.0.0-beta.4'), findsOneWidget);
      expect(find.textContaining('+168'), findsNothing);
    });

    testWidgets(
      'About shows the translated unknown state instead of a version',
      (tester) async {
        App.packageInfoReaderSeam = () async => throw StateError('no metadata');
        await App.readPackageVersion();
        expect(App.version, 'Unknown');

        final previousLanguage = appdata.settings['language'];
        appdata.settings['language'] = 'zh-CN';
        addTearDown(() => appdata.settings['language'] = previousLanguage);

        await pumpAbout(tester);

        // The unknown state is not a version, so the line is just the translated
        // marker: it must never look like a version (`VUnknown`).
        expect(find.text('未知'), findsOneWidget);
        expect(find.text('Unknown'), findsNothing);
        expect(find.textContaining('VUnknown'), findsNothing);
        expect(find.textContaining('2.0.0'), findsNothing);
        expect(find.textContaining('beta'), findsNothing);
        // A real version keeps the prefix.
        expect(appVersionDisplay('2.0.0-beta.4'), 'V2.0.0-beta.4');
      },
    );

    test('an unknown local version is never reported as an update', () async {
      // The check itself needs the network; what must hold offline is that the
      // unknown state can never be read as "a new version is available".
      App.packageInfoReaderSeam = () async => throw StateError('no metadata');
      await App.readPackageVersion();

      expect(App.version, 'Unknown');
      // The same comparison the update check performs, with a real remote
      // version: an unknown local version can never be the newer one.
      expect(isNewerSemanticVersion('2.0.0-beta.4+168', App.version), isFalse);
      expect(isNewerSemanticVersion(App.version, '2.0.0-beta.4+168'), isFalse);
    });
  });

  group('update check outcomes', () {
    test('a strictly newer remote version is an available update', () {
      expect(
        resolveUpdateOutcome(
          remoteVersion: '2.0.0-beta.5+1',
          localVersion: '2.0.0-beta.4',
        ),
        AppUpdateOutcome.available,
      );
      expect(
        resolveUpdateOutcome(
          remoteVersion: '2.0.0',
          localVersion: '2.0.0-beta.4',
        ),
        AppUpdateOutcome.available,
      );
    });

    test('build metadata alone is not an available update', () {
      expect(
        resolveUpdateOutcome(
          remoteVersion: '2.0.0-beta.4+169',
          localVersion: '2.0.0-beta.4',
        ),
        AppUpdateOutcome.none,
      );
    });

    test('an older or equal remote version is not an update', () {
      expect(
        resolveUpdateOutcome(
          remoteVersion: '2.0.0-beta.3',
          localVersion: '2.0.0-beta.4',
        ),
        AppUpdateOutcome.none,
      );
      expect(
        resolveUpdateOutcome(remoteVersion: '2.0.0', localVersion: '2.0.0'),
        AppUpdateOutcome.none,
      );
    });

    test('an unknown or malformed version is never an outcome of none', () {
      // FR-014: "cannot tell" is its own outcome. Reporting it as "no new
      // version" would claim the app is current without verifying anything, and
      // reporting it as an update would be a false positive.
      for (final remote in <String?>[
        null,
        '',
        'not-a-version',
        '2.0.0+@@',
        '2.0',
      ]) {
        expect(
          resolveUpdateOutcome(
            remoteVersion: remote,
            localVersion: '2.0.0-beta.4',
          ),
          AppUpdateOutcome.unknown,
          reason: 'remote "$remote" must be undecidable',
        );
      }
      for (final local in <String>['Unknown', '', 'not-a-version']) {
        expect(
          resolveUpdateOutcome(
            remoteVersion: '2.0.0-beta.5',
            localVersion: local,
          ),
          AppUpdateOutcome.unknown,
          reason: 'local "$local" must be undecidable',
        );
      }
    });

    test('checkUpdate maps the injected manifest to each outcome', () async {
      await setRuntimeVersion('2.0.0-beta.4+168');

      Future<AppUpdateOutcome> withManifest(String? manifest) async {
        updateManifestReader = () async => manifest;
        return checkUpdate();
      }

      expect(
        await withManifest('version: 2.0.0-beta.5+1\n'),
        AppUpdateOutcome.available,
      );
      expect(
        await withManifest('version: 2.0.0-beta.4+169\n'),
        AppUpdateOutcome.none,
      );
      // No version key at all.
      expect(await withManifest('name: venera\n'), AppUpdateOutcome.unknown);
      // Unparsable manifest.
      expect(
        await withManifest('version: [unclosed\n'),
        AppUpdateOutcome.unknown,
      );
      // Fetch failure.
      expect(await withManifest(null), AppUpdateOutcome.unknown);
      updateManifestReader = () async => throw StateError('offline');
      expect(await checkUpdate(), AppUpdateOutcome.unknown);
    });

    test('checkUpdate reports an unknown local version as unknown', () async {
      App.packageInfoReaderSeam = () async => throw StateError('no metadata');
      await App.readPackageVersion();
      updateManifestReader = () async => 'version: 2.0.0-beta.5+1\n';

      expect(await checkUpdate(), AppUpdateOutcome.unknown);
    });

    test('the result the Check button acts on is the outcome contract', () async {
      // The button's UI is a switch on `checkUpdate()`'s outcome, which cannot
      // be driven in a standalone widget test: the app reports through its own
      // overlay host and the global root navigator, neither of which exists
      // outside the app shell. What the UI renders per outcome is therefore
      // asserted through the outcome itself plus the message keys below, and
      // the rendered result is covered by the manual check recorded in
      // specs/009-minor-maintenance-enhancements/tasks.md (T038).
      await setRuntimeVersion('2.0.0-beta.4+168');

      updateManifestReader = () async => 'version: 2.0.0-beta.5+1\n';
      expect(await checkUpdate(), AppUpdateOutcome.available);

      updateManifestReader = () async => 'version: 2.0.0-beta.4+169\n';
      expect(await checkUpdate(), AppUpdateOutcome.none);

      updateManifestReader = () async => 'version: 2.0.0-@@\n';
      expect(await checkUpdate(), AppUpdateOutcome.unknown);

      // Every outcome has a user-visible message, and the undecidable one is a
      // distinct, translated string rather than a reuse of "no new version".
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'zh-CN';
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      expect('No new version available'.tl, '没有新版本可用');
      expect(
        'Unable to determine the latest version'.tl,
        '无法判断最新版本',
        reason: 'the new message must have a zh_CN translation',
      );
      expect(
        'Unable to determine the latest version'.tl,
        isNot('No new version available'.tl),
      );
    });
  });
}
