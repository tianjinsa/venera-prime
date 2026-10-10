import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';

import 'support/comic_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late Map<String, dynamic> settings;
  late HistoryManager? previousHistory;
  late ComicImageFixture images;
  final comics = [
    const Comic(
      'hidden title',
      '',
      'word',
      'allowed',
      [],
      '',
      'test',
      null,
      null,
    ),
    const Comic(
      'ordinary title',
      '',
      'author',
      'excluded',
      [],
      '',
      'test',
      null,
      null,
    ),
    const Comic(
      'visible title',
      '',
      'visible',
      'allowed',
      [],
      '',
      'test',
      null,
      null,
    ),
  ];

  setUp(() {
    settings = jsonDecode(jsonEncode(appdata.toJson()));
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedWords'] = ['hidden'];
    appdata.settings['blockedAuthors'] = ['excluded'];
    previousHistory = HistoryManager.cache;
    HistoryManager.cache = HistoryManager.create();
    images = ComicImageFixture()..cache(comics);
  });

  tearDown(() {
    images.dispose();
    HistoryManager.cache!.dispose();
    HistoryManager.cache = previousHistory;
    appdata.restoreMemorySnapshot(settings);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: CustomScrollView(slivers: [SliverGridComics(comics: comics)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> visibleIds(WidgetTester tester) => tester
      .widgetList<ComicTile>(find.byType(ComicTile))
      .map((tile) => tile.comic.id)
      .toList();

  testWidgets('default grids apply keywords and exact author rules', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await mount(tester);
    expect(visibleIds(tester), ['visible']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-length rule edits refresh an unchanged comic list', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await mount(tester);
    appdata.settings['blockedWords'][0] = 'visible';
    appdata.settings['blockedAuthors'][0] = 'missing author';
    await mount(tester);
    expect(visibleIds(tester), ['word', 'author']);
    expect(tester.takeException(), isNull);
  });
}
