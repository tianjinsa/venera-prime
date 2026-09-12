import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_queue_view.dart';
import 'package:venera/agent/agent_store.dart';

import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_images_resources_test.dart' show resourceImage;
import 'agent_test_support.dart';

class _QueueFixture {
  final AgentController controller;
  final bool applyCancellation;
  int resumeCalls = 0;
  final cancelled = <String>[];

  _QueueFixture(this.controller, {required this.applyCancellation});

  void resume() => resumeCalls++;

  void cancel(String id) {
    cancelled.add(id);
    if (applyCancellation) controller.cancelQueuedMessage(id);
  }

  AgentMessage add(
    String id,
    String text, {
    List<AgentImageDraft> images = const [],
    List<AgentTextDraft> files = const [],
  }) {
    final message = AgentMessage(
      id: id,
      conversationId: controller.conversation.id,
      role: 'user',
      parts: [
        {'type': 'text', 'text': text},
        for (final image in images) image.attachment.toJson(),
        for (final file in files) file.attachment.toJson(),
      ],
      modelId: controller.model!.id,
      createdAt: agentNow(),
      state: 'pending_task',
    );
    controller.store.saveMessageWithAttachments(
      message,
      images: images,
      files: files,
    );
    controller.reload();
    return message;
  }
}

void main() {
  const open = ValueKey('agent-queue-open');
  const resume = ValueKey('agent-queue-resume');
  const panel = ValueKey('agent-queue-panel');
  const panelResume = ValueKey('agent-queue-panel-resume');
  const model = AgentModel(
    id: 'test',
    name: '测试模型',
    model: 'test',
    baseUrl: 'https://example.invalid/v1',
    supportsVision: true,
  );

  Future<void> withQueue(
    WidgetTester tester,
    Future<void> Function(_QueueFixture) body, {
    bool applyCancellation = true,
    double textScale = 1,
    ScriptedClient? client,
  }) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('venera-agent-queue-view-'),
    ))!;
    configureAgentTestPaths(root.path);
    final store = (await tester.runAsync(
      () => AgentStore.open('${root.path}/agent'),
    ))!;
    await tester.runAsync(
      () => store.saveSettings(const AgentSettings(models: [model]), {}),
    );
    final controller = AgentController(
      store,
      client:
          client ??
          ScriptedClient(
            (_, _, _, _) async => const AgentResponse('完成', '', []),
          ),
    );
    final fixture = _QueueFixture(
      controller,
      applyCancellation: applyCancellation,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    try {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Expanded(child: Center(child: Text('聊天记录'))),
                AgentQueueStatus(
                  controller: controller,
                  onResume: fixture.resume,
                  onCancel: fixture.cancel,
                ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body(fixture);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  }

  testWidgets(
    'empty queues take no height and pending content stays collapsed',
    (tester) async {
      await withQueue(tester, (fixture) async {
        expect(tester.getSize(find.byType(AgentQueueStatus)).height, 0);
        expect(find.byKey(open), findsNothing);
        fixture.add('first', '不能占据默认聊天空间的第一条消息');
        fixture.add('second', '只能在面板里查看的第二条消息');
        await tester.pumpAndSettle();
        expect(find.text('排队 2 条'), findsOneWidget);
        expect(find.text('不能占据默认聊天空间的第一条消息'), findsNothing);
        expect(find.text('只能在面板里查看的第二条消息'), findsNothing);
        expect(
          tester.getSize(find.byType(AgentQueueStatus)).height,
          lessThanOrEqualTo(48),
        );
        expect(fixture.controller.error, isNull);
        await tester.tap(find.byKey(resume));
        expect(fixture.resumeCalls, 1);
        expect(fixture.controller.pendingMessages, hasLength(2));
      });
    },
  );

  testWidgets(
    'the panel keeps FIFO order and updates numbers after cancellation',
    (tester) async {
      await withQueue(tester, (fixture) async {
        fixture.add('first', '第一条原始内容\n包含完整换行');
        fixture.add('second', '第二条原始内容');
        fixture.add('third', '第三条原始内容');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        expect(find.byKey(panel), findsOneWidget);
        expect(find.text('第 1 条'), findsOneWidget);
        expect(find.text('第 2 条'), findsOneWidget);
        final first = find.byKey(const ValueKey('agent-queue-item-first'));
        final second = find.byKey(const ValueKey('agent-queue-item-second'));
        expect(
          tester.getTopLeft(first).dy,
          lessThan(tester.getTopLeft(second).dy),
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is SelectableText &&
                      widget.data == '第一条原始内容\n包含完整换行',
                ),
              )
              .maxLines,
          isNull,
        );
        await tester.tap(find.byKey(panelResume));
        expect(fixture.resumeCalls, 1);
        await tester.tap(
          find.byKey(const ValueKey('agent-queue-cancel-first')),
        );
        await tester.pumpAndSettle();
        expect(fixture.cancelled, ['first']);
        expect(
          find.byKey(const ValueKey('agent-queue-item-first')),
          findsNothing,
        );
        expect(
          find.descendant(of: second, matching: find.text('第 1 条')),
          findsOneWidget,
        );
        expect(find.text('排队 2 条'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('agent-queue-cancel-second')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('agent-queue-cancel-third')),
        );
        await tester.pumpAndSettle();
        expect(fixture.cancelled, ['first', 'second', 'third']);
        expect(find.text('暂无排队消息'), findsOneWidget);
        expect(find.byKey(open), findsNothing);
        expect(tester.getSize(find.byType(AgentQueueStatus)).height, 0);
        expect(find.byKey(panelResume), findsNothing);
      });
    },
  );

  testWidgets(
    'queued images and files preview fully and cancellation only calls its callback',
    (tester) async {
      const fileText = '漫画ID\n339981\n1258084\n完整尾部';
      final bytes = Uint8List.fromList(utf8.encode(fileText));
      final file = AgentTextDraft(
        AgentTextAttachment(
          id: 'ids',
          name: 'ids.csv',
          mimeType: 'text/csv',
          byteLength: bytes.length,
        ),
        bytes,
      );
      final image = resourceImage('queue-cover');
      await withQueue(tester, (fixture) async {
        fixture.add('attachments', '处理这些图片与列表', files: [file], images: [image]);
        await tester.pumpAndSettle();
        expect(find.text('ids.csv'), findsNothing);
        expect(find.text('queue-cover.png'), findsNothing);
        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        expect(find.text('ids.csv'), findsOneWidget);
        expect(find.text('queue-cover.png'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('file-ids')));
        await tester.pumpAndSettle();
        expect(find.text(fileText), findsOneWidget);
        await tester.tap(find.byTooltip('关闭文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('image-queue-cover')));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        await tester.tap(find.byTooltip('关闭图片'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('agent-queue-cancel-attachments')),
        );
        await tester.pumpAndSettle();
        expect(fixture.cancelled, ['attachments']);
        expect(fixture.controller.pendingMessages.single.id, 'attachments');
        expect(
          fixture.controller.store.textFileBytes(
            fixture.controller.conversation.id,
            'ids',
          ),
          bytes,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.resumeCalls, 0);
      }, applyCancellation: false);
    },
  );

  testWidgets(
    'busy panels show waiting and track promotion without touching the active task',
    (tester) async {
      final rootResponse = Completer<AgentResponse>();
      final queuedResponse = Completer<AgentResponse>();
      final requests = <List<AgentJson>>[];
      final client = ScriptedClient((_, wire, run, _) {
        requests.add(wire);
        return run.wait(
          requests.length == 1 ? rootResponse.future : queuedResponse.future,
        );
      });
      await withQueue(tester, (fixture) async {
        final controller = fixture.controller;
        final task = controller.send('已经开始的任务');
        await tester.pump();
        await controller.send('第一条未来任务', mode: AgentSendMode.queue);
        await controller.send('第二条未来任务', mode: AgentSendMode.queue);
        final firstId = controller.pendingMessages.first.id;
        final secondId = controller.pendingMessages.last.id;
        await tester.pumpAndSettle();
        expect(controller.busy, true);
        expect(find.byKey(resume), findsNothing);
        expect(find.text('等待'), findsOneWidget);
        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        expect(find.byKey(panelResume), findsNothing);
        expect(find.text('已经开始的任务'), findsNothing);
        rootResponse.complete(const AgentResponse('当前任务完成', '', []));
        await tester.pumpAndSettle();
        expect(requests, hasLength(2));
        expect(controller.pendingMessages.single.id, secondId);
        expect(find.byKey(ValueKey('agent-queue-item-$firstId')), findsNothing);
        final remaining = find.byKey(ValueKey('agent-queue-item-$secondId'));
        expect(
          find.descendant(of: remaining, matching: find.text('第 1 条')),
          findsOneWidget,
        );
        expect(find.byKey(panelResume), findsNothing);
        await tester.tap(find.byKey(ValueKey('agent-queue-cancel-$secondId')));
        await tester.pumpAndSettle();
        expect(fixture.cancelled, [secondId]);
        expect(controller.busy, true);
        expect(controller.messages.any((m) => m.id == firstId), true);
        expect(controller.messages.any((m) => m.text == '当前任务完成'), true);
        expect(controller.messages.any((m) => m.id == secondId), false);
        expect(find.text('暂无排队消息'), findsOneWidget);
        queuedResponse.complete(const AgentResponse('第一条未来任务完成', '', []));
        await task;
        await tester.pumpAndSettle();
        expect(controller.error, isNull);
        expect(fixture.resumeCalls, 0);
      }, client: client);
    },
  );

  testWidgets(
    '320-wide screens retain complete long text without layout overflow',
    (tester) async {
      final content = '${'这是一段较长的排队消息，需要能够在面板里完整滚动阅读。\n' * 12}最后一句完整保留';
      await withQueue(tester, (fixture) async {
        fixture.add('long', content);
        await tester.pumpAndSettle();
        expect(find.text('排队 1 条'), findsOneWidget);
        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        final text = tester.widget<SelectableText>(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == content,
          ),
        );
        expect(text.data, content);
        expect(text.maxLines, isNull);
        expect(tester.getSize(find.byKey(panel)).width, lessThanOrEqualTo(320));
        await tester.drag(
          find.byKey(const ValueKey('agent-queue-list')),
          const Offset(0, -450),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ListView>(find.byKey(const ValueKey('agent-queue-list')))
              .controller!
              .offset,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      }, textScale: 1.8);
    },
  );
}
