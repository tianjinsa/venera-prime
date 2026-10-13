import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app.dart';
import 'log.dart';

class CacheCleanupProgress {
  final int checked;
  final int total;
  final int deleted;
  final int freedBytes;

  const CacheCleanupProgress(
    this.checked,
    this.total,
    this.deleted,
    this.freedBytes,
  );
}

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';
  static CacheManager? instance;

  final String _path;
  final Database _db;
  final DateTime Function() _now;
  late Future<void> _tail;
  late final Future<void> _reconciling;
  Future<CacheCleanupProgress>? _cleaning;
  final _unmanaged = <String, int>{};
  final _size = ValueNotifier<int>(0);
  int get _currentSize => _size.value;
  set _currentSize(int value) => _size.value = value;
  int _limitSize = 2 * 1024 * 1024 * 1024;
  int _retentionDays = 7;
  int _sequence = 0;
  bool _closed = false;
  int dir = 0;

  int get currentSize => _currentSize;
  ValueListenable<int> get sizeListenable => _size;
  int get retentionDays => _retentionDays;

  /// Completes when startup has reconciled legacy sizes and orphan files.
  Future<void> get ready => _reconciling;

  factory CacheManager() => instance ??= CacheManager.open(
    directory: cachePath,
    databasePath: '${App.dataPath}/cache.db',
  );

  /// Separate paths and clock allow isolated tests without touching app data.
  CacheManager.open({
    required String directory,
    required String databasePath,
    DateTime Function()? now,
  }) : _path = directory,
       _db = sqlite3.open(databasePath),
       _now = now ?? DateTime.now {
    Directory(_path).createSync(recursive: true);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL, dir TEXT NOT NULL, name TEXT NOT NULL,
        expires INTEGER NOT NULL, type TEXT,
        last_access INTEGER, size INTEGER, ttl_ms INTEGER
      )
    ''');
    final columns = _db
        .select('PRAGMA table_info(cache)')
        .map((r) => r['name'])
        .toSet();
    for (final name in ['last_access', 'size', 'ttl_ms']) {
      if (!columns.contains(name)) {
        _db.execute('ALTER TABLE cache ADD COLUMN $name INTEGER');
      }
    }
    // The old implementation extended expires by seven days on every hit.
    _db.execute(
      'UPDATE cache SET last_access = expires - ? WHERE last_access IS NULL',
      [const Duration(days: 7).inMilliseconds],
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS cache_last_access ON cache(last_access)',
    );
    _db.execute('CREATE INDEX IF NOT EXISTS cache_file ON cache(dir, name)');
    _currentSize =
        _db.select('SELECT COALESCE(SUM(size), 0) FROM cache').first[0] as int;
    _tail = Future.value();
    _reconciling = _reconcile();
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('CacheManager is closed'));
    final operation = _tail.then((_) => action());
    // A failed operation must not poison subsequent reads or maintenance.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  File _file(Row row) => File('$_path/${row['dir']}/${row['name']}');
  Row? _row(String key) =>
      _db.select('SELECT * FROM cache WHERE key = ?', [key]).firstOrNull;

  Future<void> _reconcile() async {
    final rows = _db.select('SELECT key, dir, name FROM cache').toList();
    for (final candidate in rows) {
      // Yield the queue after each file so a first image only waits for one
      // stat, rather than the entire cache tree. Re-read identity because a
      // foreground write/delete may have replaced this snapshot entry.
      await _enqueue(() async {
        final row = _row(candidate['key'] as String);
        if (row == null ||
            row['dir'] != candidate['dir'] ||
            row['name'] != candidate['name']) {
          return;
        }
        final file = _file(row);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          await _remove(row);
          return;
        }
        if (row['size'] != stat.size) {
          _db.execute('UPDATE cache SET size = ? WHERE key = ?', [
            stat.size,
            row['key'],
          ]);
          _currentSize += stat.size - ((row['size'] as int?) ?? 0);
        }
      });
    }
    await for (final entity in Directory(
      _path,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      await _enqueue(() async {
        final segments = entity.uri.pathSegments;
        final name = segments.last;
        final directory = segments.elementAtOrNull(segments.length - 2) ?? '';
        final managed = _db.select(
          'SELECT 1 FROM cache WHERE dir = ? AND name = ? LIMIT 1',
          [directory, name],
        );
        if (managed.isNotEmpty || _unmanaged.containsKey(entity.path)) return;
        // A write holds the same queue through publication. A staging file
        // observed by list() has either become managed or disappeared now.
        final stat = await entity.stat();
        if (stat.type == FileSystemEntityType.file) {
          _unmanaged[entity.path] = stat.size;
          _currentSize += stat.size;
        }
      });
    }
  }

  void setLimitSize(int size) {
    if (size < 0) throw ArgumentError.value(size, 'size');
    _limitSize = size * 1024 * 1024;
  }

  /// Zero disables age-based eviction; the separate size limit still applies.
  void setRetentionDays(int days) {
    if (![0, 1, 3, 7, 30].contains(days)) {
      throw ArgumentError.value(days, 'days');
    }
    _retentionDays = days;
  }

  int? _ttl(Row row) =>
      row['ttl_ms'] as int? ??
      (_retentionDays == 0
          ? null
          : Duration(days: _retentionDays).inMilliseconds);

  bool _expired(Row row, int now) {
    final ttl = _ttl(row);
    return ttl != null && now - (row['last_access'] as int) >= ttl;
  }

  Future<void> _remove(Row row) async {
    final file = _file(row);
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
    _db.execute('DELETE FROM cache WHERE key = ?', [row['key']]);
    _currentSize -= row['size'] as int? ?? 0;
  }

  /// Publish a complete file before replacing the previous entry. All reads,
  /// writes and individual evictions share a queue so files are never removed
  /// while readCache/withCacheFile is using them.
  Future<void> writeCache(String key, List<int> data, [int? duration]) async {
    await _enqueue(() async {
      final previous = _row(key);
      dir = (dir + 1) % 100;
      final prefix =
          '${md5.convert(utf8.encode(key))}.${_now().microsecondsSinceEpoch}';
      late String name;
      late File file;
      late File staging;
      do {
        name = '$prefix.${_sequence++}';
        file = File('$_path/$dir/$name');
        staging = File('${file.path}.tmp');
      } while ((previous != null && _file(previous).path == file.path) ||
          await file.exists() ||
          await staging.exists());
      try {
        await staging.create(recursive: true);
        await staging.writeAsBytes(data);
        await staging.rename(file.path);
        if (previous != null) await _remove(previous);
        final now = _now().millisecondsSinceEpoch;
        final ttl = duration ?? Duration(days: _retentionDays).inMilliseconds;
        _db.execute(
          '''
          INSERT INTO cache (key, dir, name, expires, last_access, size, ttl_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
          [key, '$dir', name, now + ttl, now, data.length, duration],
        );
        _currentSize += data.length;
      } catch (_) {
        if (await staging.exists()) await staging.delete();
        if (await file.exists()) await file.delete();
        rethrow;
      }
    });
    checkCacheIfRequired();
  }

  Future<File?> _find(String key) async {
    final row = _row(key);
    if (row == null) return null;
    final now = _now().millisecondsSinceEpoch;
    if (_expired(row, now) || !await _file(row).exists()) {
      await _remove(row);
      return null;
    }
    final ttl = _ttl(row);
    _db.execute('UPDATE cache SET last_access = ?, expires = ? WHERE key = ?', [
      now,
      now + (ttl ?? 0),
      key,
    ]);
    return _file(row);
  }

  /// Prefer readCache or withCacheFile: their leases include the entire read.
  Future<File?> findCache(String key) => _enqueue(() => _find(key));

  Future<T?> withCacheFile<T>(String key, Future<T> Function(File file) read) =>
      _enqueue(() async {
        final file = await _find(key);
        return file == null ? null : await read(file);
      });

  Future<Uint8List?> readCache(String key) =>
      withCacheFile(key, (file) => file.readAsBytes());

  void checkCacheIfRequired() {
    if (_currentSize > _limitSize) {
      unawaited(
        checkCache().catchError((Object error, StackTrace stack) {
          Log.error('Cache cleanup', error, stack);
          return const CacheCleanupProgress(0, 0, 0, 0);
        }),
      );
    }
  }

  /// Always removes expired entries, even below the size limit. Each candidate
  /// is rechecked under the queue so reads can refresh its last-use timestamp.
  Future<CacheCleanupProgress> checkCache({
    void Function(CacheCleanupProgress progress)? onProgress,
  }) {
    if (_cleaning != null) return _cleaning!;
    final task = BackgroundTasks.instance.start(
      'cache-cleanup',
      'Cache cleanup',
    );
    final future =
        _checkCache((progress) {
          task.update(completed: progress.checked, total: progress.total);
          onProgress?.call(progress);
        }, onError: (error) => task.addError(error.toString())).then(
          (progress) {
            task.finish();
            return progress;
          },
          onError: (Object error, StackTrace stack) {
            task.fail(error);
            Error.throwWithStackTrace(error, stack);
          },
        );
    _cleaning = future;
    return future.whenComplete(() => _cleaning = null);
  }

  Future<CacheCleanupProgress> _checkCache(
    void Function(CacheCleanupProgress)? onProgress, {
    required void Function(Object error) onError,
  }) async {
    // Wait outside the operation queue: foreground reads/writes remain free
    // to run while reconciliation discovers files and corrects accounting.
    await _reconciling;
    final rows = await _enqueue(
      () async =>
          _db.select('SELECT * FROM cache ORDER BY last_access ASC').toList(),
    );
    final unmanaged = Map.of(_unmanaged);
    var checked = 0;
    var deleted = 0;
    var freed = 0;
    final total = rows.length + unmanaged.length;
    CacheCleanupProgress progress() =>
        CacheCleanupProgress(checked, total, deleted, freed);
    onProgress?.call(progress());
    for (final entry in unmanaged.entries) {
      await _enqueue(() async {
        // A manual clear may have removed this entry after the snapshot.
        // Only the operation that still owns its accounting may subtract it.
        final size = _unmanaged[entry.key];
        if (size == null) return;
        final file = File(entry.key);
        try {
          if (await file.exists()) await file.delete();
          _unmanaged.remove(entry.key);
          _currentSize -= size;
          freed += size;
          deleted++;
        } on FileSystemException catch (error, stack) {
          onError(error);
          Log.error('Cache cleanup', error, stack);
        }
      });
      checked++;
      onProgress?.call(progress());
    }
    for (final candidate in rows) {
      await _enqueue(() async {
        final row = _row(candidate['key'] as String);
        if (row == null || row['name'] != candidate['name']) return;
        final expired = _expired(row, _now().millisecondsSinceEpoch);
        final overLimit =
            _currentSize > _limitSize &&
            row['last_access'] == candidate['last_access'];
        if (!expired && !overLimit) return;
        try {
          await _remove(row);
          freed += row['size'] as int? ?? 0;
          deleted++;
        } on FileSystemException catch (error, stack) {
          onError(error);
          Log.error('Cache cleanup', error, stack);
        }
      });
      checked++;
      onProgress?.call(progress());
    }
    return progress();
  }

  Future<void> delete(String key) => _enqueue(() async {
    final row = _row(key);
    if (row != null) await _remove(row);
  });

  /// Clear managed cache files without deleting directories or local comics.
  Future<void> clear() async {
    await _reconciling;
    return _enqueue(() async {
      for (final row in _db.select('SELECT * FROM cache')) {
        await _remove(row);
      }
      for (final entry in _unmanaged.entries.toList()) {
        final file = File(entry.key);
        if (await file.exists()) await file.delete();
        _unmanaged.remove(entry.key);
        _currentSize -= entry.value;
      }
    });
  }

  Future<void> close() async {
    if (_closed) return;
    await _reconciling;
    await _cleaning;
    _closed = true;
    await _tail;
    _db.dispose();
    _size.dispose();
  }
}
