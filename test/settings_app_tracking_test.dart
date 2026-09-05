import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String previousLanguage;
  late Map<String, dynamic> previousSettings;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-app-settings-');
    App.dataPath = tempDir.path;
    App.cachePath = '${tempDir.path}${Platform.pathSeparator}cache';
    LocalManager().path = '${tempDir.path}${Platform.pathSeparator}comics';
    previousLanguage = appdata.settings['language'] as String;
    previousSettings = {
      'followUpdatesEnabled': appdata.settings['followUpdatesEnabled'],
      'cloudTrackingEnabled': appdata.settings['cloudTrackingEnabled'],
      'cloudTrackingServerUrl': appdata.settings['cloudTrackingServerUrl'],
      'cloudTrackingAccessToken': appdata.settings['cloudTrackingAccessToken'],
    };
    appdata.settings['language'] = 'en-US';
    appdata.settings['followUpdatesEnabled'] = false;
    appdata.settings['cloudTrackingEnabled'] = false;
    appdata.settings['cloudTrackingServerUrl'] = '';
    appdata.settings['cloudTrackingAccessToken'] = '';
  });

  tearDown(() => App.disposeTracking());

  tearDownAll(() async {
    appdata.settings['language'] = previousLanguage;
    for (final entry in previousSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    App.disposeTracking();
    CacheManager.instance?.dispose();
    CacheManager.instance = null;
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    Size size, {
    ThemeMode themeMode = ThemeMode.light,
    Key? settingsKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: themeMode,
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: Material(child: AppSettings(key: settingsKey)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders tracking diagnostics in a mobile-width layout', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(390, 844));
    await tester.scrollUntilVisible(
      find.text('Tracking Artifact Status'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Cloud Tracking'), findsWidgets);
    expect(find.text('Tracking Artifact Status'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders tracking diagnostics in a desktop-width layout', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 900));
    await tester.scrollUntilVisible(
      find.text('Tracking Artifact Status'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Cloud Tracking'), findsWidgets);
    expect(find.text('Tracking Artifact Status'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'renders Cloud, Local-only, blocked, unloaded, and master-off states',
    (tester) async {
      final previousFollow = appdata.settings['followUpdatesEnabled'];
      final previousCloud = appdata.settings['cloudTrackingEnabled'];
      addTearDown(() {
        appdata.settings['followUpdatesEnabled'] = previousFollow;
        appdata.settings['cloudTrackingEnabled'] = previousCloud;
        App.disposeTracking();
      });
      final sourceDirectory = Directory(
        '${App.dataPath}${Platform.pathSeparator}comic_source',
      );
      final store = SourceRevisionStore(sourceDirectory);
      final cloudBytes = [1, 2, 3];
      final localBytes = [4, 5, 6];
      final blockedBytes = [7, 8, 9];
      final cloud = ActiveArtifact(
        sourceKey: 'status-cloud',
        fileName: 'status-cloud.js',
        revision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        relativePath:
            '.managed/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/status-cloud.js',
        origin: ArtifactOrigin.managedCatalog,
        sha256: sha256.convert(cloudBytes).toString(),
        cloudCapable: true,
      );
      final local = ActiveArtifact(
        sourceKey: 'status-local-only',
        fileName: 'status-local-only.js',
        revision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        relativePath:
            '.managed/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/status-local-only.js',
        origin: ArtifactOrigin.managedCatalog,
        sha256: sha256.convert(localBytes).toString(),
      );
      final blocked = ActiveArtifact(
        sourceKey: 'status-unloaded',
        fileName: 'status-unloaded.js',
        revision: null,
        relativePath: 'status-unloaded.js',
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(blockedBytes).toString(),
        activationBlocked: true,
      );
      final registry = ActiveArtifactRegistry(
        artifacts: [cloud, local, blocked],
      );
      sourceDirectory.createSync(recursive: true);
      store.registryFile.parent.createSync(recursive: true);
      store.registryFile.writeAsStringSync(jsonEncode(registry.toJson()));

      appdata.settings['followUpdatesEnabled'] = true;
      appdata.settings['cloudTrackingEnabled'] = true;
      appdata.settings['cloudTrackingServerUrl'] = '';
      App.disposeTracking();
      final coordinator = App.cloudTracking;
      coordinator.modes
        ..cloudEnabled = true
        ..followUpdatesEnabled = true
        ..setCapability(cloud.identity, true)
        ..setRevisionAligned(cloud.identity, true)
        ..setCapability(local.identity, false)
        ..setRevisionAligned(local.identity, true)
        ..setActivationBlocked(blocked.identity, true)
        ..pause(
          cloud.identity,
          'Cloud tracking is paused: Server authority is unavailable.',
        );
      final statuses = await tester.runAsync(() => coordinator.statuses());
      expect(statuses, hasLength(3));

      for (final fixture in const [
        (Size(390, 844), ThemeMode.light),
        (Size(1280, 900), ThemeMode.dark),
      ]) {
        await pumpSettings(tester, fixture.$1, themeMode: fixture.$2);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.scrollUntilVisible(
          find.text('Tracking Artifact Status'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.scrollUntilVisible(
          find.text('status-cloud · status-cloud.js'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('status-cloud · status-cloud.js'), findsOneWidget);
        expect(
          find.textContaining(
            'Reason: Cloud tracking is paused: Server authority is unavailable.',
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('status-local-only · status-local-only.js'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text('status-local-only · status-local-only.js'),
          findsOneWidget,
        );
        expect(find.textContaining('local'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text('status-unloaded · status-unloaded.js'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text('status-unloaded · status-unloaded.js'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Activation Blocked: Blocked'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }

      appdata.settings['followUpdatesEnabled'] = false;
      coordinator.modes.followUpdatesEnabled = false;
      coordinator.modes.clearPause(cloud.identity);
      await pumpSettings(
        tester,
        const Size(390, 844),
        settingsKey: const ValueKey('master-off'),
      );
      await tester.scrollUntilVisible(
        find.text('Tracking Artifact Status'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        find.text('status-cloud · status-cloud.js'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Reason: Follow-up scanning is disabled.'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
