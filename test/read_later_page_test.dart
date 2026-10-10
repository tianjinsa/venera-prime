import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/read_later_page.dart';
import 'package:venera/utils/translations.dart';

import 'support/comic_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  testWidgets(
    'read later retains blocked items through search, delete and undo',
    (tester) async {
      final settings =
          jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
      final previousHistory = HistoryManager.cache;
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('read-later-page-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = root.path;
      appdata.settings['language'] = 'en-US';
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;
      appdata.settings['comicDisplayMode'] = 'detailed';
      appdata.settings['blockedWords'] = ['saved'];
      appdata.settings['blockedAuthors'] = ['excluded'];
      HistoryManager.cache = HistoryManager.create();
      final later = ReadLaterManager()..close();
      await tester.runAsync(() => later.init());
      for (var i = 0; i < 3; i++) {
        later.add(
          Comic('saved $i', '', '$i', 'excluded', [], '', 'test', null, null),
        );
      }
      final images = ComicImageFixture()..cache(later.getAll());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        images.dispose();
        later.close();
        HistoryManager.cache!.dispose();
        HistoryManager.cache = previousHistory;
        appdata.restoreMemorySnapshot(settings);
        await tester.runAsync(() => root.delete(recursive: true));
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const ReadLaterPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicTile), findsNWidgets(3));
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'saved 1');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(tester.widget<ComicTile>(find.byType(ComicTile)).comic.id, '1');
      await tester.tap(find.byTooltip('Multi-Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select All'));
      await tester.pump();
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicTile), findsNothing);
      expect(later.getAll(), hasLength(2));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(tester.widget<ComicTile>(find.byType(ComicTile)).comic.id, '1');
      expect(later.getAll(), hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );
}
