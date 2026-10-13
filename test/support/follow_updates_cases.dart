import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

import 'comic_image_fixture.dart';

class _CountingFavorites implements LocalFavoritesManager {
  _CountingFavorites(this.delegate);
  final LocalFavoritesManager delegate;
  int fullReads = 0;
  int bulkMarks = 0;
  int singleMarks = 0;

  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    fullReads++;
    return delegate.getComicsWithUpdatesInfo(folder);
  }

  @override
  void markAllAsRead() {
    bulkMarks++;
    delegate.markAllAsRead();
  }

  @override
  void markAsRead(String id, ComicType type) {
    singleMarks++;
    delegate.markAsRead(id, type);
  }

  @override
  List<String> get folderNames => delegate.folderNames;
  @override
  bool get isInitialized => delegate.isInitialized;
  @override
  bool isExist(String id, ComicType type) => delegate.isExist(id, type);
  @override
  int count(String folder) => delegate.count(folder);
  @override
  int countUpdates(String folder) => delegate.countUpdates(folder);
  @override
  void addListener(VoidCallback listener) => delegate.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      delegate.removeListener(listener);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WaitingSync extends ChangeNotifier implements DataSync {
  bool downloading = true;
  final resumed = Completer<void>();

  @override
  bool get isDownloading {
    if (!downloading && !resumed.isCompleted) resumed.complete();
    return downloading;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements ComicSource {
  @override
  final String key;
  _Source(this.key);
  @override
  String get name => 'Follow update fixture';
  @override
  bool get enableTagsTranslate => false;
  String? timestamp = '2026-10-07';
  List<String> chapterIds = ['old'];
  int calls = 0;
  Completer<void>? gate;
  final started = Completer<void>();
  String cover = '';
  String? errorMessage;

  @override
  LoadComicFunc get loadComicInfo => (id) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await gate?.future;
    if (errorMessage != null) return Res.error(errorMessage!);
    return Res(
      ComicDetails.fromJson({
        'title': 'Follow update fixture',
        'cover': cover,
        'tags': <String, dynamic>{},
        'sourceKey': key,
        'comicId': id,
        'updateTime': timestamp,
        'chapters': {for (final chapter in chapterIds) chapter: chapter},
      }),
    );
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void registerFollowUpdatesTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  var sequence = 0;
  const folder = 'Follow update fixture';
  final manager = LocalFavoritesManager();
  late Directory root;
  late _Source source;
  late Map<String, dynamic> snapshot;
  late ComicImageFixture images;

  Future<void> setup(WidgetTester tester) async {
    snapshot = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(appdata.toJson())),
    );
    root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('prime-follow-tests-'),
    ))!;
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    Directory(App.cachePath).createSync();
    // Never load the device owner's application settings or use their folders.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    for (final method in [
      'getApplicationSupportPath',
      'getApplicationDocumentsPath',
      'getApplicationCachePath',
      'getTemporaryPath',
      'getExternalStoragePath',
    ]) {
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.path_provider_android.PathProviderApi.$method',
        (_) async => const StandardMessageCodec().encodeMessage([root.path]),
      );
    }
    final local = Directory('${root.path}/local')..createSync();
    File('${root.path}/local_path').writeAsStringSync(local.path);
    appdata.settings['webdav'] = [];
    appdata.settings['blockedWords'] = [];
    appdata.settings['language'] = 'en-US';
    appdata.settings['followUpdatesFolder'] = null;
    LocalFavoritesManager.cache = manager;
    manager.close();
    await tester.runAsync(() => manager.init());
    manager.createFolder(folder);
    manager.prepareTableForFollowUpdates(folder, false);
    source = (await tester.runAsync(
      () async => _Source('follow-update-fixture-${sequence++}'),
    ))!;
    source.cover = 'https://example.invalid/${source.key}.png';
    ComicSourceManager().add(source);
    appdata.settings['followUpdatesFolder'] = folder;
    manager.addComic(
      folder,
      FavoriteItem(
        id: '1',
        name: 'Follow update fixture',
        coverPath: source.cover,
        author: '',
        type: ComicType.fromKey(source.key),
        tags: [],
      ),
      null,
      '2026-10-6',
    );
    images = ComicImageFixture()
      ..cache(manager.getComicsWithUpdatesInfo(folder));
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    images.dispose();
    LocalFavoritesManager.cache = manager;
    manager.close();
    HistoryManager().close();
    LocalManager().close();
    appdata.restoreMemorySnapshot(snapshot);
    await tester.runAsync(() => root.delete(recursive: true));
  }

  Future<UpdateProgress> check(
    WidgetTester tester, {
    bool baseline = false,
  }) async => (await tester.runAsync(
    () => updateFolder(folder, true, markNewUpdates: !baseline).toList(),
  ))!.last;

  Future<void> showPage(WidgetTester tester) async {
    images.cache(manager.getComicsWithUpdatesInfo(folder));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => WindowFrame(child!),
        home: const FollowUpdatesPage(),
      ),
    );
    DataSync();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  Future<void> leavePage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => WindowFrame(child!),
        home: const SizedBox(),
      ),
    );
  }

  Future<void> releaseCheck(WidgetTester tester, BackgroundTask task) async {
    source.gate!.complete();
    for (var i = 0; i < 300 && task.isRunning; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(task.isRunning, isFalse);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'manual follow check continues after closing its dialog and page',
    (tester) async {
      await setup(tester);
      try {
        source.gate = Completer<void>();
        await showPage(tester);
        final dynamic page = tester.state(find.byType(FollowUpdatesPage));
        page.checkNow();
        await tester.pump();
        await tester.runAsync(() => source.started.future);
        final task = BackgroundTasks.instance.latest('follow-updates:$folder')!;
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const Key('background-task-continue')));
        await tester.pumpAndSettle();
        expect(find.byType(TaskStatusText), findsOneWidget);
        expect(find.text('Running in background'.tl), findsOneWidget);
        await leavePage(tester);
        expect(task.isRunning, isTrue);
        await releaseCheck(tester, task);
        expect(task.status, BackgroundTaskStatus.completed);
        expect(manager.countUpdates(folder), 1);
        await showPage(tester);
        expect(find.textContaining('Last completed:'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await cleanup(tester);
      }
    },
  );

  for (final cancel in [false, true]) {
    testWidgets(
      'folder selection survives page exit and honors cancellation=$cancel',
      (tester) async {
        await setup(tester);
        try {
          appdata.settings['followUpdatesFolder'] = null;
          source.gate = Completer<void>();
          await showPage(tester);
          final dynamic page = tester.state(find.byType(FollowUpdatesPage));
          page.setFolder(folder);
          await tester.pump();
          await tester.runAsync(() => source.started.future);
          final task = BackgroundTasks.instance.latest(
            'follow-updates:$folder',
          )!;
          expect(appdata.settings['followUpdatesFolder'], isNull);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const Key('background-task-continue')));
          await tester.pumpAndSettle();
          await leavePage(tester);
          if (cancel) task.requestCancel();
          await releaseCheck(tester, task);
          expect(
            task.status,
            cancel
                ? BackgroundTaskStatus.cancelled
                : BackgroundTaskStatus.completed,
          );
          expect(
            appdata.settings['followUpdatesFolder'],
            cancel ? null : folder,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await cleanup(tester);
        }
      },
    );
  }

  testWidgets(
    'folder cancellation at commit restores and persists the previous selection',
    (tester) async {
      await setup(tester);
      void Function()? listener;
      try {
        appdata.settings['followUpdatesFolder'] = null;
        source.gate = Completer<void>();
        await showPage(tester);
        final task = FollowUpdatesService.selectFolder(folder);
        await tester.pump();
        await tester.runAsync(() => source.started.future);
        listener = () {
          if (appdata.settings['followUpdatesFolder'] == folder &&
              task.isRunning) {
            task.requestCancel();
          }
        };
        appdata.settings.addListener(listener);
        await releaseCheck(tester, task);
        expect(task.status, BackgroundTaskStatus.cancelled);
        expect(appdata.settings['followUpdatesFolder'], isNull);
        final saved = jsonDecode(
          File('${root.path}/appdata.json').readAsStringSync(),
        );
        expect(saved['settings']['followUpdatesFolder'], isNull);
      } finally {
        if (listener != null) appdata.settings.removeListener(listener);
        await cleanup(tester);
      }
    },
  );

  testWidgets('follow updates: sequential recheck preserves unread', (
    tester,
  ) async {
    await setup(tester);
    try {
      expect((await check(tester)).updated, 1);
      expect(
        BackgroundTasks.instance.latest('follow-updates:$folder')!.status,
        BackgroundTaskStatus.completed,
      );
      expect((await check(tester)).updated, 0);
      expect(manager.countUpdates(folder), 1);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets('follow update failures are retained in the task center', (
    tester,
  ) async {
    await setup(tester);
    try {
      ComicSourceManager().remove(source.key);
      final result = await check(tester);
      expect(result.errors, 1);
      final task = BackgroundTasks.instance.latest('follow-updates:$folder')!;
      expect(task.status, BackgroundTaskStatus.failed);
      expect(task.errors.single, contains('Comic source not found'));
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets(
    '429 attempts persist without consuming the first successful baseline',
    (tester) async {
      await setup(tester);
      try {
        source.errorMessage = 'Invalid Status Code 429: Too many requests';
        expect((await check(tester, baseline: true)).errors, 1);
        expect(source.calls, 1);
        var saved = manager.getComicsWithUpdatesInfo(folder).single;
        expect(saved.lastAttemptTime, isNotNull);
        expect(saved.lastCheckTime, isNull);
        expect(saved.updateTime, '2026-10-6');
        manager.close();
        await tester.runAsync(() => manager.init());
        saved = manager.getComicsWithUpdatesInfo(folder).single;
        expect(saved.lastAttemptTime, isNotNull);
        final skipped = (await tester.runAsync(
          () => updateFolder(folder, false).toList(),
        ))!.last;
        expect(skipped.total, 0);
        expect(source.calls, 1);
        // A forced retry remains possible and still establishes a silent baseline.
        source.errorMessage = null;
        expect((await check(tester, baseline: true)).updated, 0);
        saved = manager.getComicsWithUpdatesInfo(folder).single;
        expect(saved.lastCheckTime, isNotNull);
        expect(saved.lastAttemptTime, isNull);
        source.chapterIds.add('later-chapter');
        expect((await check(tester, baseline: true)).updated, 1);
        // A failed recheck must preserve both the chapter baseline and unread flag.
        source.errorMessage = 'HTTP 429';
        expect((await check(tester)).errors, 1);
        expect(manager.countUpdates(folder), 1);
        source.errorMessage = null;
        expect((await check(tester)).updated, 0);
        expect(manager.countUpdates(folder), 1);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'old follow schema migrates and expired failures retry automatically',
    (tester) async {
      await setup(tester);
      try {
        expect((await check(tester, baseline: true)).updated, 0);
        final baseline = manager.getComicsWithUpdatesInfo(folder).single;
        manager.close();
        final db = sqlite3.open('${root.path}/local_favorite.db');
        try {
          db.execute('ALTER TABLE "$folder" DROP COLUMN last_attempt_time;');
        } finally {
          db.dispose();
        }
        await tester.runAsync(() => manager.init());
        var restored = manager.getComicsWithUpdatesInfo(folder).single;
        expect(restored.lastCheckTime, baseline.lastCheckTime);
        expect(restored.lastAttemptTime, isNull);
        source.errorMessage = 'HTTP 429';
        await check(tester);
        manager.close();
        final expired = sqlite3.open('${root.path}/local_favorite.db');
        try {
          expired.execute(
            'UPDATE "$folder" SET last_check_time = ?, last_attempt_time = ?;',
            [0, 1],
          );
        } finally {
          expired.dispose();
        }
        await tester.runAsync(() => manager.init());
        source.errorMessage = null;
        source.chapterIds.add('after-cooldown');
        final result = (await tester.runAsync(
          () => updateFolder(folder, false).toList(),
        ))!.last;
        expect(result.updated, 1);
        restored = manager.getComicsWithUpdatesInfo(folder).single;
        expect(restored.lastAttemptTime, isNull);
        expect(restored.lastCheckTime, isNotNull);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets('429 pauses only its source for the remainder of a batch', (
    tester,
  ) async {
    await setup(tester);
    try {
      source.errorMessage = 'HTTP 429';
      for (var i = 2; i <= 8; i++) {
        manager.addComic(
          folder,
          FavoriteItem(
            id: '$i',
            name: 'Limited $i',
            coverPath: '',
            author: '',
            type: ComicType.fromKey(source.key),
            tags: [],
          ),
        );
      }
      final healthy = _Source('healthy-source');
      ComicSourceManager().add(healthy);
      manager.addComic(
        folder,
        FavoriteItem(
          id: 'healthy',
          name: 'Healthy',
          coverPath: '',
          author: '',
          type: ComicType.fromKey(healthy.key),
          tags: [],
        ),
      );
      final result = await check(tester);
      expect(result.errors, 8);
      expect(source.calls, lessThanOrEqualTo(5));
      expect(healthy.calls, 1);
      expect(
        manager
            .getComicsWithUpdatesInfo(folder)
            .where((c) => c.type == ComicType.fromKey(source.key))
            .every((c) => c.lastAttemptTime != null && c.lastCheckTime == null),
        isTrue,
      );
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets(
    'follow update task-center cancellation waits for pending requests',
    (tester) async {
      await setup(tester);
      try {
        await tester.runAsync(() async {
          source.gate = Completer<void>();
          var cancellations = 0;
          final pending = updateFolder(
            folder,
            true,
            onCancel: () => cancellations++,
          ).toList();
          await source.started.future;
          final task = BackgroundTasks.instance.latest(
            'follow-updates:$folder',
          )!;
          task.requestCancel();
          expect(cancellations, 1);
          expect(task.isRunning, isTrue);
          source.gate!.complete();
          await pending;
          expect(task.status, BackgroundTaskStatus.cancelled);
          expect(cancellations, 1);
        });
        expect(manager.countUpdates(folder), 0);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: overlapping checks preserve unread and count once',
    (tester) async {
      await setup(tester);
      try {
        final results = (await tester.runAsync(() async {
          source.gate = Completer<void>();
          final first = updateFolder(folder, true).toList();
          await source.started.future;
          final oldTask = BackgroundTasks.instance.latest(
            'follow-updates:$folder',
          )!;
          final second = updateFolder(folder, true).toList();
          expect(oldTask.status, BackgroundTaskStatus.cancelled);
          expect(
            BackgroundTasks.instance.latest('follow-updates:$folder'),
            isNot(same(oldTask)),
          );
          for (var attempt = 0; source.calls < 2 && attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          source.gate!.complete();
          expect(source.calls, 2);
          return Future.wait([first, second]);
        }))!;
        expect(
          results.map((events) => events.last.updated).reduce((a, b) => a + b),
          1,
        );
        expect(manager.countUpdates(folder), 1);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets('follow updates: same-day chapter additions are detected', (
    tester,
  ) async {
    await setup(tester);
    try {
      await check(tester);
      manager.markAsRead('1', ComicType.fromKey(source.key));
      source.timestamp = '2026-10-07 23:30:00';
      source.chapterIds.add('new');
      expect((await check(tester)).updated, 1);
      expect(manager.countUpdates(folder), 1);
      expect((await check(tester)).updated, 0);
      expect(manager.countUpdates(folder), 1);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets(
    'follow updates: an already canceled call preserves the active check',
    (tester) async {
      await setup(tester);
      try {
        final results = (await tester.runAsync(() async {
          source.gate = Completer<void>();
          final active = updateFolder(folder, true).toList();
          await source.started.future.timeout(const Duration(seconds: 5));
          final canceled = updateFolder(
            folder,
            false,
            shouldCancel: () => true,
          ).toList();
          source.gate!.complete();
          return Future.wait([
            active,
            canceled,
          ]).timeout(const Duration(seconds: 5));
        }))!;
        expect(results.first.last.updated, 1);
        expect(results.last, isEmpty);
        expect(source.calls, 1);
        expect(manager.countUpdates(folder), 1);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: chapter removal or reordering is not a new chapter',
    (tester) async {
      await setup(tester);
      try {
        source.chapterIds = ['one', 'two'];
        await check(tester);
        manager.markAsRead('1', ComicType.fromKey(source.key));
        source.chapterIds = ['two', 'one'];
        expect((await check(tester)).updated, 0);
        source.chapterIds = ['one'];
        expect((await check(tester)).updated, 0);
        expect(manager.countUpdates(folder), 0);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: initial baseline is silent and preserves unread',
    (tester) async {
      await setup(tester);
      try {
        expect((await check(tester, baseline: true)).updated, 0);
        expect(manager.countUpdates(folder), 0);
        source.chapterIds.add('new');
        expect((await check(tester)).updated, 1);
        manager.prepareTableForFollowUpdates(folder, false);
        expect((await check(tester, baseline: true)).updated, 0);
        expect(manager.countUpdates(folder), 1);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: revisiting a tracked folder detects new chapters',
    (tester) async {
      await setup(tester);
      try {
        expect((await check(tester, baseline: true)).updated, 0);
        source.chapterIds.add('added-while-away');
        manager.prepareTableForFollowUpdates(folder, false);
        expect((await check(tester, baseline: true)).updated, 1);
        expect(manager.countUpdates(folder), 1);
        expect((await check(tester, baseline: true)).updated, 0);
        expect(manager.countUpdates(folder), 1);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: canceled requests cannot write after completion',
    (tester) async {
      await setup(tester);
      try {
        source.errorMessage = 'HTTP 429';
        var canceled = false;
        final events = (await tester.runAsync(() async {
          source.gate = Completer<void>();
          final pending = updateFolder(
            folder,
            true,
            shouldCancel: () => canceled,
          ).toList();
          await source.started.future;
          canceled = true;
          source.gate!.complete();
          return pending;
        }))!;
        expect(events.last.updated, 0);
        expect(
          BackgroundTasks.instance.latest('follow-updates:$folder')!.status,
          BackgroundTaskStatus.cancelled,
        );
        expect(manager.countUpdates(folder), 0);
        expect(
          manager.getComicsWithUpdatesInfo(folder).single.lastAttemptTime,
          isNull,
        );
        expect(
          manager.getComicsWithUpdatesInfo(folder).single.updateTime,
          '2026-10-6',
        );
      } finally {
        await cleanup(tester);
      }
    },
  );

  for (final mode in ['detailed', 'brief']) {
    testWidgets(
      'left swipe acknowledges only that update and keeps following ($mode)',
      (tester) async {
        await setup(tester);
        try {
          appdata.settings['comicDisplayMode'] = mode;
          final type = ComicType.fromKey(source.key);
          manager.addComic(
            folder,
            FavoriteItem(
              id: '2',
              name: 'Other tracked comic',
              coverPath: source.cover,
              author: '',
              type: type,
              tags: [],
            ),
            null,
            '2026-10-6',
          );
          await tester.runAsync(() async {
            await HistoryManager().init();
            await LocalManager().init();
          });
          await check(tester);
          expect(manager.countUpdates(folder), 2);
          final baseline = manager
              .getComicsWithUpdatesInfo(folder)
              .firstWhere((c) => c.id == '1');
          await showPage(tester);
          final first = find.byKey(ValueKey<Object>((folder, type.value, '1')));
          await tester.scrollUntilVisible(
            first,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          final width = tester.getSize(first).width;
          // Right swipe must not acknowledge an update.
          await tester.drag(first, Offset(width * .8, 0));
          await tester.pumpAndSettle();
          expect(manager.countUpdates(folder), 2);
          await tester.runAsync(() async {
            await tester.drag(first, Offset(-width * .9, 0));
            await tester.pumpAndSettle();
            await appdata.saveData(false);
          });
          await tester.pumpAndSettle();
          expect(first, findsNothing);
          expect(
            find.byKey(ValueKey<Object>((folder, type.value, '2'))),
            findsOneWidget,
          );
          expect(manager.countUpdates(folder), 1);
          expect(manager.getFolderComics(folder), hasLength(2));
          expect(appdata.settings['followUpdatesFolder'], folder);
          expect(HistoryManager().length, 0);
          final acknowledged = manager
              .getComicsWithUpdatesInfo(folder)
              .firstWhere((c) => c.id == '1');
          expect(acknowledged.hasNewUpdate, isFalse);
          expect(acknowledged.updateTime, baseline.updateTime);
          expect(acknowledged.lastCheckTime, baseline.lastCheckTime);
          expect(tester.takeException(), isNull);

          // The read flag survives reopening; a recheck of the same chapters
          // stays quiet, whereas a newly published chapter restores the update.
          await leavePage(tester);
          manager.close();
          await tester.runAsync(() => manager.init());
          expect(manager.getFolderComics(folder), hasLength(2));
          expect(manager.countUpdates(folder), 1);
          expect((await check(tester)).updated, 0);
          expect(
            manager
                .getComicsWithUpdatesInfo(folder)
                .firstWhere((c) => c.id == '1')
                .hasNewUpdate,
            isFalse,
          );
          source.chapterIds.add('published-after-swipe');
          expect((await check(tester)).updated, 2);
          expect(manager.countUpdates(folder), 2);
          await showPage(tester);
          await tester.scrollUntilVisible(
            first,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(first, findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await cleanup(tester);
        }
      },
    );
  }

  testWidgets(
    'follow updates: unread section refreshes after detection and reading',
    (tester) async {
      await setup(tester);
      try {
        await tester.runAsync(() async {
          await HistoryManager().init();
          await LocalManager().init();
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const FollowUpdatesPage(),
          ),
        );
        await tester.pumpAndSettle();
        List<Comic> unread() => tester
            .widgetList<SliverGridComics>(
              find.byType(SliverGridComics, skipOffstage: false),
            )
            .first
            .comics;
        expect(find.text('No updates found'), findsOneWidget);
        expect((await check(tester)).updated, 1);
        expect(manager.countUpdates(folder), 1);
        updateFollowUpdatesUI();
        await tester.pumpAndSettle();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(unread(), hasLength(1));
        manager.markAsRead('1', ComicType.fromKey(source.key));
        await tester.pumpAndSettle();
        expect(find.text('No updates found'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: mark all reads 500 comics and refreshes only once',
    (tester) async {
      await setup(tester);
      try {
        manager.addComics(folder, [
          for (var i = 2; i <= 500; i++)
            FavoriteItem(
              id: '$i',
              name: 'Follow update fixture $i',
              author: '',
              coverPath: source.cover,
              type: ComicType.fromKey(source.key),
              tags: [],
            ),
        ]);
        for (final comic in manager.getComicsWithUpdatesInfo(folder)) {
          manager.updateUpdateTime(folder, comic.id, comic.type, '2026-10-7');
        }
        const otherFolder = 'Other followed folder';
        manager.createFolder(otherFolder);
        manager.prepareTableForFollowUpdates(otherFolder, false);
        manager.addComics(otherFolder, [
          manager.getComicsWithUpdatesInfo(folder).first,
        ]);
        manager.updateUpdateTime(
          otherFolder,
          '1',
          ComicType.fromKey(source.key),
          '2026-10-7',
        );
        images.cache(manager.getComicsWithUpdatesInfo(folder));
        await tester.runAsync(() async {
          await HistoryManager().init();
          await LocalManager().init();
        });
        final counted = _CountingFavorites(manager);
        LocalFavoritesManager.cache = counted;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const FollowUpdatesPage(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byIcon(Icons.clear_all));
        await tester.tap(find.byIcon(Icons.clear_all));
        await tester.pumpAndSettle();
        counted.fullReads = 0;
        var notifications = 0;
        void onChange() => notifications++;
        manager.addListener(onChange);
        try {
          await tester.tap(find.text('Confirm'));
          await tester.pumpAndSettle();
          expect(counted.bulkMarks, 1);
          expect(counted.singleMarks, 0);
          expect(counted.fullReads, 1);
          expect(notifications, 1);
          expect(manager.countUpdates(folder), 0);
          expect(manager.countUpdates(otherFolder), 1);
          expect(find.text('No updates found'), findsOneWidget);
          manager.markAllAsRead();
          expect(counted.fullReads, 1);
          expect(notifications, 1);
          expect(tester.takeException(), isNull);
        } finally {
          manager.removeListener(onChange);
        }
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'follow updates: canceled sync waiter cannot interrupt a manual check',
    (tester) async {
      await setup(tester);
      final previousSync = DataSync.instance;
      Timer? serviceTimer;
      _WaitingSync? sync;
      try {
        await tester.runAsync(() async {
          await HistoryManager().init();
          await LocalManager().init();
          sync = _WaitingSync();
        });
        DataSync.instance = sync;
        appdata.settings['followUpdatesCheckOnStart'] = true;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const FollowUpdatesPage(),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic page = tester.state(find.byType(FollowUpdatesPage));
        await tester.runAsync(() async {
          source.gate = Completer<void>();
          final updated = Completer<void>();
          void onChange() {
            if (manager.countUpdates(folder) == 1 && !updated.isCompleted) {
              updated.complete();
            }
          }

          manager.addListener(onChange);
          try {
            runZoned(
              FollowUpdatesService.initChecker,
              zoneSpecification: ZoneSpecification(
                createPeriodicTimer: (self, parent, zone, duration, callback) =>
                    serviceTimer = parent.createPeriodicTimer(
                      zone,
                      duration,
                      callback,
                    ),
              ),
            );
            page.checkNow();
            await source.started.future.timeout(const Duration(seconds: 5));
            sync!.downloading = false;
            await sync!.resumed.future.timeout(const Duration(seconds: 5));
            source.gate!.complete();
            await updated.future.timeout(const Duration(seconds: 5));
            await Future<void>.delayed(Duration.zero);
            expect(source.calls, 1);
            expect(manager.countUpdates(folder), 1);
          } finally {
            manager.removeListener(onChange);
          }
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        serviceTimer?.cancel();
        DataSync.instance = previousSync;
        sync?.dispose();
        await cleanup(tester);
      }
    },
  );
}
