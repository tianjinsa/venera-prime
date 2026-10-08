import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/translations.dart';

import 'support/comic_image_fixture.dart';

class _Source implements ComicSource {
  @override
  final String key = 'history-search-source';
  @override
  String name = 'Original source';
  @override
  bool get enableTagsTranslate => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends HistoryManager {
  _History() : super.create();
  List<History> records = [];
  int fullReads = 0;

  @override
  List<History> getAll() {
    fullReads++;
    return List.of(records);
  }

  @override
  void remove(String id, ComicType type) {
    records.removeWhere((comic) => comic.id == id && comic.type == type);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late _History history;
  late HistoryManager? previousHistory;
  late Map<String, dynamic> snapshot;
  late ComicImageFixture images;

  History record(String id, String title, String author) => History.fromMap({
    'id': id,
    'type': 42,
    'title': title,
    'subtitle': author,
    'cover': 'https://example.invalid/$id.png',
    'time': 1700000000000,
    'ep': 2,
    'page': 3,
  });

  setUp(() {
    snapshot = jsonDecode(jsonEncode(appdata.toJson()));
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['blockedWords'] = [];
    appdata.settings['blockedAuthors'] = [];
    appdata.settings['language'] = 'en-US';
    previousHistory = HistoryManager.cache;
    history = _History()
      ..records = [
        record('lost', 'Lost comic', 'Alpha'),
        record('other', 'Another comic', 'Beta'),
        record('third', 'Third comic', 'Alpha'),
      ];
    HistoryManager.cache = history;
    images = ComicImageFixture()..cache(history.records);
  });

  tearDown(() {
    images.dispose();
    HistoryManager.cache = previousHistory;
    appdata.restoreMemorySnapshot(snapshot);
  });

  Future<void> mount(WidgetTester tester, {bool pushRoute = false}) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: pushRoute
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HistoryPage()),
                    ),
                    child: const Text('Open history'),
                  ),
                ),
              )
            : const HistoryPage(),
      ),
    );
    if (pushRoute) await tester.tap(find.text('Open history'));
    await tester.pumpAndSettle();
  }

  List<String> visibleIds(WidgetTester tester) => tester
      .widget<SliverGridComics>(
        find.byType(SliverGridComics, skipOffstage: false),
      )
      .comics
      .map((comic) => comic.id)
      .toList();

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'history search opens explicitly and back cancels a pending query',
    (tester) async {
      await mount(tester, pushRoute: true);
      expect(find.byType(TextField), findsNothing);
      await openSearch(tester);
      await tester.enterText(find.byType(TextField), 'lost');
      await tester.pump(const Duration(milliseconds: 250));
      expect(visibleIds(tester), ['lost']);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(visibleIds(tester), ['lost', 'other', 'third']);
      await tester.enterText(find.byType(TextField), 'missing');
      await App.rootNavigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(visibleIds(tester), ['lost', 'other', 'third']);
      expect(history.fullReads, 1);
      await openSearch(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await App.rootNavigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(HistoryPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history typing debounces filtering and never rereads the database',
    (tester) async {
      await mount(tester);
      await openSearch(tester);
      for (final query in ['l', 'lo', 'lost', 'LOST alpha']) {
        await tester.enterText(find.byType(TextField), query);
      }
      await tester.pump();
      expect(visibleIds(tester), ['lost', 'other', 'third']);
      expect(history.fullReads, 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(visibleIds(tester), ['lost']);
      expect(history.fullReads, 1);
      await tester.enterText(find.byType(TextField), 'third');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      expect(history.fullReads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history notifications coalesce and refresh the active query', (
    tester,
  ) async {
    await mount(tester);
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump(const Duration(milliseconds: 250));
    expect(visibleIds(tester), ['lost', 'third']);
    history.records = [
      record('lost', 'Renamed comic', 'Beta'),
      record('new', 'New comic', 'Alpha'),
    ];
    images.cache(history.records);
    for (var i = 0; i < 20; i++) {
      history.notifyListeners();
    }
    expect(history.fullReads, 1);
    await tester.pump(const Duration(milliseconds: 150));
    expect(history.fullReads, 2);
    expect(visibleIds(tester), ['new']);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(visibleIds(tester), ['lost', 'new']);
    history.notifyListeners();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 150));
    expect(history.fullReads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history multi-select uses the current search even before debounce',
    (tester) async {
      await mount(tester);
      await openSearch(tester);
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.tap(find.byTooltip('Multi-Select'));
      await tester.pumpAndSettle();
      expect(visibleIds(tester), ['lost', 'third']);
      await tester.tap(find.byTooltip('Select All'));
      await tester.pump();
      await tester.tap(find.byTooltip('Delete'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(history.records.map((comic) => comic.id), ['other']);
      expect(visibleIds(tester), isEmpty);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(visibleIds(tester), ['other']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history search refreshes source names when sources change', (
    tester,
  ) async {
    final source = _Source();
    ComicSourceManager().add(source);
    history.records = [
      record('lost', 'Lost comic', 'Alpha')
        ..type = ComicType.fromKey(source.key),
    ];
    images.cache(history.records);
    await mount(tester);
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'Renamed source');
    await tester.pump(const Duration(milliseconds: 250));
    expect(visibleIds(tester), isEmpty);
    source.name = 'Renamed source';
    ComicSourceManager().notifyListeners();
    await tester.pump(const Duration(milliseconds: 150));
    expect(visibleIds(tester), ['lost']);
    expect(history.fullReads, 2);
    expect(tester.takeException(), isNull);
  });
}
