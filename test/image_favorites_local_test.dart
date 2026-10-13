import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/local.dart';

class _LocalOnlyProvider extends ImageFavoritesProvider {
  _LocalOnlyProvider(super.imageFavorite);

  @override
  Future<Uint8List?> readFromCache() async {
    fail('Downloaded favorite should not need a separate cache lookup');
  }

  @override
  Future<Uint8List> getImageFromNetwork(
    imageKey,
    chunkEvents,
    checkStop,
  ) async {
    fail('Downloaded favorite should not need a network request');
  }
}

void main() => registerImageFavoriteLocalTests();

void registerImageFavoriteLocalTests({bool device = false}) {
  void register(String name, Future<void> Function() body) {
    if (device) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      });
    } else {
      test(name, body);
    }
  }

  for (final chapter in ['first', 'second', 'unchaptered']) {
    register(
      'favorite reads downloaded $chapter chapter without network',
      () async {
        final root = await Directory.systemTemp.createTemp('favorite-local-');
        final manager = LocalManager();
        manager.close();
        try {
          App.dataPath = root.path;
          final local = Directory('${root.path}/local')..createSync();
          File('${root.path}/local_path').writeAsStringSync(local.path);
          const source = 'favorite-local-test';
          const comicId = 'comic-42';
          final hasChapters = chapter != 'unchaptered';
          final comicDir = Directory('${local.path}/downloaded')..createSync();
          for (final entry in {
            'first': 11,
            'second': 22,
            'unchaptered': 33,
          }.entries) {
            final directory = entry.key == 'unchaptered'
                ? comicDir
                : (Directory('${comicDir.path}/${entry.key}')..createSync());
            File('${directory.path}/1.png').writeAsBytesSync([entry.value]);
            File('${directory.path}/2.png').writeAsBytesSync([entry.value + 1]);
          }
          await manager.init();
          await manager.add(
            LocalComic(
              id: comicId,
              title: 'Downloaded favorite',
              subtitle: '',
              tags: const [],
              directory: 'downloaded',
              chapters: hasChapters
                  ? ComicChapters({
                      'first': 'Chapter 1',
                      'second': 'Chapter 2',
                      'not-downloaded': 'Chapter 3',
                    })
                  : null,
              cover: '1.png',
              comicType: ComicType.fromKey(source),
              downloadedChapters: hasChapters ? ['first', 'second'] : [],
              createdAt: DateTime.utc(2026, 10, 11),
            ),
          );
          final favorite = ImageFavorite(
            2,
            'https://invalid.example/page.png',
            false,
            chapter,
            comicId,
            chapter == 'second' ? 2 : 1,
            source,
            chapter,
          );
          final bytes = await _LocalOnlyProvider(favorite).load(null, null);
          expect(bytes, [
            switch (chapter) {
              'first' => 12,
              'second' => 23,
              _ => 34,
            },
          ]);
          expect(
            await ImageFavoritesProvider(
              favorite.copyWith(page: 3),
            ).getImageFromLocal(),
            isNull,
          );
          if (hasChapters) {
            for (final missing in ['not-downloaded', 'unknown']) {
              expect(
                await ImageFavoritesProvider(
                  favorite.copyWith(eid: missing),
                ).getImageFromLocal(),
                isNull,
              );
            }
          }
          await comicDir.delete(recursive: true);
          expect(
            await ImageFavoritesProvider(favorite).getImageFromLocal(),
            isNull,
          );
        } finally {
          manager.close();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
