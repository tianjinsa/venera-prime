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
import 'package:venera/utils/translations.dart';

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
    manager.close();
    await tester.runAsync(() => manager.init());
    manager.createFolder(folder);
    manager.prepareTableForFollowUpdates(folder, false);
    source = (await tester.runAsync(
      () async => _Source('follow-update-fixture-${sequence++}'),
    ))!;
    final image = File('${root.path}/fixture.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
        ),
      );
    source.cover = 'file://${image.path}';
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
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
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
}
