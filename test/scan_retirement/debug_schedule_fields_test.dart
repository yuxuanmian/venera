import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/schedule/schedule_repository.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';
import '../scan_kernel/fakes.dart' as scan_fakes;

/// Contract D (007): the two Debug blocks show **current** values, and they
/// distinguish three different answers — a missing record, a missing field on an
/// existing record, and a storage failure (D4).
///
/// The reverse guard (every retired label is gone) lives in `debug_test.dart`;
/// this file covers the positive side and the three default/failure shapes.
const _sourceKey = 'debug-fields-source';
const _comicId = 'debug-fields-comic';

/// The value of `_infoRow(label, …)`.
///
/// A label can legitimately appear in more than one block (`Scope Status` is in
/// the Raw Scan Result block as well as the collection-scope block), so every
/// row carrying the label is considered and the expected value must be one of
/// them.
void expectRow(WidgetTester tester, String label, String value) {
  final labels = find.text(label.tl);
  expect(labels, findsWidgets, reason: 'label "$label" must be on the page');
  final seen = <String>{};
  for (final element in labels.evaluate()) {
    final row = find
        .ancestor(
          of: find.byElementPredicate(
            (candidate) => identical(candidate, element),
          ),
          matching: find.byType(Row),
        )
        .first;
    for (final widget
        in find
            .descendant(of: row, matching: find.byType(SelectableText))
            .evaluate()) {
      seen.add((widget.widget as SelectableText).data ?? '');
    }
  }
  expect(
    seen,
    contains(value),
    reason: 'the "$label" row should read "$value" (rows resolved)',
  );
}

void expectRowMatches(WidgetTester tester, String label, RegExp pattern) {
  final labels = find.text(label.tl);
  expect(labels, findsWidgets, reason: 'label "$label" must be on the page');
  final seen = <String>{};
  for (final element in labels.evaluate()) {
    final row = find
        .ancestor(
          of: find.byElementPredicate(
            (candidate) => identical(candidate, element),
          ),
          matching: find.byType(Row),
        )
        .first;
    for (final widget
        in find
            .descendant(of: row, matching: find.byType(SelectableText))
            .evaluate()) {
      seen.add((widget.widget as SelectableText).data ?? '');
    }
  }
  expect(
    seen.any(pattern.hasMatch),
    isTrue,
    reason: 'no "$label" row matched $pattern (rows resolved: $seen)',
  );
}

void expectRowIsAnExplicitDefault(WidgetTester tester, String label) {
  final labels = find.text(label.tl);
  expect(labels, findsWidgets, reason: 'label "$label" must be on the page');
  final seen = <String>{};
  for (final element in labels.evaluate()) {
    final row = find
        .ancestor(
          of: find.byElementPredicate(
            (candidate) => identical(candidate, element),
          ),
          matching: find.byType(Row),
        )
        .first;
    for (final widget
        in find
            .descendant(of: row, matching: find.byType(SelectableText))
            .evaluate()) {
      seen.add((widget.widget as SelectableText).data ?? '');
    }
  }
  expect(seen, isNotEmpty);
  for (final value in seen) {
    // D4: a default MUST NOT be a `-`, a `0` or the empty string impersonating
    // a real value, and it MUST NOT use an action verb.
    expect(value.trim(), isNot(anyOf('', '-', '0')));
    for (final verb in const [
      'Enable',
      'Disable',
      'Recheck',
      '启用',
      '停用',
      '禁用',
      '重新检查',
    ]) {
      expect(value, isNot(contains(verb)), reason: '$label reads "$value"');
    }
  }
}

class _FailingScanRepository extends scan_fakes.FakeScanResultRepository {
  @override
  Future<ScanStoredItem?> readLatestItem(
    String sourceKey,
    String comicId,
  ) async {
    throw const ScanStorageException('scan store unavailable');
  }
}

/// Returns the stored item but never the scope it points at, which is the
/// "observation row exists, its scope record does not" shape of D4.
class _ScopeLessScanRepository extends scan_fakes.FakeScanResultRepository {
  @override
  Future<ScanStoredScope?> readScopeByAttemptId(
    String sourceKey,
    ScanProducer producer,
    String scopeAttemptId,
  ) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RetirementFixture fixture;

  setUpAll(AppTranslation.init);

  setUp(() async {
    fixture = await createRetirementFixture();
    final manager = ComicSourceManager();
    manager.remove(_sourceKey);
    manager.add(
      scan_fakes.makeScanTestSource(
        _sourceKey,
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      ),
    );
  });

