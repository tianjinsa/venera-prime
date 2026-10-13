import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/background_tasks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CacheManager cache;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('prime-cache-policy-');
    now = DateTime.utc(2026, 1, 1);
    cache = CacheManager.open(
      directory: '${root.path}/images',
      databasePath: '${root.path}/cache.db',
      now: () => now,
    );
    await cache.ready;
  });
  tearDown(() async {
    await cache.close();
    await root.delete(recursive: true);
  });

  test(
    'unused entries expire below capacity, successful reads renew retention',
    () async {
      cache.setRetentionDays(3);
      await cache.writeCache('used', [1, 2, 3]);
      await cache.writeCache('idle', [4, 5]);
      now = now.add(const Duration(days: 2));
      expect(await cache.readCache('used'), [1, 2, 3]);
      now = now.add(const Duration(days: 1));
      final result = await cache.checkCache();
      expect(result.deleted, 1);
      expect(result.freedBytes, 2);
      expect(cache.currentSize, 3);
      expect(await cache.readCache('idle'), isNull);
      expect(await cache.readCache('used'), [1, 2, 3]);
    },
  );

  test(
    'changing retention applies to existing entries; Never still honors size limit',
    () async {
      await cache.writeCache('image', [1, 2, 3]);
      cache.setRetentionDays(0);
      now = now.add(const Duration(days: 365));
      expect((await cache.checkCache()).deleted, 0);
      expect(await cache.readCache('image'), [1, 2, 3]);
      now = now.add(const Duration(days: 4));
      cache.setRetentionDays(3);
      expect((await cache.checkCache()).deleted, 1);
      cache.setRetentionDays(0);
      await cache.writeCache('limited', [4, 5]);
      cache.setLimitSize(0);
      await cache.checkCache();
      expect(cache.currentSize, 0);
      expect(await cache.readCache('limited'), isNull);
    },
  );

  test(
    'concurrent same-key writes and deletes preserve complete data and exact size',
    () async {
      await Future.wait([
        cache.writeCache('same', List.filled(100, 1)),
        cache.writeCache('same', List.filled(200, 2)),
        cache.delete('same'),
        cache.writeCache('same', List.filled(50, 3)),
        cache.writeCache('other', [9, 8, 7]),
      ]);
      expect(await cache.readCache('same'), List.filled(50, 3));
      expect(cache.currentSize, 53);
      final files = await Directory(
        '${root.path}/images',
      ).list(recursive: true).where((e) => e is File).toList();
      expect(files, hasLength(2));
      expect(files.any((f) => f.path.endsWith('.tmp')), isFalse);
      await cache.clear();
      expect(cache.currentSize, 0);
      expect(await cache.readCache('same'), isNull);
      await cache.writeCache('after-clear', [4]);
      expect(cache.currentSize, 1);
    },
  );

  test('an active file read completes before cleanup can remove it', () async {
    await cache.writeCache('in-use', [1, 2, 3]);
    final entered = Completer<void>();
    final finish = Completer<void>();
    final read = cache.withCacheFile('in-use', (file) async {
      entered.complete();
      await finish.future;
      return file.readAsBytes();
    });
    await entered.future;
    cache.setLimitSize(0);
    var cleanupFinished = false;
    final cleanup = cache.checkCache().then((value) {
      cleanupFinished = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(cleanupFinished, isFalse);
    finish.complete();
    expect(await read, [1, 2, 3]);
    await cleanup;
    expect(cache.currentSize, 0);
  });

  test('cleanup rechecks a candidate refreshed after its snapshot', () async {
    await cache.writeCache('old', [1]);
    await cache.writeCache('newly-used', [2]);
    cache.setLimitSize(0);
    Future<List<int>?>? read;
    final result = await cache.checkCache(
      onProgress: (progress) {
        if (progress.checked == 0) {
          now = now.add(const Duration(minutes: 1));
          read = cache.readCache('newly-used');
        }
      },
    );
    expect(await read, [2]);
    expect(result.deleted, 1);
    expect(cache.currentSize, 1);
  });

  test(
    'missing files decrement recorded size without an infinite capacity loop',
    () async {
      await cache.writeCache('external-removal', [1, 2, 3, 4]);
      final file = await cache.findCache('external-removal');
      await file!.delete();
      expect(await cache.readCache('external-removal'), isNull);
      expect(cache.currentSize, 0);
      cache.setLimitSize(0);
      await cache.checkCache();
      expect(cache.currentSize, 0);
    },
  );

  test(
    'startup reconciles legacy expiry, missing records and unmanaged files',
    () async {
      await cache.close();
      final db = sqlite3.open('${root.path}/legacy.db');
      db.execute(
        'CREATE TABLE cache (key TEXT PRIMARY KEY, dir TEXT, name TEXT, expires INTEGER, type TEXT)',
      );
      await Directory('${root.path}/legacy/1').create(recursive: true);
      await File('${root.path}/legacy/1/kept').writeAsBytes([1, 2]);
      await File('${root.path}/legacy/1/expired').writeAsBytes([3, 4, 5]);
      await File('${root.path}/legacy/1/unmanaged').writeAsBytes([6]);
      await File('${root.path}/downloaded-comic').writeAsBytes([9]);
      final expires = now.add(const Duration(days: 6)).millisecondsSinceEpoch;
      db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)', [
        'kept',
        '1',
        'kept',
        expires,
      ]);
      db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)', [
        'expired',
        '1',
        'expired',
        expires - const Duration(days: 7).inMilliseconds,
      ]);
      db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)', [
        'missing',
        '1',
        'missing',
        expires,
      ]);
      db.dispose();
      cache = CacheManager.open(
        directory: '${root.path}/legacy',
        databasePath: '${root.path}/legacy.db',
        now: () => now,
      );
      // Queue a write before startup scanning finishes; it must not be mistaken
      // for an unmanaged file or lost when initial size is established.
      await cache.writeCache('queued-write', [7, 8]);
      await cache.ready;
      expect(cache.currentSize, 8);
      final result = await cache.checkCache();
      expect(result.deleted, 2);
      expect(result.freedBytes, 4);
      expect(cache.currentSize, 4);
      expect(await cache.readCache('kept'), [1, 2]);
      expect(await cache.readCache('queued-write'), [7, 8]);
      expect(await cache.readCache('missing'), isNull);
      await cache.clear();
      expect(await File('${root.path}/downloaded-comic').readAsBytes(), [9]);
    },
  );

  test(
    'read errors do not poison later operations or clear a newer write',
    () async {
      await cache.writeCache('image', [1]);
      await expectLater(
        cache.withCacheFile<void>('image', (_) async {
          throw StateError('simulated reader failure');
        }),
        throwsStateError,
      );
      await cache.writeCache('image', [2, 3]);
      expect(await cache.readCache('image'), [2, 3]);
      expect(cache.currentSize, 2);
    },
  );

  test(
    'reopening with the same clock cannot overwrite its own backing file',
    () async {
      await cache.writeCache('same', [1, 2]);
      await cache.close();
      cache = CacheManager.open(
        directory: '${root.path}/images',
        databasePath: '${root.path}/cache.db',
        now: () => now,
      );
      await cache.writeCache('same', [3, 4, 5]);
      expect(await cache.readCache('same'), [3, 4, 5]);
      expect(cache.currentSize, 3);
    },
  );

  test('a failed progress consumer does not disable future cleanup', () async {
    await cache.writeCache('image', [1, 2]);
    now = now.add(const Duration(days: 8));
    await expectLater(
      cache.checkCache(
        onProgress: (_) {
          throw StateError('progress consumer failed');
        },
      ),
      throwsStateError,
    );
    expect((await cache.checkCache()).deleted, 1);
    expect(cache.currentSize, 0);
  });

  test(
    'manual clear during an unmanaged-file cleanup cannot subtract size twice',
    () async {
      await cache.close();
      await File('${root.path}/images/orphan').writeAsBytes([1, 2, 3, 4]);
      cache = CacheManager.open(
        directory: '${root.path}/images',
        databasePath: '${root.path}/cache.db',
        now: () => now,
      );
      await cache.ready;
      expect(cache.currentSize, 4);
      Future<void>? clearing;
      await cache.checkCache(
        onProgress: (progress) {
          if (progress.checked == 0) clearing = cache.clear();
        },
      );
      await clearing;
      expect(cache.currentSize, 0);
      await cache.writeCache('after-clear', [9]);
      expect(cache.currentSize, 1);
    },
  );

  test(
    'failed filesystem eviction stays counted and produces a failed task',
    () async {
      await cache.writeCache('permission-denied', [1, 2, 3]);
      final file = await cache.findCache('permission-denied');
      final directory = file!.parent.path;
      final chmod = await Process.run('chmod', ['500', directory]);
      expect(chmod.exitCode, 0);
      try {
        now = now.add(const Duration(days: 8));
        await cache.checkCache();
        final failed = BackgroundTasks.instance.latest('cache-cleanup')!;
        expect(cache.currentSize, 3);
        expect(await file.exists(), isTrue);
        expect(failed.status, BackgroundTaskStatus.failed);
        expect(failed.errors, isNotEmpty);
      } finally {
        await Process.run('chmod', ['700', directory]);
      }
      await cache.checkCache();
      expect(cache.currentSize, 0);
      expect(
        BackgroundTasks.instance.latest('cache-cleanup')!.status,
        BackgroundTaskStatus.completed,
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'manual clear and tracked cleanup both wait for an active read',
    () async {
      await cache.writeCache('reading', [1, 2, 3]);
      final entered = Completer<void>();
      final release = Completer<void>();
      final reading = cache.withCacheFile('reading', (file) async {
        entered.complete();
        await release.future;
        return file.readAsBytes();
      });
      await entered.future;
      final clearing = cache.clear();
      final firstCleanup = cache.checkCache();
      final secondCleanup = cache.checkCache();
      final task = BackgroundTasks.instance.latest('cache-cleanup')!;
      expect(task.isRunning, isTrue);
      expect(task.cancellable, isFalse);
      task.requestCancel();
      expect(task.cancelRequested, isFalse);
      release.complete();
      expect(await reading, [1, 2, 3]);
      await clearing;
      expect(identical(await firstCleanup, await secondCleanup), isTrue);
      expect(cache.currentSize, 0);
      expect(task.status, BackgroundTaskStatus.completed);
      await cache.writeCache('after', [4, 5]);
      expect(await cache.readCache('after'), [4, 5]);
      expect(cache.currentSize, 2);
    },
  );

  test(
    'legacy startup allows foreground work before reconciliation with exact nonnegative accounting',
    () async {
      await cache.close();
      final directory = Directory('${root.path}/legacy-startup')..createSync();
      final databasePath = '${root.path}/legacy-startup.db';
      final db = sqlite3.open(databasePath);
      db.execute(
        'CREATE TABLE cache (key TEXT PRIMARY KEY, dir TEXT, name TEXT, expires INTEGER, type TEXT)',
      );
      db.execute('BEGIN');
      final expires = now.add(const Duration(days: 7)).millisecondsSinceEpoch;
      for (var shard = 0; shard < 10; shard++) {
        Directory('${directory.path}/$shard').createSync();
      }
      for (var i = 0; i < 200; i++) {
        File(
          '${directory.path}/${i % 10}/image$i',
        ).writeAsBytesSync(List.filled(i % 5 + 1, i));
        db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)', [
          'image$i',
          '${i % 10}',
          'image$i',
          expires,
        ]);
      }
      db.execute('COMMIT');
      db.dispose();
      File('${directory.path}/orphan').writeAsBytesSync(List.filled(9, 0));
      cache = CacheManager.open(
        directory: directory.path,
        databasePath: databasePath,
        now: () => now,
      );
      var reconciled = false;
      final sizes = <int>[];
      cache.sizeListenable.addListener(() => sizes.add(cache.currentSize));
      final ready = cache.ready.then((_) => reconciled = true);
      // Delete one entry the scan may already have measured and one unmeasured
      // legacy entry. Replace another size=NULL entry before the scan reaches it.
      final deleteMeasured = cache.delete('image0');
      final deleteUnmeasured = cache.delete('image10');
      final replacement = cache.writeCache('image11', List.filled(100, 7));
      final read = cache.readCache('image12');
      final fresh = cache.writeCache('fresh', List.filled(30, 8));
      expect(await read, [12, 12, 12]);
      expect(reconciled, isFalse);
      await Future.wait([deleteMeasured, deleteUnmeasured, replacement, fresh]);
      await ready;
      expect(sizes.every((size) => size >= 0), isTrue);
      expect(cache.currentSize, 735); // 600 - 1 - 1 - 2 + 100 + 30 + 9.
      expect(await cache.readCache('image0'), isNull);
      expect(await cache.readCache('image10'), isNull);
      expect(await cache.readCache('image11'), List.filled(100, 7));
      var physicalSize = 0;
      await for (final file in directory.list(recursive: true)) {
        if (file is File) physicalSize += await file.length();
      }
      expect(cache.currentSize, physicalSize);
      await cache.checkCache();
      expect(cache.currentSize, 726); // The unmanaged file is evicted once.
    },
  );
}
