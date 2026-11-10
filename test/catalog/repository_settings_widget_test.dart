import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _FakeRepositoryController extends CatalogController {
  _FakeRepositoryController({
    required this.savedSource,
    required this.runtimePointer,
    this.updateAvailable = false,
    this.localFallback = false,
    this.fallbackReason,
    required CatalogRepositoryVerification verification,
    required CatalogRepositoryCheck check,
  }) : _verification = verification,
       _check = check,
       super(
         store: CatalogStore(Directory.systemTemp),
         appdata: Appdata.createForTesting(() async => Directory.systemTemp),
         preferences: SourcePreferences(initial: const []),
       );

  CatalogRepositorySource savedSource;
  @override
  final CatalogPointer? runtimePointer;
  final bool updateAvailable;
  final bool localFallback;
  final CatalogLocalFallbackReason? fallbackReason;
  final CatalogRepositoryVerification _verification;
  final CatalogRepositoryCheck _check;
  int verifyCalls = 0;
  int checkCalls = 0;
  CatalogRepositorySource? checkedSource;

  @override
  CatalogRepositorySource get repositorySource => savedSource;

  @override
  bool get hasRepositoryUpdate => updateAvailable;

  @override
  bool get usingLocalFallback => localFallback;

  @override
  CatalogLocalFallbackReason? get localFallbackReason => fallbackReason;

  @override
  Future<CatalogRepositoryVerification> verifyAndSaveRepositorySource(
    CatalogRepositorySource source,
  ) async {
    verifyCalls++;
    final result = _verification;
    if (result.succeeded) savedSource = source;
    return result;
  }

  @override
  Future<CatalogRepositoryCheck> checkRepositoryUpdate({
    CatalogRepositorySource? source,
  }) async {
    checkCalls++;
    checkedSource = source;
    latestRepositoryCheck = _check;
    notifyListeners();
    return _check;
  }
}

CatalogPointer _pointer(String revision) =>
    CatalogRepositorySource.defaults.pointerForRevision(revision);

CatalogRepositoryCheck _successCheck(
  CatalogRepositorySource source,
  CatalogPointer pointer,
) => CatalogRepositoryCheck(
  source: source,
  checkedAt: DateTime.utc(2026, 11, 9, 12),
  status: CatalogRepositoryCheckStatus.success,
  latest: pointer,
);

