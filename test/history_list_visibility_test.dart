import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

History _history(String id, {int page = 12}) {
  return History.fromMap({
    'type': 0,
    'time': 1700000000000,
    'title': id,
    'subtitle': '',
    'cover': '',
    'ep': 8,
    'page': page,
    'id': id,
    'readEpisode': <String>['1', '2-8'],
    'max_page': 28,
  })..group = 2;
}

void main() {
  late Directory dataDir;
  late HistoryManager manager;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('venera_history_visibility_');
    App.dataPath = dataDir.path;
    manager = HistoryManager.create();
    HistoryManager.cache = manager;
  });

  tearDown(() async {
    await manager.closeWhenIdle();
    HistoryManager.cache = null;
    dataDir.deleteSync(recursive: true);
  });

  test('legacy history stays visible through the database migration', () async {
    final database = sqlite3.open('${dataDir.path}/history.db');
    try {
      database.execute("""
        create table history (
          id text primary key, title text, subtitle text, cover text, time int,
          type int, ep int, page int, readEpisode text, max_page int,
          chapter_group int
        );
        insert into history values (
          'legacy', 'Legacy', '', '', 1700000000000, 0, 8, 12, '1,2-8', 28, 2
        );
      """);
    } finally {
      database.dispose();
    }

    await manager.init();
    expect(manager.getRecent().single.id, 'legacy');
    expect(manager.count(), 1);
    final stored = manager.find('legacy', ComicType.local)!;
    expect(
      (stored.group, stored.ep, stored.page, stored.maxPage),
      (2, 8, 12, 28),
    );
    expect(stored.readEpisode, {'1', '2-8'});
  });

  test('clear keeps resume and chapter marks across database reopen', () async {
    await manager.init();
    manager.addHistory(_history('a'));
    manager.addHistory(_history('b'));
    expect(manager.getAll(), hasLength(2));

    await manager.clearHistoryList();
    expect(manager.getAll(), isEmpty);
    expect(manager.getRecent(), isEmpty);
    expect(manager.count(), 0);
    expect(manager.find('a', ComicType.local)?.page, 12);
    manager.close();
    await manager.init();

    expect(manager.getRecent(), isEmpty);
    final stored = manager.find('a', ComicType.local)!;
    expect(
      (stored.group, stored.ep, stored.page, stored.maxPage),
      (2, 8, 12, 28),
    );
    expect(stored.readEpisode, {'1', '2-8'});

    await manager.addHistoryAsync(_history('a', page: 13));
    expect(manager.count(), 0);
    expect(manager.find('a', ComicType.local)?.page, 13);

    await manager.addHistoryAsync(
      manager.find('a', ComicType.local)!,
      listEntryRevision: manager.listRevision,
    );
    expect(manager.getAll().single.id, 'a');
    expect(manager.getRecent().single.page, 13);
    expect(manager.count(), 1);
    expect(manager.find('b', ComicType.local)?.page, 12);
  });

  test('one or more removals hide only the requested comics', () async {
    await manager.init();
    for (final id in ['a', 'b', 'c', 'd']) {
      manager.addHistory(_history(id));
    }
    final originalEntry = manager.listRevision;
    await manager.hideFromHistoryList([const ComicID(ComicType.local, 'a')]);
    expect(manager.count(), 3);
    await manager.hideFromHistoryList([
      const ComicID(ComicType.local, 'b'),
      const ComicID(ComicType.local, 'c'),
    ]);
    expect(manager.getAll().single.id, 'd');

    await manager.addHistoryAsync(
      _history('a', page: 14),
      listEntryRevision: originalEntry,
    );
    manager.addHistory(_history('b', page: 16));
    await manager.addHistoryAsync(
      _history('e'),
      listEntryRevision: originalEntry,
    );
    expect(
      manager.getRecent().map((item) => item.id),
      unorderedEquals(['d', 'e']),
    );
    expect(manager.find('a', ComicType.local)?.page, 14);
    expect(manager.find('b', ComicType.local)?.page, 16);
  });

  test(
    'clear takes precedence over queued first saves for new comics',
    () async {
      await manager.init();
      final originalEntry = manager.listRevision;
      final save = manager.addHistoryAsync(
        _history('saving'),
        listEntryRevision: originalEntry,
      );
      // Let the save start and race with the clear rather than merely enqueue it
      // before the write queue has run.
      await Future<void>.delayed(Duration.zero);
      final clear = manager.clearHistoryList();
      final delayedSave = manager.addHistoryAsync(
        _history('delayed'),
        listEntryRevision: originalEntry,
      );
      await Future.wait([save, clear, delayedSave]);

      expect(manager.getAll(), isEmpty);
      expect(manager.find('saving', ComicType.local)?.page, 12);
      expect(manager.find('delayed', ComicType.local)?.page, 12);
    },
  );

  test(
    'a failed clear preserves visibility and the next queued save',
    () async {
      await manager.init();
      manager.addHistory(_history('existing'));
      final database = sqlite3.open('${dataDir.path}/history.db');
      try {
        database.execute("""
        create trigger fail_clear before update of visible on history
        when new.visible = 0
        begin
          select raise(abort, 'test clear failure');
        end;
      """);
      } finally {
        database.dispose();
      }

      final originalEntry = manager.listRevision;
      final clear = manager.clearHistoryList();
      final save = manager.addHistoryAsync(
        _history('new'),
        listEntryRevision: originalEntry,
      );
      await expectLater(clear, throwsA(isA<SqliteException>()));
      await save;

      expect(
        manager.getAll().map((entry) => entry.id),
        unorderedEquals(['existing', 'new']),
      );
    },
  );
}
