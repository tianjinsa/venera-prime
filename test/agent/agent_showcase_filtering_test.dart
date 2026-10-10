import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_showcase_view.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/components/components.dart' show ComicTile;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

import '../support/comic_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  for (final kind in ['discovery', 'favorites', 'later']) {
    testWidgets('Agent $kind results retain keyword and author matches', (
      tester,
    ) async {
      final settings =
          jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;
      appdata.settings['comicDisplayMode'] = 'detailed';
      appdata.settings['blockedWords'] = ['hidden'];
      appdata.settings['blockedAuthors'] = ['excluded'];
      final group = AgentShowcase(
        id: 'fixture-$kind',
        kind: kind,
        title: 'Requested comics',
        note: '',
        createdAt: 1,
        comics: const [
          AgentComic(sourceKey: 'test', comicId: 'word', title: 'hidden title'),
          AgentComic(
            sourceKey: 'test',
            comicId: 'author',
            title: 'ordinary title',
            subtitle: 'excluded',
          ),
        ],
      );
      final images = ComicImageFixture()
        ..cache(group.comics.map(AgentTools.toComic));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        images.dispose();
        appdata.restoreMemorySnapshot(settings);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentShowcasePanel(
              conversationId: 'filter-test',
              groups: [group],
              focusedGroup: group.id,
              clear: () {},
              hideGroup: (_) {},
              hideComic: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<ComicTile>(find.byType(ComicTile))
            .map((tile) => tile.comic.id),
        ['word', 'author'],
      );
      expect(tester.takeException(), isNull);
    });
  }
}