CatalogRepositoryVerification _successVerification(
  CatalogRepositorySource source,
  CatalogPointer pointer,
) {
  final check = _successCheck(source, pointer);
  return CatalogRepositoryVerification(
    source: source,
    check: check,
    saved: true,
  );
}

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('shows saved target separately from actual Runtime', (
    tester,
  ) async {
    final source = CatalogRepositorySource(branch: 'saved');
    final runtime = _pointer('a' * 40);
    final next = CatalogRepositorySource(branch: 'next');
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      verification: _successVerification(next, runtime),
      check: _successCheck(source, runtime),
    );
    addTearDown(() {
      controller.preferences.dispose();
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );

    expect(find.text('已保存目标'), findsOneWidget);
    expect(find.text(source.repositoryUrl), findsWidgets);
    expect(find.text('当前运行版本'), findsOneWidget);
    expect(find.text('提交: aaaaaaaa'), findsOneWidget);
    expect(find.byKey(const Key('repository-url-field')), findsOneWidget);
    expect(find.byKey(const Key('repository-branch-field')), findsOneWidget);
  });

  testWidgets(
    'successful verification saves a new target without changing Runtime',
    (tester) async {
      final source = CatalogRepositorySource(branch: 'saved');
      final runtime = _pointer('b' * 40);
      final next = CatalogRepositorySource(branch: 'next');
      final controller = _FakeRepositoryController(
        savedSource: source,
        runtimePointer: runtime,
        verification: _successVerification(next, runtime),
        check: _successCheck(source, runtime),
      );
      addTearDown(() => _disposeController(controller));
      await tester.pumpWidget(
        MaterialApp(home: CatalogRepositorySettings(controller: controller)),
      );
      await tester.enterText(
        find.byKey(const Key('repository-branch-field')),
        'next',
      );
      await tester.tap(find.byKey(const Key('verify-repository-button')));
      await tester.pumpAndSettle();

      expect(controller.verifyCalls, 1);
      expect(controller.checkCalls, 0);
      expect(controller.savedSource, next);
      expect(controller.runtimePointer, runtime);
      expect(find.text('来源已验证并保存；下次启动时使用。'), findsOneWidget);
    },
  );

  testWidgets('verification failure keeps saved source and edited draft', (
    tester,
  ) async {
    final source = CatalogRepositorySource(branch: 'saved');
    final next = CatalogRepositorySource(branch: 'draft');
    final failure = const CatalogSetupFailure(
      CatalogSetupFailureKind.repositoryHeadUnavailable,
      diagnostic: 'repositoryHead:head_query_failed',
    );
    final verification = CatalogRepositoryVerification(
      source: next,
      check: CatalogRepositoryCheck(
        source: next,
        checkedAt: DateTime.utc(2026, 11, 9),
        status: CatalogRepositoryCheckStatus.failed,
        failure: failure,
      ),
      saved: false,
      failure: failure,
    );
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: _pointer('c' * 40),
      verification: verification,
      check: _successCheck(source, _pointer('c' * 40)),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );
    await tester.enterText(
      find.byKey(const Key('repository-branch-field')),
      'draft',
    );
    await tester.tap(find.byKey(const Key('verify-repository-button')));
    await tester.pumpAndSettle();

    expect(controller.savedSource, source);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('repository-branch-field')))
          .controller!
          .text,
      'draft',
    );
    expect(find.text('无法获取分支最新提交'), findsOneWidget);
  });

  testWidgets(
    'unsaved draft blocks update check and makes no controller call',
    (tester) async {
      final source = CatalogRepositorySource(branch: 'saved');
      final controller = _FakeRepositoryController(
        savedSource: source,
        runtimePointer: _pointer('d' * 40),
        verification: _successVerification(source, _pointer('d' * 40)),
        check: _successCheck(source, _pointer('d' * 40)),
      );
      addTearDown(() => _disposeController(controller));
      await tester.pumpWidget(
        MaterialApp(home: CatalogRepositorySettings(controller: controller)),
      );
      await tester.enterText(
        find.byKey(const Key('repository-branch-field')),
        'unsaved',
      );
      await tester.tap(find.byKey(const Key('check-update-button')));
      await tester.pumpAndSettle();

      expect(controller.checkCalls, 0);
      expect(find.textContaining('请先处理未保存修改'), findsOneWidget);
    },
  );

  testWidgets('different HEAD offers injected restart action', (tester) async {
    _useTallView(tester);
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('e' * 40);
    final latest = _pointer('f' * 40);
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      updateAvailable: true,
      verification: _successVerification(source, runtime),
      check: _successCheck(source, latest),
    );
    addTearDown(() => _disposeController(controller));
    var restarted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogRepositorySettings(
          controller: controller,
          restartAction: () async => restarted++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();

    expect(controller.checkCalls, 1);
    expect(controller.checkedSource, source);
    expect(find.textContaining('发现可用更新'), findsOneWidget);
    expect(find.byKey(const Key('restart-update-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('restart-update-button')));
    await tester.pumpAndSettle();
    expect(restarted, 1);
    expect(controller.runtimePointer, runtime);
  });

  testWidgets('same HEAD does not offer restart', (tester) async {
    _useTallView(tester);
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('1' * 40);
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      verification: _successVerification(source, runtime),
      check: _successCheck(source, runtime),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('与当前运行版本一致'), findsOneWidget);
    expect(find.byKey(const Key('restart-update-button')), findsNothing);
  });

  testWidgets(
    'missing Runtime or mismatched check source is not called current',
    (tester) async {
      _useTallView(tester);
      final saved = CatalogRepositorySource(branch: 'saved');
      final other = CatalogRepositorySource(branch: 'other');
      final controller = _FakeRepositoryController(
        savedSource: saved,
        runtimePointer: null,
        verification: _successVerification(saved, _pointer('1' * 40)),
        check: _successCheck(other, _pointer('1' * 40)),
      );
      addTearDown(() => _disposeController(controller));
      await tester.pumpWidget(
        MaterialApp(home: CatalogRepositorySettings(controller: controller)),
      );
      await tester.tap(find.byKey(const Key('check-update-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('查询来源与已保存目标不同'), findsOneWidget);
      expect(find.text('与当前运行版本一致'), findsNothing);
      expect(find.byKey(const Key('restart-update-button')), findsNothing);
    },
  );

  testWidgets('nullable failed classification remains a plain failure', (
    tester,
  ) async {
    _useTallView(tester);
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('2' * 40);
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      verification: _successVerification(source, runtime),
      check: CatalogRepositoryCheck(
        source: source,
        checkedAt: DateTime.utc(2026, 11, 9),
        status: CatalogRepositoryCheckStatus.failed,
      ),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('检查失败'), findsOneWidget);
    expect(find.text('与当前运行版本一致'), findsNothing);
  });

  testWidgets('failure and local fallback are never reported as latest', (
    tester,
  ) async {
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('2' * 40);
    final failure = const CatalogSetupFailure(
      CatalogSetupFailureKind.connectionFailed,
      diagnostic: 'repositoryHead:connection_failed',
    );
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      localFallback: true,
      fallbackReason: CatalogLocalFallbackReason.repositoryCheckFailed,
      verification: _successVerification(source, runtime),
      check: CatalogRepositoryCheck(
        source: source,
        checkedAt: DateTime.utc(2026, 11, 9),
        status: CatalogRepositoryCheckStatus.failed,
        failure: failure,
      ),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );

    expect(find.textContaining('正在使用本地版本'), findsOneWidget);
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('检查失败'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('检查失败'), findsOneWidget);
    expect(find.text('与当前运行版本一致'), findsNothing);
    expect(find.textContaining('已是最新'), findsNothing);
    expect(find.byKey(const Key('restart-update-button')), findsNothing);
  });

  testWidgets('successful check while local fallback stays explicit', (
    tester,
  ) async {
    _useTallView(tester);
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('5' * 40);
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      localFallback: true,
      fallbackReason: CatalogLocalFallbackReason.userSelected,
      verification: _successVerification(source, runtime),
      check: _successCheck(source, runtime),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前仍在使用本地版本'), findsOneWidget);
    expect(find.textContaining('与当前运行版本一致'), findsNothing);
    expect(find.textContaining('已是最新'), findsNothing);
  });

  testWidgets('manual restart action only shows safe cold-start guidance', (
    tester,
  ) async {
    _useTallView(tester);
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('3' * 40);
    final controller = _FakeRepositoryController(
      savedSource: source,
      runtimePointer: runtime,
      updateAvailable: true,
      verification: _successVerification(source, runtime),
      check: _successCheck(source, _pointer('4' * 40)),
    );
    addTearDown(() => _disposeController(controller));
    await tester.pumpWidget(
      MaterialApp(home: CatalogRepositorySettings(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('check-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restart-update-button')));
    await tester.pumpAndSettle();

    expect(find.text('重启并更新'), findsWidgets);
    expect(find.textContaining('请完全关闭 Venera'), findsOneWidget);
    expect(find.textContaining('检查并更新配置'), findsWidgets);
  });
}

void _useTallView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1600);
  addTearDown(tester.view.reset);
}

void _disposeController(CatalogController controller) {
  controller.preferences.dispose();
  controller.dispose();
}
