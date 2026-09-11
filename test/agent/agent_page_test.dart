import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_integration.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/components/components.dart' show NaviPane, ComicTile;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/translations.dart';
import 'agent_test_support.dart';

void main() {
  test('legacy launch values retain the four upstream page meanings', () {
    expect([0, 1, 2, 3].map(agentInitialPage), [0, 1, 3, 4]);
    expect(['0', '1', '2', '3'].map(agentInitialPage), [0, 1, 3, 4]);
    for (final value in [null, -1, 4, 'invalid']) {
      expect(agentInitialPage(value), 0);
    }
    expect(agentTabIndex, 2);
  });

  for (final width in [320.0, 800.0, 1200.0]) {
    testWidgets('Agent layout and local settings work at width $width', (
      tester,
    ) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('agent-page-'),
      ))!;
      configureAgentTestPaths(root.path);
      final store = (await tester.runAsync(
        () => AgentStore.open('${root.path}/agent'),
      ))!;
      final controller = AgentController(
        store,
        client: AgentClient(dio: Dio()),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      try {
        await tester.pumpWidget(
          MaterialApp(home: AgentPage(controller: controller)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('agent-input')), findsOneWidget);
        expect(find.text('先连接一个模型'), findsOneWidget);
        expect(find.text('展示漫画'), width >= 720 ? findsOneWidget : findsNothing);
        expect(
          find.text('历史对话'),
          width >= 1024 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), null);
        if (width < 720) {
          await tester.tap(find.byTooltip('展示漫画'));
          await tester.pumpAndSettle();
          expect(find.text('Agent 展示或加入收藏、稍后再看的漫画会出现在这里'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('agent-settings')));
        await tester.pumpAndSettle();
        expect(find.text('Agent 模型设置'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('agent-add-model')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('agent-model-name')), findsOneWidget);
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'actual MainPage inserts Agent at the center and maps existing defaults',
    (tester) async {
      await AppTranslation.init();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('agent-navigation-'),
      ))!;
      configureAgentTestPaths(root.path);
      final old = appdata.settings['initialPage'];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      try {
        for (final initial in ['2', '3']) {
          appdata.settings['initialPage'] = initial;
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              home: MainPage(key: ValueKey(initial)),
            ),
          );
          await tester.pumpAndSettle();
          final pane = tester.widget<NaviPane>(find.byType(NaviPane));
          expect(pane.paneItems.length, 5);
          expect(pane.paneItems[2].label, 'Agent');
          expect(pane.pageBuilder(2), isA<AgentPage>());
          expect(pane.initialPage, initial == '2' ? 3 : 4);
          expect(
            pane.pageBuilder(pane.initialPage),
            initial == '2' ? isA<ExplorePage>() : isA<CategoriesPage>(),
          );
          expect(appdata.settings['initialPage'], initial);
          expect(tester.takeException(), null);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        appdata.settings['initialPage'] = old;
        App.mainNavigatorKey = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  for (final mode in ['detailed', 'brief']) {
    testWidgets('filled conversation and comic showcase fit the $mode layout', (
      tester,
    ) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('agent-filled-'),
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
        // Source initialization can start an unawaited settings migration.
        // Drain its serialized save before the temporary directory is removed.
        await appdata.saveData(false);
      });
      final store = (await tester.runAsync(
        () => AgentStore.open('${root.path}/agent'),
      ))!;
      final controller = AgentController(
        store,
        client: AgentClient(dio: Dio()),
      );
      const comic = AgentComic(
        sourceKey: 'local',
        comicId: 'missing',
        title: '一本真实漫画',
      );
      store.remember(controller.conversation.id, comic);
      store.addShowcase(controller.conversation.id, [comic], title: '搜索结果');
      store.saveMessage(
        AgentMessage(
          id: 'answer',
          conversationId: controller.conversation.id,
          role: 'assistant',
          createdAt: 1,
          parts: [
            {
              'type': 'text',
              'text':
                  '## 推荐结果\n\n**已找到**，请查看展示栏。\n\n'
                  '| 非常长的表格标题一 | 非常长的表格标题二 | 非常长的表格标题三 |\n'
                  '| --- | --- | --- |\n| 内容一 | 内容二 | 内容三 |\n\n'
                  '![远程图片](https://example.invalid/tracking.png)',
            },
          ],
        ),
      );
      controller.reload();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      try {
        await tester.pumpWidget(
          MaterialApp(home: AgentPage(controller: controller)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ComicTile), findsOneWidget);
        final comicRect = tester.getRect(find.byType(ComicTile));
        final removeRect = tester.getRect(find.byTooltip('从展示中移除'));
        expect(comicRect.overlaps(removeRect), false);
        expect(find.text('[图片已省略]'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), null);
        await tester.tap(find.byTooltip('从展示中移除'));
        await tester.pumpAndSettle();
        expect(store.showcases(controller.conversation.id), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        local.close();
        appdata.settings['comicDisplayMode'] = previousMode;
        appdata.settings['showFavoriteStatusOnTile'] = previousBadge;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }

  for (final width in [360.0, 1200.0]) {
    testWidgets(
      'Agent groups activity between prose and resets disclosures after completion at $width',
      (tester) async {
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('agent-steps-'),
        ))!;
        configureAgentTestPaths(root.path);
        final store = (await tester.runAsync(
          () => AgentStore.open('${root.path}/agent'),
        ))!;
        final controller = AgentController(
          store,
          client: AgentClient(dio: Dio()),
        );
        store.saveMessage(
          AgentMessage(
            id: 'user',
            conversationId: controller.conversation.id,
            role: 'user',
            createdAt: 1,
            parts: [
              {'type': 'text', 'text': '演示一次多步骤 Agent 执行过程'},
            ],
          ),
        );
        for (var i = 1; i <= 3; i++) {
          final names = switch (i) {
            1 => ['list_sources', 'list_search_options'],
            2 => ['search_source', 'showcase_comics'],
            _ => <String>[],
          };
          store.saveMessage(
            AgentMessage(
              id: 'step-$i',
              conversationId: controller.conversation.id,
              role: 'assistant',
              createdAt: i + 1,
              parts: [
                {'type': 'reasoning', 'text': '思考步骤$i'},
                {'type': 'text', 'text': '正文步骤$i'},
                for (final name in names)
                  {
                    'type': 'tool_call',
                    'id': '$i-$name',
                    'name': name,
                    'arguments': <String, dynamic>{},
                    'state': 'done',
                    'result': {'ok': true, 'data': <String, dynamic>{}},
                  },
              ],
            ),
          );
          if (i == 2) {
            store.saveMessage(
              AgentMessage(
                id: 'supplement',
                conversationId: controller.conversation.id,
                role: 'user',
                createdAt: 4,
                parts: [
                  {'type': 'text', 'text': '运行中的补充要求', 'follow_up_to': 'user'},
                ],
              ),
            );
          }
        }
        controller.reload();
        controller.busy = true;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 2400);
        try {
          await tester.pumpWidget(
            MaterialApp(home: AgentPage(controller: controller)),
          );
          await tester.pump();
          expect(find.text('执行过程'), findsNWidgets(4));
          expect(find.text('思考过程'), findsNothing);
          expect(find.text('运行中的补充要求'), findsOneWidget);
          expect(
            tester
                .widgetList<MarkdownBody>(find.byType(MarkdownBody))
                .map((w) => w.data),
            ['正文步骤1', '正文步骤2', '正文步骤3'],
          );
          for (final label in ['查看漫画源', '读取搜索选项', '搜索漫画']) {
            expect(find.text(label), findsNothing);
          }
          expect(find.textContaining('第 1 步'), findsNothing);

          Future<void> toggle(String id) async {
            await tester.tap(find.byKey(ValueKey('toggle-$id')));
            await tester.pump(const Duration(milliseconds: 200));
          }

          await toggle('activity-step-1-0');
          expect(find.text('思考过程'), findsOneWidget);
          expect(find.text('思考步骤1'), findsNothing);
          await toggle('activity-step-1-2');
          // The next response's reasoning shares a group with the previous
          // response's tools; only visible prose and user input divide groups.
          expect(find.text('思考过程'), findsNWidgets(2));
          expect(find.text('查看漫画源'), findsOneWidget);
          expect(find.text('读取搜索选项'), findsOneWidget);
          expect(find.text('搜索漫画'), findsNothing);
          expect(find.text('思考步骤2'), findsNothing);
          expect(find.textContaining('"tool": "list_sources"'), findsNothing);
          await toggle('reasoning-step-1-0');
          await toggle('reasoning-step-2-0');
          expect(find.text('思考步骤1'), findsOneWidget);
          expect(find.text('思考步骤2'), findsOneWidget);
          expect(find.text('思考步骤3'), findsNothing);
          await toggle('tool-step-1-2');
          await toggle('tool-step-1-3');
          expect(find.textContaining('"tool": "list_sources"'), findsOneWidget);
          expect(
            find.textContaining('"tool": "list_search_options"'),
            findsOneWidget,
          );
          await toggle('reasoning-step-1-0');
          expect(find.text('思考步骤1'), findsNothing);
          expect(find.text('思考步骤2'), findsOneWidget);
          await toggle('reasoning-step-1-0');
          expect(find.text('思考步骤1'), findsOneWidget);
          await toggle('activity-step-1-2');
          expect(find.text('思考步骤2'), findsNothing);
          expect(find.text('查看漫画源'), findsNothing);
          await toggle('activity-step-1-2');
          expect(find.text('思考步骤2'), findsOneWidget);
          expect(find.textContaining('"tool": "list_sources"'), findsOneWidget);
          controller.reload();
          await tester.pump();
          expect(find.text('思考步骤2'), findsOneWidget);
          controller.busy = false;
          controller.reload();
          await tester.pumpAndSettle();
          expect(
            tester
                .widgetList<MarkdownBody>(find.byType(MarkdownBody))
                .map((w) => w.data),
            ['正文步骤3'],
          );
          expect(find.text('运行中的补充要求'), findsNothing);
          expect(find.text('演示一次多步骤 Agent 执行过程'), findsOneWidget);
          expect(find.text('思考步骤1'), findsNothing);
          expect(find.text('查看漫画源'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('toggle-turn-step-1')));
          await tester.pumpAndSettle();
          expect(find.text('运行中的补充要求'), findsOneWidget);
          expect(
            tester
                .widgetList<MarkdownBody>(find.byType(MarkdownBody))
                .map((w) => w.data),
            ['正文步骤1', '正文步骤2', '正文步骤3'],
          );
          expect(find.text('执行过程'), findsNWidgets(4));
          expect(find.text('思考过程'), findsNothing);
          expect(find.text('思考步骤1'), findsNothing);
          expect(find.text('查看漫画源'), findsNothing);
          await toggle('activity-step-1-2');
          expect(find.text('查看漫画源'), findsOneWidget);
          expect(find.text('思考过程'), findsOneWidget);
          expect(find.text('思考步骤2'), findsNothing);
          expect(find.textContaining('"tool": "list_sources"'), findsNothing);
          await toggle('reasoning-step-2-0');
          expect(find.text('思考步骤2'), findsOneWidget);
          await toggle('tool-step-1-2');
          expect(find.textContaining('"tool": "list_sources"'), findsOneWidget);
          expect(tester.takeException(), null);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
