import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

History _history({
  String id = 'manager-cover-test',
  String cover = 'https://example.com/old.jpg',
  int type = 7,
}) {
  final history = History.fromMap({
    'type': type,
    'time': 1700000000000,
    'title': 'History manager test',
    'subtitle': 'subtitle',
    'cover': cover,
    'ep': 4,
    'page': 6,
    'id': id,
    'readEpisode': <String>['1', '2'],
    'max_page': 9,
  });
  history.group = 3;
  return history;
}

void main() {
  late Directory tempDir;
  late HistoryManager manager;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera_history_cover_');
    App.dataPath = tempDir.path;
    HistoryManager.cache = null;
    manager = HistoryManager();
    await manager.init();
  });

  tearDown(() {
    manager.close();
    HistoryManager.cache = null;
    tempDir.deleteSync(recursive: true);
  });

  test('conditional cover update changes only the cover column', () {
    final history = _history();
    manager.addHistory(history);
    var notifications = 0;
    manager.addListener(() => notifications++);

    final result = manager.updateCoverIfUnchanged(
      id: history.id,
      type: history.type,
      expectedCover: history.cover,
      newCover: 'https://example.com/new.jpg',
    );

    expect(result, isTrue);
    expect(notifications, 1);
    expect(history.cover, 'https://example.com/new.jpg');

    final stored = manager.getAll().single;
    expect(stored.cover, 'https://example.com/new.jpg');
    expect(stored.id, history.id);
    expect(stored.type, history.type);
    expect(stored.title, history.title);
    expect(stored.subtitle, history.subtitle);
    expect(stored.time, history.time);
    expect(stored.ep, 4);
    expect(stored.page, 6);
    expect(stored.readEpisode, {'1', '2'});
    expect(stored.maxPage, 9);
    expect(stored.group, 3);
  });

  test('cover mismatch or invalid new cover changes nothing', () {
    final history = _history(id: 'manager-cover-mismatch');
    manager.addHistory(history);
    final before = manager.getAll().single;
    var notifications = 0;
    manager.addListener(() => notifications++);

    expect(
      manager.updateCoverIfUnchanged(
        id: history.id,
        type: history.type,
        expectedCover: 'https://example.com/other.jpg',
        newCover: 'https://example.com/new.jpg',
      ),
      isFalse,
    );
    expect(
      manager.updateCoverIfUnchanged(
        id: history.id,
        type: history.type,
        expectedCover: before.cover,
        newCover: '',
      ),
      isFalse,
    );
    expect(
      manager.updateCoverIfUnchanged(
        id: history.id,
        type: history.type,
        expectedCover: before.cover,
        newCover: before.cover,
      ),
      isFalse,
    );

    final after = manager.getAll().single;
    expect(notifications, 0);
    expect(after.cover, before.cover);
    expect(after.ep, before.ep);
    expect(after.page, before.page);
    expect(after.time, before.time);
    expect(after.readEpisode, before.readEpisode);
    expect(after.maxPage, before.maxPage);
    expect(after.group, before.group);
  });

  test('deleted history is not reinserted by a conditional cover update', () {
    final history = _history(id: 'manager-cover-deleted');
    manager.addHistory(history);
    manager.remove(history.id, history.type);

    final result = manager.updateCoverIfUnchanged(
      id: history.id,
      type: history.type,
      expectedCover: history.cover,
      newCover: 'https://example.com/new.jpg',
    );

    expect(result, isFalse);
    expect(manager.getAll(), isEmpty);
    expect(manager.cachedHistories, isEmpty);
  });

  test(
    'a stale cached object is not overwritten after the database update',
    () {
      final history = _history(id: 'manager-cover-stale-cache');
      manager.addHistory(history);
      history.cover = 'https://example.com/third.jpg';

      final result = manager.updateCoverIfUnchanged(
        id: history.id,
        type: const ComicType(7),
        expectedCover: 'https://example.com/old.jpg',
        newCover: 'https://example.com/new.jpg',
      );

      expect(result, isTrue);
      expect(history.cover, 'https://example.com/third.jpg');
      expect(manager.getAll().single.cover, 'https://example.com/new.jpg');
    },
  );
}
