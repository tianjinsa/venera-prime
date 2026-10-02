import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

class _Source implements ComicSource {
  @override
  String get key => 'update-test';
  int calls = 0;
  @override
  LoadComicFunc get loadComicInfo => (id) async {
    calls++;
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
  testWidgets('all folders share one update dialog and deduplicate requests', (
    tester,
  ) async {
    await AppTranslation.init();
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('favorite-update-'),
    );
    App.dataPath = directory!.path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    final manager = LocalFavoritesManager();
    await tester.runAsync(() => manager.init());
    final source = _Source();
    ComicSourceManager().add(source);
    manager.createFolder('First');
    manager.createFolder('Second');
    final comic = FavoriteItem(
      id: '1',
      name: 'Old',
      coverPath: '',
      author: '',
      type: ComicType.fromKey(source.key),
      tags: [],
    );
    manager.addComics('First', [comic]);
    manager.addComics('Second', [comic]);
    manager.addComics('Second', [
      FavoriteItem(
        id: '2',
        name: 'Missing source comic',
        coverPath: '',
        author: '',
        type: const ComicType(987654321),
        tags: [],
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
    );
    await updateAllComicsInfo();
    await tester.pumpAndSettle();
    expect(source.calls, 1);
    expect(manager.getFolderComics('First').single.name, 'Updated comic');
    expect(manager.getFolderComics('Second').first.name, 'Updated comic');
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(find.text('Missing source comic'), findsOneWidget);
    expect(find.text('Errors: 1'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    manager.close();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
}