  tearDown(() async {
    ComicSourceManager().remove(_sourceKey);
    await fixture.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    ScheduleStateRepository? schedule,
    ScanResultRepository? scan,
  }) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: ComicDebugPage(
          // A fresh key per pump: these tests swap the injected repositories
          // between pumps, and `didUpdateWidget` only reloads when the identity
          // changes (which is the production-relevant case).
          key: UniqueKey(),
          sourceKey: _sourceKey,
          comicId: _comicId,
          scheduleRepository: schedule,
          scanRepository: scan,
          favoriteCache: fixture.cache,
        ),
        builder: (context, child) => OverlayWidget(WindowFrame(child!)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<SqliteScheduleRepository> seededSchedule({
    int? nextAtMs,
    int? activityAtMs,
    int? autoHotUntilMs,
    bool jitterApplied = false,
  }) async {
    final repository = SqliteScheduleRepository(databasePath: ':memory:');
    addTearDown(repository.close);
    await repository.ensureOpen();
    await repository.applyBatch([
      ScheduleState(
        sourceKey: _sourceKey,
        comicId: _comicId,
        nextAtMs: nextAtMs,
        activityAtMs: activityAtMs,
        autoHotUntilMs: autoHotUntilMs,
        oldScheduleJitterApplied: jitterApplied,
      ),
    ]);
    return repository;
  }

  Future<SqliteScheduleRepository> emptySchedule() async {
    final repository = SqliteScheduleRepository(databasePath: ':memory:');
    addTearDown(repository.close);
    await repository.ensureOpen();
    return repository;
  }

  Future<T> seedInto<T extends scan_fakes.FakeScanResultRepository>(
    T repository, {
    bool finish = true,
  }) async {
    addTearDown(repository.close);
    final scope = await repository.beginScope(
      sourceKey: _sourceKey,
      producer: ScanProducer.comic,
      scopeKey: _comicId,
      definitionRevision: 'rev',
    );
    await repository.saveItem(
      ScanIngestionContext(scope: scope),
      ScanItemResult.observed(
        attemptId: scanUuidV5(
          scope.scopeAttemptId,
          '$_sourceKey\u0000$_comicId',
        ),
        scopeAttemptId: scope.scopeAttemptId,
        sourceKey: _sourceKey,
        comicId: _comicId,
        producer: ScanProducer.comic,
        definitionRevision: 'rev',
        observedAt: '2026-09-10T00:00:00.000Z',
        observation: ScanObservation(
          sourceUnread: true,
          update: UpdateDescriptor(latestChapterId: 'chapter-1'),
        ),
      ),
    );
    if (finish) {
      await repository.finishScope(
        ScanIngestionContext(scope: scope),
        ScanScopeStatus.completed,
      );
    }
    return repository;
  }

  Future<scan_fakes.FakeScanResultRepository> seededScan() =>
      seedInto(scan_fakes.FakeScanResultRepository());

  testWidgets('with data, both blocks show the current stored values', (
    tester,
  ) async {
    final next = DateTime.utc(2026, 10, 1, 3);
    final anchor = DateTime.utc(2026, 9, 1, 3);
    final until = DateTime.now().toUtc().add(const Duration(hours: 6));
    await pump(
      tester,
      schedule: await seededSchedule(
        nextAtMs: next.millisecondsSinceEpoch,
        activityAtMs: anchor.millisecondsSinceEpoch,
        autoHotUntilMs: until.millisecondsSinceEpoch,
        jitterApplied: true,
      ),
      scan: await seededScan(),
    );

    expect(find.text('Schedule'.tl), findsOneWidget);
    expect(find.text('Collection Scope'.tl), findsOneWidget);

    expectRow(tester, 'Next Check Time', _stamp(next));
    expectRow(tester, 'Activity Anchor', _stamp(anchor));
    expectRow(tester, 'Auto Hot Window', 'Active'.tl);
    expectRow(tester, 'Auto Hot Until', _stamp(until));
    expectRow(tester, 'Schedule Jitter Applied', 'Yes'.tl);

    expectRow(tester, 'Scan Capability', 'comic');
    expectRow(tester, 'Scan Preferred Method', 'comic');
    expectRow(tester, 'Scope Type', 'comic');
    expectRow(tester, 'Scope Key', _comicId);
    expectRow(tester, 'Scope Status', 'completed');
    // The scope's own timestamps come from the seeding clock, so they are
    // asserted by shape rather than by an exact second.
    expectRowMatches(
      tester,
      'Scope Started',
      RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'),
    );
    expectRowMatches(
      tester,
      'Scope Finished',
      RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'),
    );
    expectRow(tester, 'Scope Failure', 'None'.tl);
    expectRow(tester, 'Scope Items', '1');
  });

  testWidgets('an expired automatic window reads as inactive, not as a value', (
    tester,
  ) async {
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    await pump(
      tester,
      schedule: await seededSchedule(
        autoHotUntilMs: past.millisecondsSinceEpoch,
      ),
      scan: await seededScan(),
    );

    expectRow(tester, 'Auto Hot Window', 'Inactive'.tl);
    // The stored deadline is still shown: it is a real value, not a default.
    expectRow(tester, 'Auto Hot Until', _stamp(past));
  });

  testWidgets('no schedule record makes block 1 an explicit default', (
    tester,
  ) async {
    await pump(
      tester,
      schedule: await seededSchedule(),
      scan: await seededScan(),
    );
    // A row exists but nothing was computed for it: still a real row, so the
    // next-check field says so rather than claiming there is no record.
    expectRow(tester, 'Next Check Time', 'Not computed yet'.tl);

    await pump(
      tester,
      schedule: await emptySchedule(),
      scan: await seededScan(),
    );
    for (final label in const [
      'Next Check Time',
      'Activity Anchor',
      'Auto Hot Window',
      'Auto Hot Until',
      'Schedule Jitter Applied',
    ]) {
      expectRow(tester, label, 'No check record'.tl);
      expectRowIsAnExplicitDefault(tester, label);
    }
    // The block is shown, not hidden (D4).
    expect(find.text('Schedule'.tl), findsOneWidget);
  });

  testWidgets('no scan record and no scope record are two different defaults', (
    tester,
  ) async {
    // No observation row at all.
    await pump(
      tester,
      schedule: await seededSchedule(nextAtMs: 1),
      scan: scan_fakes.FakeScanResultRepository(),
    );
    for (final label in const [
      'Scope Type',
      'Scope Key',
      'Scope Status',
      'Scope Started',
      'Scope Finished',
      'Scope Items',
      'Scope Failure',
    ]) {
      expectRow(tester, label, 'No scan record'.tl);
      expectRowIsAnExplicitDefault(tester, label);
    }
    expect(find.text('Collection Scope'.tl), findsOneWidget);

    // An observation row exists but its scope record does not.
    await pump(
      tester,
      schedule: await seededSchedule(nextAtMs: 1),
      scan: await seedInto(_ScopeLessScanRepository()),
    );
    for (final label in const [
      'Scope Type',
      'Scope Key',
      'Scope Status',
      'Scope Started',
      'Scope Finished',
      'Scope Items',
      'Scope Failure',
    ]) {
      expectRow(tester, label, 'No scope record'.tl);
      expectRowIsAnExplicitDefault(tester, label);
    }
  });

  testWidgets('a storage failure is reported, not rendered as a default', (
    tester,
  ) async {
    // A database path that is a directory cannot be opened, so the schedule
    // read fails for a real reason rather than by a stub returning null.
    final broken = SqliteScheduleRepository(
      databasePath: Directory.systemTemp.path,
    );
    addTearDown(broken.close);
    await pump(tester, schedule: broken, scan: await seededScan());

    expect(find.text('Schedule State Unreadable'.tl), findsOneWidget);
    expect(find.text('No check record'.tl), findsNothing);
    // The rest of the page is intact: a broken store must not blank the page.
    expect(find.text('Schedule'.tl), findsOneWidget);
    expect(find.text('Collection Scope'.tl), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pump(
      tester,
      schedule: await seededSchedule(nextAtMs: 1),
      scan: await seedInto(_FailingScanRepository()),
    );
    expect(find.text('Scan State Unreadable'.tl), findsOneWidget);
    expect(find.text('No scan record'.tl), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the historical disclaimer is gone and the action stays disabled',
    (tester) async {
      await pump(
        tester,
        schedule: await seededSchedule(nextAtMs: 1),
        scan: await seededScan(),
      );

      // D5: nothing claims to be a historical record any more, and the
      // "scanner unavailable" text is not a block title.
      expect(find.text('Displayed scan state is historical'.tl), findsNothing);
      expect(find.text('Follow-up State'.tl), findsNothing);
      expect(find.text('Not tracked by follow-up scans'.tl), findsNothing);
      expect(
        find.text(followUpdateScannerUnavailableMessage.tl),
        findsNothing,
        reason:
            'the unavailable message belongs to the action entry (D6), so it '
            'appears only after the action is used',
      );

      // D6: the entry is still there and still reports being unavailable.
      await tester.tap(find.text('Recheck Now'.tl));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text(followUpdateScannerUnavailableMessage.tl), findsWidgets);
      await tester.pump(const Duration(seconds: 3));
    },
  );
}

/// The page's own time format: local time, seconds precision.
String _stamp(DateTime utc) => utc.toLocal().toString().substring(0, 19);
