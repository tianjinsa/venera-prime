import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'support/test_translations.dart';

class _Source implements ComicSource {
  @override
  String get key => 'update-test';
  int calls = 0;
  Completer<void>? gate;
  @override
  LoadComicFunc get loadComicInfo => (id) async {
    calls++;
    await gate?.future;
    return Res(
      ComicDetails.fromJson({
        'title': 'Updated comic',
        'cover': '',
        'tags': <String, dynamic>{},
        'sourceKey': key,
        'comicId': id,
      }),
    );
  };
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
    directory = await Directory.systemTemp.createTemp('favorite-update-');
    App.dataPath = directory.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    manager = LocalFavoritesManager();
    manager.close();
    await manager.init();
    source = _Source();
    ComicSourceManager().add(source);
    manager.createFolder('First');
    manager.createFolder('Second');
  });
  tearDown(() async {
    ComicSourceManager().remove(source.key);
    manager.close();
    BackgroundTasks.instance.clearFinished();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });
  FavoriteItem comic(String id, {bool missingSource = false}) => FavoriteItem(
    id: id,
    name: missingSource ? 'Missing source comic' : 'Old $id',
    coverPath: '',
    author: '',
    type: missingSource
        ? const ComicType(987654321)
        : ComicType.fromKey(source.key),
    tags: [],
  );
  Future<void> showApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
  );

  testWidgets(
    'closing update view keeps deduplicated refresh running and retains reasons',
    (tester) async {
      manager.addComics('First', [comic('1')]);
      manager.addComics('Second', [
        comic('1'),
        comic('2', missingSource: true),
      ]);
      source.gate = Completer<void>();
      await showApp(tester);
      final result = updateAllComicsInfo();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final task = BackgroundTasks.instance.latest(favoriteInfoTaskKey(null))!;
      expect(source.calls, 1);
      expect(task.isRunning, isTrue);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(task.cancelRequested, isFalse);
      expect(task.isRunning, isTrue);
      // Removing a membership while minimized must not recreate it on completion.
      manager.deleteComicWithId('Second', '1', ComicType.fromKey(source.key));
      source.gate!.complete();
      await tester.pump();
      await result;
      expect(source.calls, 1);
      expect(manager.getFolderComics('First').single.name, 'Updated comic');
      expect(
        manager.getFolderComics('Second').single.name,
        'Missing source comic',
      );
      expect(task.completed, 2);
      expect(task.total, 2);
      expect(task.errors.single, contains('Missing source comic'));
      expect(task.errors.single, contains('Comic source is unavailable'));
      expect(task.status, BackgroundTaskStatus.failed);
      expect(
        BackgroundTasks.instance.latest(favoriteInfoTaskKey(null)),
        same(task),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('explicit cancellation starts no further requests or retries', (
    tester,
  ) async {
    manager.addComics('First', List.generate(8, (i) => comic('$i')));
    source.gate = Completer<void>();
    await showApp(tester);
    final result = updateComicsInfo('First');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final task = BackgroundTasks.instance.latest(favoriteInfoTaskKey('First'))!;
    expect(source.calls, 4);
    task.requestCancel();
    source.gate!.complete();
    await tester.pump();
    await result;
    expect(source.calls, 4);
    expect(task.status, BackgroundTaskStatus.cancelled);
    expect(
      manager.getFolderComics('First').every((c) => c.name.startsWith('Old')),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
