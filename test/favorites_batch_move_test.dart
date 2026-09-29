import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batch move to the same folder preserves favorites', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-favorites-move-',
    );
    App.dataPath = directory.path;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => directory.path,
        );

    final manager = LocalFavoritesManager();
    manager.close();
    await manager.init();
    manager.createFolder('Favorites');
    manager.createFolder('Archive');
    manager.createFolder('Reading');

    final comic = FavoriteItem(
      id: 'comic-1',
      name: 'Comic 1',
      coverPath: 'cover-1',
      author: 'Author',
      type: const ComicType(123),
      tags: const ['language:english'],
    );
    manager.addComic('Favorites', comic);

    manager.batchMoveFavorites('Favorites', 'Favorites', [comic]);
    expect(manager.getFolderComics('Favorites'), hasLength(1));
    expect(manager.folderComics('Favorites'), 1);

    manager.batchMoveFavoritesToFolders(
      'Favorites',
      ['Archive', 'Reading'],
      [comic],
    );
    expect(manager.getFolderComics('Favorites'), isEmpty);
    expect(manager.getFolderComics('Archive'), hasLength(1));
    expect(manager.getFolderComics('Reading'), hasLength(1));
    expect(manager.folderComics('Favorites'), 0);
    expect(manager.folderComics('Archive'), 1);
    expect(manager.folderComics('Reading'), 1);

    manager.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await directory.delete(recursive: true);
  });
}
