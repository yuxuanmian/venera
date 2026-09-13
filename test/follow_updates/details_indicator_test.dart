import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Contract W (007) at the page level: visibility, the value shown, refresh on
/// a judgment batch, and the two failure shapes.
///
/// The page's schedule read is a **point read of one identity** used only for
/// display, so this file drives the real `ComicPage` and injects only the two
/// boundaries that would otherwise need the whole composition layer: the reader
/// (so a read can be controlled and counted) and the judgment batch stream (so
/// a batch can be delivered without running a judgment pass).
const _sourceKey = 'indicator-source';
const _comicId = 'indicator-comic';

const _fireIcon = ValueKey('favorite-hot-window-fire-icon');
const _splitButton = ValueKey('favorite-hot-window-split-button');

ComicSource _buildSource(String sourceKey) {
  final coverPath =
      'file://${Directory.current.path}${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}app_icon.png';
  final favoriteData = FavoriteData(
    key: sourceKey,
    title: 'Favorites',
    multiFolder: true,
    loadComic: null,
    loadNext: null,
    // No folder refresh: this file is about the indicator, and an unawaited
    // folder request would add a second, unrelated async path.
    loadFolders: null,
  );
  final source = ComicSource(
    'Indicator source',
    sourceKey,
    null,
    null,
    null,
    favoriteData,
    const [],
    null,
    null,
    (id) async => Res(
      ComicDetails.fromJson({
        'title': 'Comic $id',
        'subtitle': 'Author',
        'cover': coverPath,
        'description': 'Details loaded',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{'ep': 'Chapter'},
        'sourceKey': sourceKey,
        'comicId': id,
        'isFavorite': true,
        'isLiked': false,
      }),
    ),
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
  source.data['account'] = const ['logged-in'];
  return source;
}

/// Whether the split button is present at all.
bool _indicatorShown(WidgetTester tester) =>
    find.byKey(_splitButton).evaluate().isNotEmpty;

/// Whether the fire icon is drawn "lit" (an automatic hot window is open).
bool _indicatorLit(WidgetTester tester) {
  final icon = tester.widget<Icon>(find.byKey(_fireIcon));
  return icon.icon == Icons.local_fire_department;
}

ScheduleState _record({DateTime? autoHotUntil}) => ScheduleState(
  sourceKey: _sourceKey,
  comicId: _comicId,
  nextAtMs: DateTime.now().millisecondsSinceEpoch,
  autoHotUntilMs: autoHotUntil?.millisecondsSinceEpoch,
);

/// The indicator's own explanatory text.
///
/// Scoped to the split button: the page has other tooltips (the app bar's icon
/// buttons), so an unscoped `find.byType(Tooltip)` would be ambiguous.
String _indicatorTooltip(WidgetTester tester) =>
    tester
        .widget<Tooltip>(
          find.descendant(
            of: find.byKey(_splitButton),
            matching: find.byType(Tooltip),
          ),
        )
        .message ??
    '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late StreamController<JudgmentBatchEvent> events;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = Directory.systemTemp.createTempSync('venera-details-indicator-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    await HistoryManager().init();
    await NetworkFavoriteCacheManager().init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}favorites.db',
      migrateLegacy: false,
    );
  });

  setUp(() {
    events = StreamController<JudgmentBatchEvent>.broadcast();
    appdata.settings['followUpdatesEnabled'] = true;
  });

  tearDown(() {
    unawaited(events.close());
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<ScheduleState?> Function(String, String) reader,
  }) async {
    ComicSourceManager().add(_buildSource(_sourceKey));
    addTearDown(() => ComicSourceManager().remove(_sourceKey));
    await tester.pumpWidget(
      MaterialApp(
        home: ComicPage(
          id: _comicId,
          sourceKey: _sourceKey,
          scheduleReader: reader,
          judgmentEvents: events.stream,
        ),
      ),
    );
    // One pump for the details load, one for the schedule point read.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a record with an open window is lit', (tester) async {
    final until = DateTime.now().add(const Duration(hours: 1));
    var reads = 0;
    await pumpPage(
      tester,
      reader: (sourceKey, comicId) async {
        reads++;
        expect(sourceKey, _sourceKey);
        expect(comicId, _comicId);
        return _record(autoHotUntil: until);
      },
    );

    expect(
      reads,
      1,
      reason: 'one point read on open, never a whole-table read',
    );
    expect(_indicatorShown(tester), isTrue);
    expect(_indicatorLit(tester), isTrue);
    // The explanation is reachable from the page, and it names the stored
    // deadline rather than offering an action (W5; the semantics/label detail
    // is asserted in follow_update_hot_window_widget_test.dart).
    expect(_indicatorTooltip(tester), contains('Recently updated'.tl));
    expect(
      _indicatorTooltip(tester),
      contains(
        'Auto hot window until @time'.tlParams({
          'time': until.toLocal().toString().substring(0, 19),
        }),
      ),
    );
  });

  testWidgets('a record with a closed or absent window is unlit', (
    tester,
  ) async {
    await pumpPage(
      tester,
      reader: (_, __) async => _record(
        autoHotUntil: DateTime.now().subtract(const Duration(hours: 1)),
      ),
    );
    expect(_indicatorShown(tester), isTrue);
    expect(_indicatorLit(tester), isFalse);
    expect(_indicatorTooltip(tester), 'No recent update'.tl);

    // Same record, deadline never set: still shown (there IS a check record),
    // still unlit.
    await pumpPage(tester, reader: (_, __) async => _record());
    expect(_indicatorShown(tester), isTrue);
    expect(_indicatorLit(tester), isFalse);
  });

  testWidgets('no schedule record means no indicator at all', (tester) async {
    await pumpPage(tester, reader: (_, __) async => null);

    expect(_indicatorShown(tester), isFalse);
    expect(find.byKey(_fireIcon), findsNothing);
    // The ordinary favorite button takes the slot instead: the page is intact.
    expect(find.text('Comic $_comicId'), findsWidgets);
    expect(find.text('Favorite'.tl), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follow-up being off hides the indicator even with a record', (
    tester,
  ) async {
    appdata.settings['followUpdatesEnabled'] = false;
    await pumpPage(
      tester,
      reader: (_, __) async =>
          _record(autoHotUntil: DateTime.now().add(const Duration(hours: 1))),
    );

    expect(_indicatorShown(tester), isFalse);
    expect(find.byKey(_fireIcon), findsNothing);
  });

  testWidgets('a read failure is shown as "no record" and breaks nothing', (
    tester,
  ) async {
    await pumpPage(
      tester,
      reader: (_, __) async => throw StateError('schedule store unavailable'),
    );

    expect(_indicatorShown(tester), isFalse);
    expect(find.text('Comic $_comicId'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only a batch containing this identity triggers a re-read', (
    tester,
  ) async {
    var reads = 0;
    var state = _record(autoHotUntil: null);
    await pumpPage(
      tester,
      reader: (_, __) async {
        reads++;
        return state;
      },
    );
    expect(reads, 1);
    expect(_indicatorLit(tester), isFalse);

    // A batch about other comics: no re-read (avoiding pointless I/O).
    events.add(
      const JudgmentBatchEvent(
        rows: [
          JudgmentRowResult(
            sourceKey: _sourceKey,
            comicId: 'some-other-comic',
            conclusion: JudgmentConclusion.changed,
            observedAtMs: 1,
          ),
          JudgmentRowResult(
            sourceKey: 'another-source',
            comicId: _comicId,
            conclusion: JudgmentConclusion.changed,
            observedAtMs: 2,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(reads, 1, reason: 'neither row is this page\'s identity');

    // This identity changed: exactly one re-read, and the page updates without
    // navigating away.
    state = _record(autoHotUntil: DateTime.now().add(const Duration(hours: 1)));
    events.add(
      const JudgmentBatchEvent(
        rows: [
          JudgmentRowResult(
            sourceKey: _sourceKey,
            comicId: _comicId,
            conclusion: JudgmentConclusion.changed,
            observedAtMs: 3,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(reads, 2, reason: 'at most one re-read per batch per identity');
    expect(_indicatorLit(tester), isTrue);
  });

  testWidgets('a batch carrying this identity twice still re-reads once', (
    tester,
  ) async {
    var reads = 0;
    await pumpPage(
      tester,
      reader: (_, __) async {
        reads++;
        return _record();
      },
    );
    expect(reads, 1);

    events.add(
      const JudgmentBatchEvent(
        rows: [
          JudgmentRowResult(
            sourceKey: _sourceKey,
            comicId: _comicId,
            conclusion: JudgmentConclusion.unchanged,
            observedAtMs: 1,
          ),
          JudgmentRowResult(
            sourceKey: _sourceKey,
            comicId: _comicId,
            conclusion: JudgmentConclusion.unknown,
            observedAtMs: 2,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
  });

  testWidgets('leaving the page cancels the batch subscription', (
    tester,
  ) async {
    var reads = 0;
    await pumpPage(
      tester,
      reader: (_, __) async {
        reads++;
        return _record();
      },
    );
    expect(reads, 1);

    await tester.pumpWidget(const SizedBox());
    events.add(
      const JudgmentBatchEvent(
        rows: [
          JudgmentRowResult(
            sourceKey: _sourceKey,
            comicId: _comicId,
            conclusion: JudgmentConclusion.changed,
            observedAtMs: 1,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(reads, 1, reason: 'a disposed page must not read or rebuild');
    expect(tester.takeException(), isNull);
  });
}
