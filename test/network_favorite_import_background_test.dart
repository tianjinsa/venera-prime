import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'support/test_translations.dart';

class _Source implements ComicSource {
  @override
  final key = 'network-import-test';
  @override
  final name = 'Network import';
  late Future<Res<List<Comic>>> Function(int page) loader;
  bool oldToNew = false;
  final calls = <int>[];
  @override
  FavoriteData get favoriteData => FavoriteData(
    key: key,
    title: name,
    multiFolder: false,
    loadNext: null,
    isOldToNewSort: oldToNew,
    loadComic: (page, [folder]) {
      calls.add(page);
      return loader(page);
    },
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTestTranslations);
  late Directory directory;
  late LocalFavoritesManager manager;
  late _Source source;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'network-import-background-',
    );
    App.dataPath = directory.path;
    appdata.settings['webdav'] = [];
    appdata.settings['newFavoriteAddTo'] = 'end';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    manager = LocalFavoritesManager()..close();
    await manager.init();
    source = _Source();
    ComicSourceManager().add(source);
    BackgroundTasks.instance.configure(history: {});
    BackgroundTasks.instance.clearFinished();
  });
  tearDown(() async {
    ComicSourceManager().remove(source.key);
    manager.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });
  Comic comic(String id) =>
      Comic(id, '', id, '', const [], '', source.key, null, null);
  Future<void> showApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
  );
  BackgroundTask getTask() => BackgroundTasks.instance.tasks.firstWhere(
    (task) => task.key.startsWith('network-favorites-import:'),
  );

  testWidgets(
    'minimizing keeps pagination running and duplicate comics stay unique',
    (tester) async {
      final second = Completer<Res<List<Comic>>>();
      source.loader = (page) async =>
          page == 1 ? Res([comic('a'), comic('a')], subData: 2) : second.future;
      await showApp(tester);
      final result = importNetworkFolder(source.key, 10, 'Saved', null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.calls, [1, 2]);
      await tester.tap(find.byKey(const Key('background-task-continue')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(getTask().cancelRequested, isFalse);
      second.complete(Res([comic('a'), comic('b')], subData: 2));
      await tester.pump();
      await result;
      expect(manager.count('Saved'), 2);
      expect(getTask().status, BackgroundTaskStatus.completed);
      expect(getTask().completed, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancel ignores a late page and issues no more page requests', (
    tester,
  ) async {
    final second = Completer<Res<List<Comic>>>();
    source.loader = (page) async =>
        page == 1 ? Res([comic('a')], subData: 3) : second.future;
    await showApp(tester);
    final result = importNetworkFolder(source.key, 10, 'Saved', null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    getTask().requestCancel();
    second.complete(Res([comic('b')], subData: 3));
    await tester.pump();
    await result;
    expect(source.calls, [1, 2]);
    expect(manager.count('Saved'), 1);
    expect(getTask().status, BackgroundTaskStatus.cancelled);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('later page failures retain fetched comics and a failed result', (
    tester,
  ) async {
    source.loader = (page) async =>
        page == 1 ? Res([comic('a')], subData: 2) : const Res.error('offline');
    await showApp(tester);
    final result = importNetworkFolder(source.key, 10, 'Saved', null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await result;
    expect(source.calls, [1, 2, 2, 2]);
    expect(manager.count('Saved'), 1);
    expect(getTask().status, BackgroundTaskStatus.failed);
    expect(getTask().errors.single, contains('offline'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old-to-new pagination clamps to first page and reuses its probe',
    (tester) async {
      source.oldToNew = true;
      source.loader = (page) async => Res([comic('$page')], subData: 2);
      await showApp(tester);
      final result = importNetworkFolder(source.key, 100, 'Saved', null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await result;
      expect(source.calls, [1, 2]);
      expect(manager.count('Saved'), 2);
      expect(getTask().status, BackgroundTaskStatus.completed);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
