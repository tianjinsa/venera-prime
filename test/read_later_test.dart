import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/read_later.dart';

void main() {
  test('unsupported schema fails without replacing a healthy database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'read-later-unknown-',
    );
    App.dataPath = directory.path;
    final manager = ReadLaterManager();
    manager.close();
    addTearDown(() async {
      manager.close();
      await directory.delete(recursive: true);
    });
    final path = '${directory.path}/read_later.db';
    final db = sqlite3.open(path);
    db.execute(
      "CREATE TABLE read_later (id TEXT); INSERT INTO read_later VALUES ('keep');",
    );
    db.dispose();
    await expectLater(manager.init(), throwsFormatException);
    expect(manager.isInitialized, isFalse);
    final preserved = sqlite3.open(path);
    try {
      expect(preserved.select('SELECT id FROM read_later;').single[0], 'keep');
    } finally {
      preserved.dispose();
    }
    expect(
      directory.listSync().where((file) => file.path.contains('.corrupt.')),
      isEmpty,
    );
  });

  for (final populated in [false, true]) {
    test('migrates legacy backup schema (populated=$populated)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'read-later-old-',
      );
      App.dataPath = directory.path;
      final manager = ReadLaterManager();
      manager.close();
      addTearDown(() async {
        manager.close();
        await directory.delete(recursive: true);
      });
      final path = '${directory.path}/read_later.db';
      final db = sqlite3.open(path);
      db.execute('''
        CREATE TABLE read_later (
          id TEXT NOT NULL,
          type INTEGER NOT NULL,
          title TEXT NOT NULL,
          subtitle TEXT,
          cover TEXT NOT NULL,
          source_key TEXT NOT NULL,
          added_time INTEGER NOT NULL,
          PRIMARY KEY (id, type)
        );
      ''');
      if (populated) {
        for (final timestamp in [10, 20]) {
          db.execute('INSERT INTO read_later VALUES (?, ?, ?, ?, ?, ?, ?);', [
            '$timestamp',
            ComicType.local.value,
            'Legacy $timestamp',
            null,
            'cover',
            'local',
            timestamp,
          ]);
        }
      }
      db.dispose();

      await manager.init();
      expect(
        manager.getAll().map((comic) => comic.id),
        populated ? ['20', '10'] : isEmpty,
      );
      if (populated) {
        final comic = manager.getAll(keyword: 'Legacy').first;
        expect(comic.type, ComicType.local);
        expect(comic.subtitle, isEmpty);
        expect(comic.description, isEmpty);
        expect(comic.tags, isEmpty);
        expect(comic.sourceKey, 'local');
      }
      final migrated = sqlite3.open(path);
      try {
        expect(migrated.select('PRAGMA integrity_check;').single[0], 'ok');
        expect(
          migrated
              .select('SELECT added_at FROM read_later ORDER BY added_at;')
              .map((row) => row[0]),
          populated ? [10, 20] : isEmpty,
        );
      } finally {
        migrated.dispose();
      }
      final original = manager.getAll();
      const added = Comic(
        'New',
        'cover',
        'new',
        '',
        [],
        '',
        'local',
        null,
        null,
      );
      expect(manager.add(added), isTrue);
      expect(manager.add(added), isFalse);
      expect(manager.getAll().first.id, 'new');
      expect(manager.removeComic(added), isTrue);
      manager.restore(original);
      manager.close();
      await manager.init();
      expect(manager.getAll(), hasLength(populated ? 2 : 0));
      expect(
        directory.listSync().where((file) => file.path.contains('.corrupt.')),
        isEmpty,
      );
    });
  }

  test('read later keeps source identity and rejects duplicates', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-read-later-',
    );
    App.dataPath = directory.path;
    final manager = ReadLaterManager();
    manager.close();
    await manager.init();
    manager.clear();

    const first = Comic(
      'First',
      'cover-1',
      'same-id',
      'author',
      ['tag'],
      '',
      'source-a',
      null,
      null,
    );
    const second = Comic(
      'Second',
      'cover-2',
      'same-id',
      'author',
      ['tag'],
      '',
      'source-b',
      null,
      null,
    );
    expect(manager.add(first), isTrue);
    expect(manager.add(first), isFalse);
    expect(manager.add(second), isTrue);
    expect(manager.getAll(), hasLength(2));
    final firstType = manager.typeForComic(first);
    final secondType = manager.typeForComic(second);
    final saved = manager.getComic(first.id, firstType)!;
    expect(saved.sourceKey, first.sourceKey);
    expect(saved.title, first.title);
    expect(saved.cover, first.cover);
    expect(saved.tags, first.tags);
    expect(manager.getComic(second.id, secondType)?.title, second.title);
    expect(manager.getComic('missing', firstType), isNull);
    expect(manager.remove(first.id, firstType), isTrue);
    expect(manager.getComic(first.id, firstType), isNull);
    expect(manager.getComic(second.id, secondType)?.title, second.title);

    manager.removeMany(manager.getAll());
    expect(manager.getAll(), isEmpty);
    manager.close();
    await directory.delete(recursive: true);
  });

  test('migrates an older table and recovers a corrupt database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-read-later-migration-',
    );
    App.dataPath = directory.path;
    final path = '${directory.path}/read_later.db';
    final oldDb = sqlite3.open(path);
    oldDb.execute('''
      CREATE TABLE read_later (
        id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        source_key TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    oldDb.execute(
      '''INSERT INTO read_later
         (id, comic_type, source_key, title, subtitle, tags, cover, added_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?);''',
      ['legacy', ComicType.local.value, 'local', 'Legacy', '', '[]', '', 1],
    );
    oldDb.dispose();

    final manager = ReadLaterManager();
    manager.close();
    await manager.init();
    expect(manager.getAll().single.description, isEmpty);
    expect(File(path).readAsBytesSync(), isNotEmpty);

    manager.close();
    await File(path).writeAsString('not a sqlite database');
    await manager.init();
    expect(manager.getAll(), isEmpty);
    expect(
      directory.listSync().whereType<File>().any(
        (file) => file.path.contains('.corrupt.'),
      ),
      isTrue,
    );
    manager.close();
    await directory.delete(recursive: true);
  });
}
