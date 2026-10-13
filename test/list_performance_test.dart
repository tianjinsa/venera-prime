import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/translations.dart';

import 'support/comic_image_fixture.dart';

class _HistoryManager with ChangeNotifier implements HistoryManager {
  final records = <History>[];
  int finds = 0;
  int allReads = 0;
  int pageReads = 0;
  int batches = 0;
  int singleDeletes = 0;

  @override
  List<History> getAll() {
    allReads++;
    return List.of(records);
  }

  @override
  Future<HistoryPageResult> getPage({
    HistoryCursor? cursor,
    int limit = 60,
    String query = '',
  }) async {
    pageReads++;
    final matching = records.where((item) => item.matchesQuery(query)).toList();
    final start = cursor == null
        ? 0
        : matching.indexWhere(
                (item) =>
                    item.id == cursor.id && item.type.value == cursor.type,
              ) +
              1;
    final items = matching.skip(start).take(limit).toList();
    return HistoryPageResult(
      items,
      nextCursor: start + items.length < matching.length
          ? HistoryCursor.fromHistory(items.last)
          : null,
    );
  }

  @override
  Future<Set<ComicID>> getMatchingIds({String query = ''}) async => {
    for (final record in records)
      if (record.matchesQuery(query)) ComicID(record.type, record.id),
  };

  @override
  History? find(String id, ComicType type) {
    finds++;
    return null;
  }

  @override
  void remove(String id, ComicType type) {
    singleDeletes++;
    records.removeWhere((h) => h.id == id && h.type == type);
    notifyListeners();
  }

  @override
  void batchDeleteHistories(List<ComicID> histories) {
    batches++;
    for (final id in histories) {
      records.removeWhere((h) => h.id == id.id && h.type == id.type);
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FavoritesManager with ChangeNotifier implements LocalFavoritesManager {
  final comics = List.generate(
    400,
    (i) => FavoriteItem(
      id: '$i',
      name: 'blocked-fixture $i',
      coverPath: '',
      author: '',
      type: const ComicType(123),
      tags: const [],
    ),
  );

  @override
  List<String> get folderNames => ['Test'];
  @override
  int get totalComics => comics.length;
  @override
  bool existsFolder(String name) => name == 'Test';
  @override
  int folderComics(String name) => comics.length;
  @override
  List<FavoriteItem> getFolderComics(String name) => comics;
  @override
  (String?, String?) findLinked(String name) => (null, null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  late _HistoryManager history;
  late ComicImageFixture images;
  setUp(() {
    final previousHistory = HistoryManager.cache;
    final previousFavorites = LocalFavoritesManager.cache;
    final Map<String, dynamic> snapshot = jsonDecode(
      jsonEncode(appdata.toJson()),
    );
    history = _HistoryManager();
    HistoryManager.cache = history;
    final favorites = _FavoritesManager();
    LocalFavoritesManager.cache = favorites;
    // Saved lists deliberately bypass keyword filtering. Stub cover loading
    // and badges so this measures list-wide history queries, not visible tiles.
    images = ComicImageFixture()..cache(favorites.comics);
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicTileScale'] = 1.0;
    appdata.settings['blockedWords'] = ['blocked-fixture'];
    appdata.implicitData['favoriteFolder'] = {
      'name': 'Test',
      'isNetwork': false,
    };
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    addTearDown(() {
      HistoryManager.cache = previousHistory;
      LocalFavoritesManager.cache = previousFavorites;
      images.dispose();
      appdata.restoreMemorySnapshot(snapshot);
    });
  });

  testWidgets('All favorites does not look up history for the whole folder', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FavoritesPage())),
    );
    await tester.pumpAndSettle();
    expect(history.finds, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history multi-delete refreshes the list once for the batch', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    history.records.addAll(
      List.generate(
        300,
        (i) => History.fromMap({
          'id': '$i',
          'type': i.isEven ? 0 : 123,
          'title': 'blocked-fixture $i',
          'subtitle': '',
          'cover': '',
          'time': 0,
          'ep': 1,
          'page': 1,
        }),
      ),
    );
    images.cache(history.records, thumbnailSize: const Size(320, 384));
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    final readsBeforeDelete = history.pageReads;
    await tester.tap(find.byIcon(Icons.delete));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(history.records, isEmpty);
    expect(history.batches, 1);
    expect(history.singleDeletes, 0);
    expect(history.pageReads - readsBeforeDelete, 1);
    expect(history.allReads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
