import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';

class _Source implements ComicSource {
  @override
  final String key = 'background-download-fixture';
  final started = Completer<void>();
  final response = Completer<Res<ComicDetails>>();
  @override
  LoadComicFunc get loadComicInfo => (_) {
    if (!started.isCompleted) started.complete();
    return response.future;
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Source source;
  final manager = LocalManager();

  ComicDetails comic() => ComicDetails.fromJson({
    'comicId': 'fixture',
    'sourceKey': source.key,
    'title': 'Fixture',
    'cover': '',
    'tags': <String, dynamic>{},
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('background-download-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    final local = Directory('${root.path}/local')..createSync();
    File('${root.path}/local_path').writeAsStringSync(local.path);
    manager.close();
    manager.downloadingTasks.clear();
    await manager.init();
    source = _Source();
    ComicSourceManager().add(source);
  });
  tearDown(() async {
    for (final task in List.of(manager.downloadingTasks)) {
      task.cancel();
    }
    if (!source.response.isCompleted) source.response.complete(Res(comic()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await manager.saveCurrentDownloadingTasks();
    manager.close();
    ComicSourceManager().remove(source.key);
    await root.delete(recursive: true);
  });

  test(
    'queue task stays active when paused and cancels through task center',
    () async {
      final download = ImagesDownloadTask(
        source: source,
        comicId: 'fixture',
        comicTitle: 'Fixture',
      );
      manager.addTask(download);
      await source.started.future;
      final tracked = BackgroundTasks.instance.latest(
        download.backgroundTaskKey,
      )!;
      expect(tracked.isRunning, isTrue);
      download.pause();
      expect(tracked.isRunning, isTrue);
      expect(tracked.message, 'Paused');
      tracked.requestCancel();
      source.response.complete(Res(comic()));
      for (var i = 0; i < 50 && tracked.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(tracked.status, BackgroundTaskStatus.cancelled);
      expect(tracked.onCancel, isNull);
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'direct resume reports errors and retry creates a new tracked attempt',
    () async {
      final download = ImagesDownloadTask(
        source: source,
        comicId: 'fixture',
        comic: comic(),
      );
      download.path =
          root.path; // Outside the configured managed comic storage.
      Future<BackgroundTask> attempt() async {
        download.resume();
        for (var i = 0; i < 50 && !download.isError; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(download.isError, isTrue);
        final tracked = BackgroundTasks.instance.latest(
          download.backgroundTaskKey,
        )!;
        expect(tracked.status, BackgroundTaskStatus.failed);
        expect(tracked.onCancel, isNull);
        expect(tracked.errors, isNotEmpty);
        return tracked;
      }

      final first = await attempt();
      final retry = await attempt();
      expect(retry.id, greaterThan(first.id));
      download.dispose();
    },
  );

  test(
    'restored download queue appears without starting network requests',
    () async {
      manager.downloadingTasks.add(
        ImagesDownloadTask(source: source, comicId: 'restored', comic: comic()),
      );
      await manager.saveCurrentDownloadingTasks();
      manager.downloadingTasks.clear();
      manager.restoreDownloadingTasks();
      final restored = manager.downloadingTasks.single;
      final tracked = BackgroundTasks.instance.latest(
        restored.backgroundTaskKey,
      )!;
      expect(tracked.isRunning, isTrue);
      expect(tracked.message, 'Queued');
      expect(restored.isPaused, isTrue);
      expect(source.started.isCompleted, isFalse);
    },
  );
}
