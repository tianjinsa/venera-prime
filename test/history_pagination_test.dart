import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';

class _Source implements ComicSource {
  @override
  String get key => 'history-pagination-source';
  @override
  String name = 'Ärt 图源';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

History _record(int index, {String? id, int type = 42, String? title}) =>
    History.fromMap({
      'id': id ?? 'id-${index.toString().padLeft(4, '0')}',
      'type': type,
      'title': title ?? 'Comic $index',
      'subtitle': 'An Author',
      'cover': 'https://example.invalid/$index.png',
      'time': 1700000000000 + index ~/ 5,
      'ep': 2,
      'page': 3,
      'readEpisode': ['1', '2'],
      'max_page': 100,
    })..group = 4;

ComicID _identity(History history) => ComicID(history.type, history.id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HistoryManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-history-pages-');
    App.dataPath = directory.path;
    manager = HistoryManager.create();
    HistoryManager.cache = manager;
    await manager.init();
  });

  tearDown(() async {
    manager.close();
    HistoryManager.cache = null;
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });

  void seed(List<History> histories) {
    final db = sqlite3.open('${directory.path}/history.db');
    try {
      db.execute('BEGIN;');
      final statement = db.prepare('''
        INSERT INTO history
          (id, type, title, subtitle, cover, time, ep, page, readEpisode,
           max_page, chapter_group)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''');
      try {
        for (final item in histories) {
          statement.execute([
            item.id,
            item.type.value,
            item.title,
            item.subtitle,
            item.cover,
            item.time.millisecondsSinceEpoch,
            item.ep,
            item.page,
            item.readEpisode.join(','),
            item.maxPage,
            item.group,
          ]);
        }
      } finally {
        statement.dispose();
      }
      db.execute('COMMIT;');
    } finally {
      db.dispose();
    }
  }

  test('bounded pages preserve all identities and tied timestamps', () async {
    seed([
      for (var i = 0; i < 1204; i++) _record(i),
      _record(1203, id: 'id-1203', type: 43),
    ]);
    final expected = manager.getAll();
    final actual = <History>[];
    HistoryCursor? cursor;
    do {
      final page = await manager.getPage(cursor: cursor, limit: 37);
      expect(page.items.length, lessThanOrEqualTo(37));
      actual.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(actual.map(_identity), expected.map(_identity));
    expect(actual.map(_identity).toSet(), hasLength(1205));
    expect(actual.first.readEpisode, {'1', '2'});
    expect(actual.first.group, 4);
    expect(actual.first.maxPage, 100);

    final db = sqlite3.open('${directory.path}/history.db');
    try {
      final plan = db.select(
        '''
        EXPLAIN QUERY PLAN SELECT * FROM history
        WHERE (time, id, type) < (?, ?, ?)
        ORDER BY time DESC, id DESC, type DESC LIMIT ?;
      ''',
        [1700000000100, 'id-0500', 42, 60],
      );
      final details = plan.map((row) => row['detail']).join('\n');
      expect(details, contains('history_time_identity_idx'));
      expect(details, isNot(contains('TEMP B-TREE')));
    } finally {
      db.dispose();
    }
  });

  test(
    'search covers unloaded rows and preserves Unicode and source names',
    () async {
      final source = _Source();
      ComicSourceManager().add(source);
      seed([
        for (var i = 0; i < 150; i++) _record(i),
        _record(
          0,
          id: 'deleted-123',
          type: source.key.hashCode,
          title: 'ÄBC Lost',
        ),
        _record(0, id: 'local-only', type: 0, title: '100% literal'),
        _record(0, id: 'unknown-only', type: 731, title: "x' OR 1=1 --"),
      ]);
      final initial = await manager.getPage();
      expect(initial.items, hasLength(60));
      expect(initial.items.any((item) => item.id == 'deleted-123'), isFalse);
      for (final query in ['äbc AUTHOR 图源', 'deleted-123', source.key]) {
        final result = await manager.getPage(query: query);
        expect(result.items.map((item) => item.id), ['deleted-123']);
        expect(result.nextCursor, isNull);
      }
      source.name = 'Renamed source';
      expect(
        (await manager.getPage(query: 'renamed')).items.map((item) => item.id),
        ['deleted-123'],
      );
      expect(
        (await manager.getPage(query: '100% local')).items.single.id,
        'local-only',
      );
      expect(
        (await manager.getPage(query: "x' OR 1=1 --")).items.single.id,
        'unknown-only',
      );
      expect(
        (await manager.getPage(query: 'Unknown:731')).items.single.id,
        'unknown-only',
      );
      expect((await manager.getPage(query: 'äbc missing')).items, isEmpty);
    },
  );

  test(
    'query selection returns all matching identities without page limits',
    () async {
      seed([
        for (var i = 0; i < 180; i++)
          _record(i, title: i.isEven ? 'Match' : 'Other'),
      ]);
      final first = await manager.getPage(query: 'match', limit: 20);
      final second = await manager.getPage(
        query: 'match',
        cursor: first.nextCursor,
        limit: 20,
      );
      expect(first.items, hasLength(20));
      expect(second.items, hasLength(20));
      expect(first.items.toSet().intersection(second.items.toSet()), isEmpty);
      final identities = await manager.getMatchingIds(query: 'match');
      expect(identities, hasLength(90));
      expect(identities, containsAll(first.items.map(_identity)));
      expect(await manager.getMatchingIds(), hasLength(180));
    },
  );

  test(
    'deleting the cursor and inserting newer history does not skip a page',
    () async {
      seed([for (var i = 0; i < 140; i++) _record(i)]);
      final expected = manager.getAll();
      final first = await manager.getPage();
      final last = first.items.last;
      manager.remove(last.id, last.type);
      manager.addHistory(_record(500));
      final second = await manager.getPage(cursor: first.nextCursor);
      expect(
        second.items.map(_identity),
        expected.skip(60).take(60).map(_identity),
      );
    },
  );

  test(
    'an active read snapshot does not block saving reading progress',
    () async {
      seed([_record(1)]);
      final reader = sqlite3.open(
        '${directory.path}/history.db',
        mode: OpenMode.readOnly,
      );
      try {
        expect(reader.select('PRAGMA journal_mode;').single[0], 'wal');
        reader.execute('BEGIN;');
        expect(reader.select('SELECT count(*) FROM history;').single[0], 1);
        manager.addHistory(_record(2));
        expect(reader.select('SELECT count(*) FROM history;').single[0], 1);
        expect((await manager.getPage()).items, hasLength(2));
        reader.execute('COMMIT;');
        expect(reader.select('SELECT count(*) FROM history;').single[0], 2);
      } finally {
        reader.dispose();
      }
    },
  );

  test(
    'restoring waits for workers and prevents new reads until reinitialized',
    () async {
      seed([_record(1)]);
      final read = manager.getPage();
      final close = manager.closeAfterReads();
      await expectLater(manager.getMatchingIds(), throwsStateError);
      expect((await read).items, hasLength(1));
      await close;
      expect(manager.isInitialized, isFalse);
      await manager.init();
      expect((await manager.getPage()).items, hasLength(1));
    },
  );
}
