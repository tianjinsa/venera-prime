import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_showcase_view.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/components/components.dart' show ComicTile;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'agent_test_support.dart';

void main() {
  testWidgets(
    'default thinking uses a live dropdown and saves the selected level',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('agent-settings-'),
      ))!;
      configureAgentTestPaths(root.path);
      final store = (await tester.runAsync(
        () => AgentStore.open('${root.path}/agent'),
      ))!;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(850, 2200);
      Finder field(String name) => find.byKey(ValueKey('agent-model-$name'));
      try {
        await tester.pumpWidget(
          MaterialApp(home: AgentSettingsPage(store: store)),
        );
        await tester.tap(find.byKey(const ValueKey('agent-add-model')));
        await tester.pumpAndSettle();
        await tester.enterText(field('name'), '我的模型');
        await tester.enterText(field('model'), 'example-model');
        await tester.enterText(
          field('thinking'),
          jsonEncode([
            {
              'id': 'low',
              'label': '快速',
              'params': {'reasoning_effort': 'low'},
            },
            {
              'id': 'high',
              'label': '深入',
              'params': {'reasoning_effort': 'high'},
            },
          ]),
        );
        await tester.pump();
        expect(
          tester.widget<DropdownButton<String>>(field('default')).value,
          'low',
        );
        await tester.tap(field('default'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('深入').last);
        await tester.pumpAndSettle();
        expect(
          tester.widget<DropdownButton<String>>(field('default')).value,
          'high',
        );
        await tester.enterText(
          field('thinking'),
          '[{"id":"low","label":"快速","params":{}}]',
        );
        await tester.pump();
        expect(
          tester.widget<DropdownButton<String>>(field('default')).value,
          'low',
        );
        await tester.enterText(field('thinking'), '[');
        await tester.pump();
        expect(
          tester.widget<DropdownButton<String>>(field('default')).onChanged,
          isNull,
        );
        expect(find.text('请先填写有效的思考深度列表'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.enterText(
          field('thinking'),
          '[{"id":"deep","label":"深度思考","params":{"reasoning_effort":"high"}}]',
        );
        await tester.enterText(field('context'), '200000');
        await tester.pump();
        expect(
          tester.widget<DropdownButton<String>>(field('default')).value,
          'deep',
        );
        expect(find.textContaining('最大工具轮数'), findsNothing);
        expect(field('rounds'), findsNothing);
        await tester.runAsync(() async {
          await tester.tap(find.text('保存模型'));
          for (var i = 0; i < 100 && store.settings.models.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pumpAndSettle();
        expect(store.settings.models.single.defaultThinking, 'deep');
        expect(store.settings.models.single.contextWindowTokens, 200000);
        expect(
          store.settings.models.single.toJson().containsKey('max_tool_rounds'),
          false,
        );
        expect(find.text('Agent 模型设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        store.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  for (final mode in ['detailed', 'brief']) {
    testWidgets(
      'collection showcases fold by operation and favorite folder in $mode mode',
      (tester) async {
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('agent-operation-ui-'),
        ))!;
        configureAgentTestPaths(root.path);
        final previousMode = appdata.settings['comicDisplayMode'];
        final previousBadge = appdata.settings['showFavoriteStatusOnTile'];
        appdata.settings['comicDisplayMode'] = mode;
        appdata.settings['showFavoriteStatusOnTile'] = false;
        final local = LocalManager()..close();
        await tester.runAsync(() async {
          await local.init();
          await ComicSourceManager().ensureInit();
          await appdata.saveData(false);
        });
        final store = (await tester.runAsync(
          () => AgentStore.open('${root.path}/agent'),
        ))!;
        final conversation = store.createConversation();
        const first = AgentComic(
          sourceKey: 'local',
          comicId: 'first',
          title: '收藏的漫画',
        );
        const second = AgentComic(
          sourceKey: 'local',
          comicId: 'second',
          title: '稍后阅读的漫画',
        );
        final folderId = store.recordOperationComics(
          conversation.id,
          'favorites',
          [first],
          folder: '常看',
        );
        store.recordOperationComics(conversation.id, 'favorites', [
          second,
        ], folder: '待整理');
        final laterId = store.recordOperationComics(conversation.id, 'later', [
          second,
        ]);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(304, 1100);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => AgentShowcasePanel(
                    conversationId: conversation.id,
                    groups: store.showcases(conversation.id),
                    clear: () =>
                        setState(() => store.clearShowcases(conversation.id)),
                    hideGroup: (id) => setState(() => store.hideShowcase(id)),
                    hideComic: (id, comic) =>
                        setState(() => store.hideComic(id, comic)),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('收藏'), findsOneWidget);
          expect(find.text('稍后再看'), findsOneWidget);
          expect(find.text('常看'), findsNothing);
          expect(find.byType(ComicTile), findsNothing);
          await tester.tap(
            find.byKey(
              ValueKey('toggle-showcase-favorites-${conversation.id}'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('常看'), findsOneWidget);
          expect(find.text('待整理'), findsOneWidget);
          expect(find.byType(ComicTile), findsNothing);
          await tester.tap(find.byKey(ValueKey('toggle-showcase-$folderId')));
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile), findsOneWidget);
          final remove = find.byKey(
            ValueKey('remove-$folderId-${first.identity}'),
          );
          expect(
            tester
                .getRect(find.byType(ComicTile))
                .overlaps(tester.getRect(remove)),
            false,
          );
          await tester.tap(find.byKey(ValueKey('toggle-showcase-$laterId')));
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile), findsNWidgets(2));
          await tester.tap(remove);
          await tester.pumpAndSettle();
          expect(
            store.showcases(conversation.id).any((g) => g.id == folderId),
            false,
          );
          expect(
            store
                .showcases(conversation.id)
                .singleWhere((g) => g.id == laterId)
                .comics
                .single
                .comicId,
            'second',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          store.close();
          local.close();
          appdata.settings['comicDisplayMode'] = previousMode;
          appdata.settings['showFavoriteStatusOnTile'] = previousBadge;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
