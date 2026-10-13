import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

void main() {
  late Directory root;
  late Directory local;
  final manager = LocalManager();

  Future<LocalComic> createComic(
    String id, {
    bool managed = true,
    String? path,
  }) async {
    final directory = Directory(path ?? '${local.path}/$id')
      ..createSync(recursive: true);
    File('${directory.path}/1.jpg').writeAsBytesSync([1, 2, 3]);
    final comic = LocalComic(
      id: id,
      title: id,
      subtitle: '',
      tags: const [],
      directory: path ?? id,
      chapters: null,
      cover: '1.jpg',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime.now(),
      managedByApp: managed,
    );
    await manager.add(comic);
    return comic;
  }

  Future<void> waitFor(Iterable<BackgroundTask> tasks) async {
    for (var i = 0; i < 300 && tasks.any((task) => task.isRunning); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(tasks.any((task) => task.isRunning), isFalse);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-cleanup-tasks-');
    local = Directory('${root.path}/local')..createSync();
    App.dataPath = root.path;
    File('${root.path}/local_path').writeAsStringSync(local.path);
    manager.close();
    await manager.init();
    BackgroundTasks.instance.clearFinished();
  });
  tearDown(() async {
    await waitFor(BackgroundTasks.instance.tasks);
    manager.close();
    await root.delete(recursive: true);
  });

  test(
    'simultaneous deletion batches retain independent jobs and clean all directories',
    () async {
      final first = await createComic('first');
      final second = await createComic('second');
      final third = await createComic('third');
      manager.batchDeleteComics([first, second], true, false);
      manager.batchDeleteComics([third], true, false);
      final tasks = BackgroundTasks.instance.tasks
          .where((task) => task.key.startsWith('local-delete:'))
          .toList();
      expect(tasks, hasLength(2));
      expect(tasks.map((task) => task.key).toSet(), hasLength(2));
      expect(tasks.every((task) => task.isRunning), isTrue);
      await waitFor(tasks);
      expect(
        tasks.every((task) => task.status == BackgroundTaskStatus.completed),
        isTrue,
      );
      expect(tasks.map((task) => task.total), unorderedEquals([2, 1]));
      expect(tasks.every((task) => task.completed == task.total), isTrue);
      for (final comic in [first, second, third]) {
        expect(Directory(comic.baseDir).existsSync(), isFalse);
      }
    },
  );

  test(
    'worker refuses a substituted symlink and exposes its error in the task',
    () async {
      final comic = await createComic('replaced');
      final outside = Directory('${root.path}/outside')..createSync();
      final sentinel = File('${outside.path}/keep.txt')
        ..writeAsStringSync('keep');
      manager.batchDeleteComics([comic], true, false);
      // Substitute the checked directory before the scheduled worker starts.
      Directory(comic.baseDir).renameSync('${root.path}/original');
      Link(comic.baseDir).createSync(outside.path);
      final task = BackgroundTasks.instance.tasks.single;
      await waitFor([task]);
      expect(task.status, BackgroundTaskStatus.failed);
      expect(task.errors.single, contains('Refusing to delete'));
      expect(sentinel.readAsStringSync(), 'keep');
      expect(Directory('${root.path}/original').existsSync(), isTrue);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks may require privileges on Windows.'
        : false,
  );

  test(
    'unmanaged and outside-root records never schedule file deletion',
    () async {
      final unmanaged = await createComic('imported', managed: false);
      final outside = await createComic(
        'outside',
        path: '${root.path}/outside',
      );
      manager.batchDeleteComics([unmanaged, outside], true, false);
      expect(BackgroundTasks.instance.tasks, isEmpty);
      expect(Directory(unmanaged.baseDir).existsSync(), isTrue);
      expect(Directory(outside.baseDir).existsSync(), isTrue);
    },
  );
}
