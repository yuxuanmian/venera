import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/entry_route.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

final _pageTurn = find.byKey(const ValueKey('reader-page-turn'));
final _loadingVeil = find.byKey(const ValueKey('reader-loading-veil'));

class _ControlledReaderSource extends RetirementFakeSource {
  _ControlledReaderSource() : super(sourceKey: retirementSourceA);

  final metadata = Completer<void>();
  final pages = Completer<Res<List<String>>>();
  final nextChapter = Completer<Res<List<String>>>();

  @override
  Future<Res<ComicDetails>> detail(String id) async {
    await metadata.future;
    return super.detail(id);
  }

  @override
  Future<Res<List<String>>> readerPages(String id, String? ep) =>
      ep == '2' ? nextChapter.future : pages.future;
}

class _ReaderFrame extends ImageStreamCompleter {
  void show() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint()..color = Colors.blueGrey);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(16, 24)));
    picture.dispose();
  }

  void fail() => reportError(exception: StateError('Broken manga image'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;
  late RetirementFixture fixture;

  setUpAll(() async {
    await AppTranslation.init();
    appDirectory = await Directory.systemTemp.createTemp(
      'venera-retirement-detail-app-',
    );
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
    await HistoryManager().init();
    await LocalManager().init();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(retirementSourceA);
    HistoryManager().close();
    LocalManager().dispose();
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  setUp(() async {
    fixture = await createRetirementFixture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    ComicSourceManager().remove(retirementSourceA);
    await fixture.dispose();
  });

  void registerSource(RetirementFakeSource source) {
    ComicSourceManager().remove(source.sourceKey);
    ComicSourceManager().add(source.buildComicSource());
  }

  Future<void> pumpPage(
    WidgetTester tester,
    Widget child, {
    bool reduceMotion = false,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        theme: ThemeData(brightness: brightness),
        home: child,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: WindowFrame(child!),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settleLoading(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  Future<void> closeReader(
    WidgetTester tester, {
    bool expectHistoryWrite = false,
  }) async {
    final history = HistoryManager();
    var saved = false;
    void onSave() => saved = true;
    if (expectHistoryWrite) history.addListener(onSave);
    try {
      await pumpPage(tester, const SizedBox.shrink());
      // Reader disposal schedules the existing data-sync registration timer.
      await tester.pump(const Duration(seconds: 1));
      if (expectHistoryWrite) {
        // History uses a real isolate for SQLite even in a widget test.
        for (var attempt = 0; attempt < 20 && !saved; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(saved, isTrue);
      }
    } finally {
      if (expectHistoryWrite) history.removeListener(onSave);
    }
  }

  Animation<double> veilOpacity(WidgetTester tester) =>
      tester.widget<FadeTransition>(_loadingVeil).opacity;

  _ReaderFrame prepareReaderFrame(String page, {String chapter = '1'}) {
    final key = ReaderImageProvider(
      page,
      retirementSourceA,
      'retire-c',
      chapter,
      1,
    );
    final cache = PaintingBinding.instance.imageCache;
    final frame = _ReaderFrame();
    cache.putIfAbsent(key, () => frame);
    addTearDown(() => cache.evict(key));
    return frame;
  }

  testWidgets(
    'ComicPage uses the registered source for normal detail success',
    (tester) async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('Fake retire-c'), findsWidgets);
      expect(source.counters.detailCalls, 1);
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ComicPage keeps ordinary retry and offers only favorite removal on a 404',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: '404 Not Found',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('404 Not Found'), findsOneWidget);
      // `retire-c` is a cached favorite, so removal is offered — and that is
      // the point: the action is justified by the user's own favorite, not by a
      // delist verdict the app can no longer form (FR-023).
      expect(find.text('Remove Favorite'.tl), findsOneWidget);
      expect(
        find.text('Clear Suspected Removed'.tl),
        findsNothing,
        reason: 'the control was removed from the build, not merely hidden',
      );
      final callsBeforeRetry = source.counters.detailCalls;

      await tester.tap(find.text('Retry'.tl));
      await settleLoading(tester);

      expect(source.counters.detailCalls, greaterThan(callsBeforeRetry));
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ComicPage offers only Remove Favorite, and never a suspected-removed control',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: 'comic removed (404)',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-b', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('comic removed (404)'), findsOneWidget);
      expect(find.text('Remove Favorite'.tl), findsOneWidget);
      // The removed control, its handler and its backing verdict are all gone
      // (FR-023).  Its absence is the assertion: a returning button would mean
      // the retired verdict came back with it.
      expect(find.text('Clear Suspected Removed'.tl), findsNothing);
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ReaderWithLoading opens the normal reader and keeps scan state untouched',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        readerPagesPending: true,
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Reader), findsOneWidget);
      expect(source.counters.detailCalls, 1);
      expect(source.counters.readerPageCalls, 1);
      expect(snapshotRetirementState(fixture.databasePath), before);
      expect(_pageTurn, findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(_pageTurn, findsOneWidget);
      expect(find.byType(SkeletonBlock), findsNothing);
      await tester.tapAt(tester.getCenter(_pageTurn));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);

      // Keep page loading pending so the test does not perform an image
      // request; the real reader route has already been entered.
      await closeReader(tester);
    },
  );

  testWidgets(
    'ReaderWithLoading shows ordinary removed errors without scan evidence',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: 'removed by source (404)',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-b', sourceKey: retirementSourceA),
      );
      expect(_pageTurn, findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_pageTurn, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.text('removed by source (404)'), findsOneWidget);
      expect(find.text('Retry'.tl), findsOneWidget);
      expect(_pageTurn, findsNothing);
      expect(find.byType(Reader), findsNothing);
      expect(source.counters.detailCalls, greaterThanOrEqualTo(4));
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets('slow reader loading waits for the full-screen entry to settle', (
    tester,
  ) async {
    final source = RetirementFakeSource(
      sourceKey: retirementSourceA,
      readerPagesPending: true,
    );
    registerSource(source);
    const open = ValueKey('open-reader-for-loading');
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: open,
            onPressed: () => pushReader(
              context,
              () => const ReaderWithLoading(
                id: 'retire-c',
                sourceKey: retirementSourceA,
              ),
            ),
            child: const Text('Read'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(open));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 780));
    expect(source.counters.readerPageCalls, 1);
    expect(_pageTurn, findsNothing);

    await tester.pump(const Duration(milliseconds: 40));
    expect(_pageTurn, findsOneWidget);

    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await closeReader(tester);
  });

  for (final mode in ['galleryLeftToRight', 'continuousTopToBottom']) {
    testWidgets('loading runs across metadata, chapter and image in $mode', (
      tester,
    ) async {
      final previousMode = appdata.settings['readerMode'];
      final previousPreload = appdata.settings['preloadImageCount'];
      appdata.settings['readerMode'] = mode;
      appdata.settings['preloadImageCount'] = 0;
      addTearDown(() {
        appdata.settings['readerMode'] = previousMode;
        appdata.settings['preloadImageCount'] = previousPreload;
      });

      final source = _ControlledReaderSource();
      registerSource(source);
      const firstPage = 'file://first-image';
      const resumePage = 'file://resume-image';
      final first = prepareReaderFrame(firstPage);
      final resume = prepareReaderFrame(resumePage);
      await pumpPage(
        tester,
        const ReaderWithLoading(
          id: 'retire-c',
          sourceKey: retirementSourceA,
          initialPage: 2,
        ),
        brightness: mode == 'galleryLeftToRight'
            ? Brightness.dark
            : Brightness.light,
      );
      final originalVeil = veilOpacity(tester);
      final originalBackground =
          (tester.widget<FadeTransition>(_loadingVeil).child! as ColoredBox)
              .color;
      await tester.pump(const Duration(milliseconds: 250));
      expect(_pageTurn, findsOneWidget);
      expect(find.textContaining('正在打开'), findsNothing);

      source.metadata.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(Reader), findsOneWidget);
      expect(veilOpacity(tester), same(originalVeil));
      expect(
        (tester.widget<FadeTransition>(_loadingVeil).child! as ColoredBox)
            .color,
        originalBackground,
      );
      expect(_pageTurn, findsOneWidget);

      source.pages.complete(const Res([firstPage, resumePage]));
      await tester.pump();
      await tester.pump();
      first.show();
      await tester.pump(const Duration(milliseconds: 280));
      expect(originalVeil.value, 1);
      expect(_pageTurn, findsOneWidget);

      resume.show();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(originalVeil.value, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(originalVeil.value, 0);
      expect(_pageTurn, findsNothing);
      await closeReader(tester, expectHistoryWrite: true);
    });
  }

  testWidgets('an image failure immediately exposes the existing retry', (
    tester,
  ) async {
    final source = _ControlledReaderSource();
    registerSource(source);
    const image = 'file://broken-image';
    final frame = prepareReaderFrame(image);
    source.metadata.complete();
    source.pages.complete(const Res([image]));
    await pumpPage(
      tester,
      const ReaderWithLoading(id: 'retire-c', sourceKey: retirementSourceA),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(_pageTurn, findsOneWidget);

    frame.fail();
    await tester.pump();
    await tester.pump();
    expect(veilOpacity(tester).value, 0);
    expect(_pageTurn, findsNothing);
    expect(find.textContaining('Broken manga image'), findsOneWidget);
    expect(find.text('Retry'.tl), findsOneWidget);
    await closeReader(tester, expectHistoryWrite: true);
  });

  testWidgets('a cached first image skips the flip delay', (tester) async {
    final source = _ControlledReaderSource();
    registerSource(source);
    const image = 'file://cached-image';
    prepareReaderFrame(image).show();
    source.metadata.complete();
    source.pages.complete(const Res([image]));
    await pumpPage(
      tester,
      const ReaderWithLoading(id: 'retire-c', sourceKey: retirementSourceA),
    );
    await tester.pump();
    await tester.pump();
    expect(veilOpacity(tester).value, 0);
    expect(_pageTurn, findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_pageTurn, findsNothing);
    await closeReader(tester, expectHistoryWrite: true);
  });

  testWidgets(
    'a direct reader switches chapters with a static book when requested',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = _ControlledReaderSource();
      registerSource(source);
      const first = 'file://direct-first-chapter';
      const second = 'file://direct-second-chapter';
      prepareReaderFrame(first).show();
      final nextFrame = prepareReaderFrame(second, chapter: '2');
      source.pages.complete(const Res([first]));
      source.metadata.complete();
      final details = await source.detail('retire-c');
      final history = History.fromModel(model: details.data, ep: 1, page: 1);
      await pumpPage(
        tester,
        Reader(
          type: ComicType.fromKey(retirementSourceA),
          cid: 'retire-c',
          name: 'Fake retire-c',
          chapters: const ComicChapters({'1': 'Chapter 1', '2': 'Chapter 2'}),
          history: history,
          author: '',
          tags: const [],
        ),
        reduceMotion: true,
      );
      await tester.pumpAndSettle();
      final opening = veilOpacity(tester);
      expect(opening.value, 0);

      await tester.tapAt(const Offset(195, 400));
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.last_page));
      await tester.pump();
      expect(opening.value, 1);
      expect(_pageTurn, findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_pageTurn, findsOneWidget);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );

      source.nextChapter.complete(const Res([second]));
      await tester.pump();
      await tester.pump();
      expect(opening.value, 1);
      nextFrame.show();
      await tester.pump();
      await tester.pump();
      expect(opening.value, 0);
      expect(_pageTurn, findsNothing);
      expect(history.ep, 2);
      await closeReader(tester, expectHistoryWrite: true);
    },
  );
}
