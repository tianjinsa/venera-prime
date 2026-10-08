import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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

  @override
  LoadComicFunc get loadComicInfo => (id) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await gate?.future;
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

  testWidgets('follow updates: sequential recheck preserves unread', (
    tester,
  ) async {
    await setup(tester);
    try {
      expect((await check(tester)).updated, 1);
      expect((await check(tester)).updated, 0);
      expect(manager.countUpdates(folder), 1);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets(
    'follow updates: overlapping checks preserve unread and count once',
    (tester) async {
      await setup(tester);
      try {
        final results = (await tester.runAsync(() async {
          source.gate = Completer<void>();
          final first = updateFolder(folder, true).toList();
          await source.started.future;
          final second = updateFolder(folder, true).toList();
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
        expect(manager.countUpdates(folder), 0);
        expect(
          manager.getComicsWithUpdatesInfo(folder).single.updateTime,
          '2026-10-6',
        );
      } finally {
        await cleanup(tester);
      }
    },
  );

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
