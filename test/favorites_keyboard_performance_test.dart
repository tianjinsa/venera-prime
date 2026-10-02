import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

class _CountingHistory extends HistoryManager {
  _CountingHistory() : super.create();
  int lookups = 0;
  @override
  History? find(String id, ComicType type) {
    lookups++;
    return null;
  }
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  final items = <FavoriteItem>[];
  @override
  List<String> get folderNames => ['Large'];
  @override
  int get totalComics => items.length;
  @override
  int folderComics(String folder) => items.length;
  @override
  int count(String folder) => items.length;
  @override
  bool existsFolder(String folder) => folder == 'Large';
  @override
  (String?, String?) findLinked(String folder) => (null, null);
  @override
  List<FavoriteItem> getFolderComics(String folder) => items;
  @override
  List<FavoriteItem> getAllComics() => items;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  for (final filter in ['All', 'UnCompleted']) {
    testWidgets(
      'favorite search keyboard avoids rescanning the collection ($filter)',
      (tester) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(1, 1);
        picture.dispose();
        final previousManager = LocalFavoritesManager.cache;
        final manager = _Favorites();
        LocalFavoritesManager.cache = manager;
        final previousHistory = HistoryManager.cache;
        final history = _CountingHistory();
        HistoryManager.cache = history;
        final previousFavorite = appdata.settings['showFavoriteStatusOnTile'];
        final previousStatus = appdata.settings['showHistoryStatusOnTile'];
        final previousFolder = appdata.implicitData['favoriteFolder'];
        final previousFilter =
            appdata.implicitData['local_favorites_read_filter'];
        appdata.settings['showFavoriteStatusOnTile'] = false;
        appdata.settings['showHistoryStatusOnTile'] = false;
        appdata.implicitData['favoriteFolder'] = {
          'name': 'Large',
          'isNetwork': false,
        };
        appdata.implicitData['local_favorites_read_filter'] = filter;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        try {
          manager.items.addAll([
            for (var i = 0; i < 400; i++)
              FavoriteItem(
                id: '$i',
                name: 'Comic $i',
                coverPath: 'https://example.invalid/cover.png',
                author: 'Author',
                type: const ComicType(42),
                tags: [],
              ),
          ]);
          for (final comic in manager.items) {
            PaintingBinding.instance.imageCache.putIfAbsent(
              CachedImageProvider(
                comic.cover,
                sourceKey: comic.sourceKey,
                cid: comic.id,
              ),
              () => OneFrameImageStreamCompleter(
                Future.value(ImageInfo(image: image.clone())),
              ),
            );
          }
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              home: const Scaffold(body: FavoritesPage()),
            ),
          );
          await tester.pumpAndSettle();
          final expectedLookups = filter == 'All' ? 0 : 400;
          expect(history.lookups, expectedLookups);
          history.notifyListeners();
          await tester.pumpAndSettle();
          expect(history.lookups, expectedLookups * 2);
          expect(find.byType(ComicTile).evaluate().length, lessThan(30));
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsOneWidget);
          final grid = tester.widget<SliverGridComics>(
            find.byType(SliverGridComics),
          );
          final firstHero = tester
              .widget<ComicTile>(find.byType(ComicTile).first)
              .heroID;
          for (var i = 1; i <= 15; i++) {
            tester.view.viewInsets = FakeViewPadding(bottom: i * 20.0);
            await tester.pump();
          }
          expect(history.lookups, expectedLookups * 2);
          expect(
            identical(
              tester
                  .widget<SliverGridComics>(find.byType(SliverGridComics))
                  .comics,
              grid.comics,
            ),
            isTrue,
          );
          expect(
            tester.widget<ComicTile>(find.byType(ComicTile).first).heroID,
            firstHero,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          LocalFavoritesManager.cache = previousManager;
          HistoryManager.cache = previousHistory;
          appdata.settings['showFavoriteStatusOnTile'] = previousFavorite;
          appdata.settings['showHistoryStatusOnTile'] = previousStatus;
          appdata.implicitData['favoriteFolder'] = previousFolder;
          appdata.implicitData['local_favorites_read_filter'] = previousFilter;
          PaintingBinding.instance.imageCache.clear();
          image.dispose();
        }
      },
    );
  }
}
