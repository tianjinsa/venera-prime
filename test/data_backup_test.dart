import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/archive_security.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart' as native_zip;

Comic _comic() => const Comic(
  'Backup comic',
  'cover',
  'backup-id',
  'author',
  ['backup'],
  '',
  'backup-source',
  null,
  null,
);

Future<File> _archive(String path, Map<String, List<int>> files) async {
  if (Platform.environment['PRIME_NATIVE_ZIP_TEST'] == '1') {
    final inputs = await Directory.systemTemp.createTemp('prime-backup-input-');
    final zip = native_zip.ZipFile.open(path);
    try {
      var index = 0;
      for (final entry in files.entries) {
        final input = File('${inputs.path}/${index++}')
          ..writeAsBytesSync(entry.value);
        zip.addFile(entry.key, input.path);
      }
    } finally {
      zip.close();
      await inputs.delete(recursive: true);
    }
    return File(path);
  }
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(
      ArchiveFile.bytes(entry.key, Uint8List.fromList(entry.value)),
    );
  }
  return File(path)..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

List<int> _emptyDatabase(String path) {
  final db = sqlite3.open(path);
  db.dispose();
  return File(path).readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exports committed rows from every live WAL database',
    () async {
      final directory = await Directory.systemTemp.createTemp('prime-wal-');
      App.dataPath = directory.path;
      App.cachePath = '${directory.path}/cache';
      Directory(App.cachePath).createSync();
      final databases = <String, Database>{};
      try {
        for (final name in [
          'history.db',
          'local_favorite.db',
          'read_later.db',
          'reading_statistics.db',
          'cookie.db',
        ]) {
          final db = sqlite3.open('${directory.path}/$name');
          databases[name] = db;
          db.execute('PRAGMA journal_mode = WAL;');
          db.execute('PRAGMA wal_autocheckpoint = 0;');
          db.execute('CREATE TABLE backup_probe (value TEXT);');
          db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
          db.execute(
            "INSERT INTO backup_probe VALUES ('latest-committed-row');",
          );
          expect(
            File('${directory.path}/$name-wal').lengthSync(),
            greaterThan(0),
          );

          // Prove that copying only the main file really loses the latest row.
          final stale = File('${directory.path}/$name.stale');
          stale.writeAsBytesSync(
            File('${directory.path}/$name').readAsBytesSync(),
          );
          final mainOnly = sqlite3.open(stale.path);
          try {
            expect(mainOnly.select('SELECT * FROM backup_probe;'), isEmpty);
          } finally {
            mainOnly.dispose();
          }
        }
        for (final sync in [true, false]) {
          final backup = await exportAppData(sync);
          final extracted = Directory('${App.cachePath}/snapshot-$sync');
          await ArchiveSecurity.extract(backup, extracted);
          for (final name in databases.keys) {
            final snapshot = sqlite3.open('${extracted.path}/$name');
            try {
              expect(
                snapshot.select('PRAGMA integrity_check;').single[0],
                'ok',
              );
              expect(
                snapshot.select('SELECT value FROM backup_probe;').single[0],
                'latest-committed-row',
                reason: '$name (sync=$sync)',
              );
            } finally {
              snapshot.dispose();
            }
          }
        }
      } finally {
        for (final db in databases.values) {
          db.dispose();
        }
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );

  test(
    'imports read later entries and preserves them for old backups',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera-backup-');
      final cache = Directory('${directory.path}/cache')..createSync();
      App.dataPath = directory.path;
      App.cachePath = cache.path;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async {
            return directory.path;
          });

      final manager = ReadLaterManager();
      manager.close();
      await manager.init();
      manager.clear();
      expect(manager.add(_comic()), isTrue);
      final cookies = SingleInstanceCookieJar('${directory.path}/cookie.db');
      final uri = Uri.parse('https://example.test/login');
      cookies.saveFromResponse(uri, [Cookie('session', 'fixture-session')]);
      final cookieBytes = File(cookies.path).readAsBytesSync();
      cookies.deleteAll();

      final databaseBytes = File(
        '${directory.path}/read_later.db',
      ).readAsBytesSync();
      final completeBackup = await _archive(
        '${directory.path}/complete.venera',
        {
          'appdata.json': utf8.encode(
            jsonEncode({
              'settings': {
                'token': 'fixture-token',
                'webdav': [
                  'https://backup.example.test',
                  'fixture-user',
                  'fixture-password',
                ],
              },
              'searchHistory': [],
            }),
          ),
          'history.db': _emptyDatabase('${directory.path}/history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/local_favorite.db',
          ),
          'read_later.db': databaseBytes,
          'cookie.db': cookieBytes,
        },
      );
      manager.clear();
      await importAppData(completeBackup);
      expect(manager.getAll().single.id, 'backup-id');
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
      expect(appdata.settings['token'], 'fixture-token');
      expect(appdata.settings['webdav'][2], 'fixture-password');

      final corruptCookiesBackup = await _archive(
        '${directory.path}/bad-cookie.venera',
        {
          'history.db': _emptyDatabase(
            '${directory.path}/bad-cookie-history.db',
          ),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/bad-cookie-favorites.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'cookie.db': utf8.encode('not a database'),
        },
      );
      await expectLater(
        importAppData(corruptCookiesBackup),
        throwsA(isA<SqliteException>()),
      );
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
      expect(manager.getAll().single.id, 'backup-id');

      if (Platform.environment['PRIME_NATIVE_ZIP_TEST'] == '1') {
        final sourceDir = Directory('${directory.path}/comic_source')
          ..createSync();
        final sourceData = File('${sourceDir.path}/fixture.data');
        sourceData.writeAsStringSync(
          jsonEncode({
            'account': ['fixture-user', 'fixture-password'],
            'nested': {
              'Authorization': 'fixture-auth',
              'refresh_token': 'fixture-refresh',
            },
          }),
        );
        for (final sync in [false, true]) {
          final history = HistoryManager();
          final item = History.fromMap({
            'id': 'wal-history-$sync',
            'type': 42,
            'title': 'Recent history',
            'subtitle': 'Author',
            'cover': '',
            'time': 1700000000000,
            'ep': 1,
            'page': 8,
            'readEpisode': ['1'],
          });
          history.addHistory(item);
          // Keep the writer open: the newest history is still in the WAL.
          expect(
            File('${directory.path}/history.db-wal').lengthSync(),
            greaterThan(0),
          );
          final exported = await exportAppData(sync);
          final extracted = Directory('${cache.path}/export-$sync');
          await ArchiveSecurity.extract(exported, extracted);
          expect(
            File(
              '${extracted.path}/comic_source/fixture.data',
            ).readAsStringSync(),
            sourceData.readAsStringSync(),
          );
          final settings = jsonDecode(
            File('${extracted.path}/appdata.json').readAsStringSync(),
          )['settings'];
          expect(settings['token'], 'fixture-token');
          expect(settings.containsKey('webdav'), !sync);
          final exportedCookies = CookieJarSql('${extracted.path}/cookie.db');
          expect(
            exportedCookies.loadForRequest(uri).single.value,
            'fixture-session',
          );
          exportedCookies.dispose();
          final exportedHistory = sqlite3.open('${extracted.path}/history.db');
          try {
            expect(
              exportedHistory.select('PRAGMA integrity_check;').single[0],
              'ok',
            );
            expect(
              exportedHistory.select('SELECT page FROM history WHERE id = ?;', [
                item.id,
              ]).single[0],
              8,
            );
          } finally {
            exportedHistory.dispose();
          }
          final expectedSourceData = sourceData.readAsStringSync();
          sourceData.writeAsStringSync('{}');
          cookies.deleteAll();
          await importAppData(exported);
          expect(sourceData.readAsStringSync(), expectedSourceData);
          expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
          expect(
            (await HistoryManager().getPage(query: item.id)).items.single.page,
            8,
          );
          await exported.delete();
        }

        const preservedScript = '''
class BackupPreserved extends ComicSource {
  name = 'Backup fixture';
  key = 'backup_preserved';
  version = '1.0.0';
  minAppVersion = '1.0.0';
  comic = {};
  search = {};
}
''';
        final backupFiles = <String, List<int>>{
          'history.db': _emptyDatabase('${directory.path}/source-history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/source-favorites.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({
              'settings': {'token': 'restored-with-warning'},
              'searchHistory': [],
            }),
          ),
          'comic_source/fixture.data': utf8.encode(
            '{"account":["fixture-user","fixture-password"]}',
          ),
          'comic_source/preserved.js': [],
          'comic_source/empty.js': [],
          'comic_source/nested/blank.js': utf8.encode(' \n\t'),
        };
        for (final withManifest in [false, true]) {
          final files = Map<String, List<int>>.from(backupFiles);
          if (withManifest) {
            files['manifest.json'] = utf8.encode(
              jsonEncode({'format': 1, 'files': backupFiles.keys.toList()}),
            );
          }
          final backup = await _archive(
            '${directory.path}/empty-source-$withManifest.venera',
            files,
          );
          final preserved = File('${sourceDir.path}/preserved.js')
            ..writeAsStringSync(preservedScript);
          final skipped = await importAppData(backup);
          expect(
            skipped,
            unorderedEquals([
              'comic_source/preserved.js',
              'comic_source/empty.js',
              'comic_source/nested/blank.js',
            ]),
          );
          expect(preserved.readAsStringSync(), preservedScript);
          expect(ComicSource.find('backup_preserved'), isNotNull);
          expect(File('${sourceDir.path}/empty.js').existsSync(), isFalse);
          expect(
            File('${sourceDir.path}/nested/blank.js').existsSync(),
            isFalse,
          );
          expect(
            jsonDecode(sourceData.readAsStringSync())['account'][1],
            'fixture-password',
          );
          expect(appdata.settings['token'], 'restored-with-warning');
          expect(manager.getAll().single.id, 'backup-id');
          expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
        }

        // Skipping bad scripts cannot bypass manifest or credential validation.
        final missingSource = await _archive(
          '${directory.path}/missing-source.venera',
          {
            ...backupFiles,
            'manifest.json': utf8.encode(
              jsonEncode({
                'format': 1,
                'files': [...backupFiles.keys, 'comic_source/missing.js'],
              }),
            ),
          },
        );
        await expectLater(importAppData(missingSource), throwsFormatException);
        final invalidSourceData = await _archive(
          '${directory.path}/invalid-source-data.venera',
          {
            ...backupFiles,
            'comic_source/fixture.data': utf8.encode('not JSON'),
          },
        );
        await expectLater(
          importAppData(invalidSourceData),
          throwsFormatException,
        );
        final invalidDatabase = await _archive(
          '${directory.path}/invalid-source-database.venera',
          {...backupFiles, 'history.db': utf8.encode('not SQLite')},
        );
        await expectLater(
          importAppData(invalidDatabase),
          throwsA(isA<SqliteException>()),
        );
        expect(appdata.settings['token'], 'restored-with-warning');
        expect(ComicSource.find('backup_preserved'), isNotNull);
        expect(manager.getAll().single.id, 'backup-id');
        ComicSourceManager().remove('backup_preserved');
        await sourceDir.delete(recursive: true);
        JsEngine().dispose();
      }

      final legacyBackup = await _archive('${directory.path}/legacy.venera', {
        'history.db': _emptyDatabase('${directory.path}/legacy-history.db'),
        'local_favorite.db': _emptyDatabase(
          '${directory.path}/legacy-favorite.db',
        ),
        'appdata.json': utf8.encode(
          jsonEncode({'settings': {}, 'searchHistory': []}),
        ),
      });
      await importAppData(legacyBackup);
      expect(manager.getAll().single.id, 'backup-id');
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');

      final oldReadLater = sqlite3.open('${directory.path}/old-read-later.db');
      oldReadLater.execute('''
        CREATE TABLE read_later (
          id TEXT NOT NULL, type INTEGER NOT NULL, title TEXT NOT NULL,
          subtitle TEXT, cover TEXT NOT NULL, source_key TEXT NOT NULL,
          added_time INTEGER NOT NULL, PRIMARY KEY (id, type)
        );
        INSERT INTO read_later VALUES
          ('old-backup', 0, 'Old backup', NULL, 'cover', 'local', 123);
      ''');
      oldReadLater.dispose();
      final legacySchemaBackup = await _archive(
        '${directory.path}/legacy-schema.venera',
        {
          'history.db': _emptyDatabase('${directory.path}/legacy-history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/legacy-favorite.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'read_later.db': File(
            '${directory.path}/old-read-later.db',
          ).readAsBytesSync(),
        },
      );
      await importAppData(legacySchemaBackup);
      expect(manager.getAll().single.id, 'old-backup');
      App.closeComponents();
      await App.initComponents();
      expect(manager.getAll().single.id, 'old-backup');
      expect(manager.add(_comic()), isTrue);
      expect(manager.removeComic(_comic()), isTrue);
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');

      final invalidManifestBackup = await _archive(
        '${directory.path}/invalid-manifest.venera',
        {
          'history.db': _emptyDatabase('${directory.path}/invalid-history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/invalid-favorite.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'manifest.json': utf8.encode(
            jsonEncode({'format': 99, 'files': <String>[]}),
          ),
        },
      );
      await expectLater(
        importAppData(invalidManifestBackup),
        throwsA(isA<FormatException>()),
      );

      // Wait for isolate history reads before disposing the database, then
      // close every component (this also closes App.local, created by the
      // App.initComponents() call above).
      await HistoryManager().closeAfterReads();
      App.closeComponents();
      cookies.dispose();
      SingleInstanceCookieJar.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    },
  );
}
