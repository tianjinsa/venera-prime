import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_page.dart';
import 'package:venera/agent/agent_store.dart';
import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_images_resources_test.dart' show resourceImage;
import 'agent_test_support.dart';

void main() {
  const model = AgentModel(
    id: 'vision',
    name: '识图模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
    supportsVision: true,
  );
  const textModel = AgentModel(
    id: 'text',
    name: '文本模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );

  for (final width in [320.0, 1200.0]) {
    testWidgets('images can be previewed, removed and sent alone at $width', (
      tester,
    ) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('agent-image-ui-'),
      ))!;
      configureAgentTestPaths(root.path);
      final store = (await tester.runAsync(
        () => AgentStore.open('${root.path}/agent'),
      ))!;
      await tester.runAsync(
        () => store.saveSettings(
          const AgentSettings(models: [model, textModel]),
          {},
        ),
      );
      final images = [resourceImage('first'), resourceImage('second')];
      final nextImage = resourceImage('next');
      var picks = 0;
      final requests = <List<AgentJson>>[];
      final controller = AgentController(
        store,
        client: ScriptedClient((_, wire, _, _) async {
          requests.add(wire);
          return const AgentResponse('已收到图片', '', []);
        }),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AgentPage(
              controller: controller,
              imagePicker: () async => picks++ == 0 ? images : [nextImage],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('agent-draft-images')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('image-first')), findsOneWidget);
        expect(find.byKey(const ValueKey('image-second')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('image-second')));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.text('second.png'), findsWidgets);
        await tester.tap(find.byTooltip('关闭图片'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('remove-image-first')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('image-first')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        final content =
            requests.single.firstWhere((m) => m['role'] == 'user')['content']
                as List;
        expect(content.single['type'], 'image_url');
        expect(find.byKey(const ValueKey('agent-draft-images')), findsNothing);
        expect(controller.messages.first.images.single.id, 'second');
        expect(find.byKey(const ValueKey('image-second')), findsOneWidget);
        expect(
          store.imageBytes(controller.conversation.id, 'second'),
          images.last.bytes,
        );

        controller.selectModel(textModel.id);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('agent-draft-images')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('image-next')), findsOneWidget);
        expect(requests, hasLength(1));
        expect(find.textContaining('请先在模型设置中开启'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });

    testWidgets(
      'history shows sizes and bulk-deletes only selected search results at $width',
      (tester) async {
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('agent-history-ui-'),
        ))!;
        configureAgentTestPaths(root.path);
        final store = (await tester.runAsync(
          () => AgentStore.open('${root.path}/agent'),
        ))!;
        await tester.runAsync(
          () => store.saveSettings(const AgentSettings(models: [model]), {}),
        );
        final first = store.createConversation();
        first.title = '清理甲';
        store.saveConversation(first);
        final second = store.createConversation();
        second.title = '清理乙';
        store.saveConversation(second);
        for (final conversation in [first, second]) {
          final image = resourceImage(conversation.id);
          store.saveMessageWithImages(
            AgentMessage(
              id: 'user-${conversation.id}',
              conversationId: conversation.id,
              role: 'user',
              createdAt: 1,
              parts: [
                {'type': 'text', 'text': '图片和消息'},
                image.attachment.toJson(),
              ],
            ),
            [image],
          );
        }
        final keep = store.createConversation(modelId: model.id);
        keep.title = '保留';
        store.saveConversation(keep);
        final controller = AgentController(
          store,
          client: ScriptedClient(
            (_, _, _, _) async => const AgentResponse('', '', []),
          ),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        try {
          await tester.pumpWidget(
            MaterialApp(home: AgentPage(controller: controller)),
          );
          await tester.pumpAndSettle();
          if (width < 1024) {
            await tester.tap(find.byTooltip('历史对话'));
            await tester.pumpAndSettle();
          }
          for (final conversation in controller.conversations) {
            expect(
              tester
                  .widget<Text>(
                    find.byKey(ValueKey('history-size-${conversation.id}')),
                  )
                  .data,
              '约 ${agentFormatBytes(conversation.storageBytes)}',
            );
          }
          final search = find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == '搜索对话',
          );
          await tester.enterText(search, '清理');
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('history-${keep.id}')), findsNothing);
          await tester.tap(find.byKey(const ValueKey('agent-history-manage')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('history-${first.id}')));
          await tester.pumpAndSettle();
          expect(find.text('已选 1 段'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('agent-history-select-all')),
          );
          await tester.pumpAndSettle();
          expect(find.text('已选 2 段'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('agent-history-delete-selected')),
          );
          await tester.pumpAndSettle();
          expect(find.text('删除 2 段对话？'), findsOneWidget);
          expect(find.textContaining('图片、文字、工具运行记录'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(store.conversations(), hasLength(3));
          expect(find.text('已选 2 段'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('agent-history-delete-selected')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('agent-confirm-delete')));
          await tester.pumpAndSettle();
          expect(store.conversations().map((c) => c.id), [keep.id]);
          expect(store.imageBytes(first.id, first.id), isNull);
          expect(store.imageBytes(second.id, second.id), isNull);
          expect(controller.conversation.id, keep.id);
          expect(find.text('没有匹配的对话'), findsOneWidget);
          expect(tester.takeException(), isNull);
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
