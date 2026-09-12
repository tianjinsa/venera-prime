import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

AgentTextDraft _textFile(String id, String name, String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return AgentTextDraft(
    AgentTextAttachment(
      id: id,
      name: name,
      mimeType: 'text/plain',
      byteLength: bytes.length,
      encoding: 'utf-8',
    ),
    bytes,
  );
}

String _wireText(AgentJson message) {
  final content = message['content'];
  return content is String
      ? content
      : (content as List)
            .where((part) => part['type'] == 'text')
            .map((part) => part['text'])
            .join('\n');
}

void main() {
  const textModel = AgentModel(
    id: 'text',
    name: '文本模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  const visionModel = AgentModel(
    id: 'vision',
    name: '识图模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
    supportsVision: true,
  );
  final attach = find.byKey(const ValueKey('agent-attach'));
  final send = find.byKey(const ValueKey('agent-send'));
  final pause = find.byKey(const ValueKey('agent-stop'));
  final draft = find.byKey(const ValueKey('agent-draft-attachments'));
  final input = find.byKey(const ValueKey('agent-input'));

  Future<void> pick(WidgetTester tester, String kind) async {
    await tester.tap(attach);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('agent-upload-$kind')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> sendWhileRunning(WidgetTester tester, String mode) async {
    await tester.tap(send);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('agent-send-$mode')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> withPage(
    WidgetTester tester,
    Future<void> Function(AgentController, List<List<AgentJson>>) body, {
    double width = 360,
    Future<List<AgentTextDraft>> Function()? filePicker,
    Future<List<AgentImageDraft>> Function()? imagePicker,
    Future<AgentResponse> Function(int)? response,
  }) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('agent-text-file-ui-'),
    ))!;
    configureAgentTestPaths(root.path);
    final store = (await tester.runAsync(
      () => AgentStore.open('${root.path}/agent'),
    ))!;
    await tester.runAsync(
      () => store.saveSettings(
        const AgentSettings(models: [textModel, visionModel]),
        {},
      ),
    );
    final requests = <List<AgentJson>>[];
    final controller = AgentController(
      store,
      client: ScriptedClient((_, wire, run, _) async {
        requests.add(wire);
        return response == null
            ? const AgentResponse('已收到附件', '', [])
            : run.wait(response(requests.length));
      }),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: AgentPage(
            controller: controller,
            filePicker: filePicker,
            imagePicker: imagePicker,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body(controller, requests);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  }

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'file-only and mixed attachments use one menu and preview row at $width',
      (tester) async {
        final removed = _textFile('removed', 'ids.csv', 'id\n339981');
        const jsonText = '{"ids":[339981,1258084]}';
        final kept = _textFile('kept', 'comics.json', jsonText);
        final mixed = _textFile('mixed', '说明.txt', '图片里的漫画加入稍后再看');
        final image = resourceImage('mixed-image');
        var filePicks = 0;
        var imagePicks = 0;
        await withPage(
          tester,
          (controller, requests) async {
            await tester.tap(attach);
            await tester.pumpAndSettle();
            expect(find.text('上传图片'), findsOneWidget);
            expect(find.text('上传文件'), findsOneWidget);
            expect(filePicks, 0);
            expect(imagePicks, 0);
            await tester.tap(find.byKey(const ValueKey('agent-upload-files')));
            await tester.pumpAndSettle();
            expect(filePicks, 1);
            expect(imagePicks, 0);
            expect(draft, findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('remove-file-removed')));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('file-removed')), findsNothing);
            await tester.tap(find.byKey(const ValueKey('file-kept')));
            await tester.pumpAndSettle();
            expect(find.text(jsonText), findsOneWidget);
            await tester.tap(find.byTooltip('关闭文件'));
            await tester.pumpAndSettle();
            await tester.tap(send);
            await tester.pumpAndSettle();
            expect(requests, hasLength(1));
            expect(controller.model!.supportsVision, false);
            final user = requests.single.singleWhere(
              (m) => m['role'] == 'user',
            );
            expect(_wireText(user), contains(jsonText));
            expect(_wireText(user), contains('comics.json'));
            expect(controller.messages.first.files.single.id, 'kept');
            expect(draft, findsNothing);
            await tester.tap(find.byKey(const ValueKey('file-kept')));
            await tester.pumpAndSettle();
            expect(find.text(jsonText), findsOneWidget);
            await tester.tap(find.byTooltip('关闭文件'));
            await tester.pumpAndSettle();

            await pick(tester, 'images');
            await pick(tester, 'files');
            expect(imagePicks, 1);
            expect(filePicks, 2);
            expect(
              tester
                  .getTopLeft(find.byKey(const ValueKey('image-mixed-image')))
                  .dy,
              tester.getTopLeft(find.byKey(const ValueKey('file-mixed'))).dy,
            );
            // A model mismatch must restore both kinds of attachments together.
            await tester.tap(send);
            await tester.pumpAndSettle();
            expect(requests, hasLength(1));
            expect(draft, findsOneWidget);
            expect(find.byKey(const ValueKey('file-mixed')), findsOneWidget);
            expect(
              find.byKey(const ValueKey('image-mixed-image')),
              findsOneWidget,
            );
            ScaffoldMessenger.of(tester.element(send)).hideCurrentSnackBar();
            await tester.pumpAndSettle();
            controller.selectModel(visionModel.id);
            await tester.pumpAndSettle();
            expect(draft, findsOneWidget);
            expect(tester.widget<IconButton>(send).onPressed, isNotNull);
            await tester.tap(send);
            await tester.pumpAndSettle();
            expect(requests.length, 2);
            final lastUser = controller.messages.lastWhere(
              (m) => m.role == 'user',
            );
            expect(lastUser.files.single.id, 'mixed');
            expect(lastUser.images.single.id, 'mixed-image');
            expect(draft, findsNothing);
          },
          width: width,
          filePicker: () async => filePicks++ == 0 ? [removed, kept] : [mixed],
          imagePicker: () async {
            imagePicks++;
            return [image];
          },
        );
      },
    );
  }

  testWidgets(
    'late or failed file selections do not replace another conversation draft',
    (tester) async {
      final selection = Completer<List<AgentTextDraft>>();
      final file = _textFile('late', 'notes.txt', '稍后返回');
      var picks = 0;
      await withPage(
        tester,
        (controller, requests) async {
          await pick(tester, 'files');
          expect(tester.widget<PopupMenuButton>(attach).enabled, false);
          await controller.newConversation();
          await tester.pump();
          await tester.enterText(input, '新对话草稿');
          selection.complete([file]);
          await tester.pumpAndSettle();
          expect(draft, findsNothing);
          expect(tester.widget<TextField>(input).controller!.text, '新对话草稿');
          expect(tester.widget<PopupMenuButton>(attach).enabled, true);
          await pick(tester, 'files');
          await tester.pumpAndSettle();
          expect(find.text('请选择纯文本文件'), findsOneWidget);
          expect(tester.widget<TextField>(input).controller!.text, '新对话草稿');
          expect(draft, findsNothing);
          expect(requests, isEmpty);
          expect(tester.widget<PopupMenuButton>(attach).enabled, true);
        },
        filePicker: () {
          if (picks++ == 0) return selection.future;
          throw const AgentException('INVALID_TEXT_FILE', '请选择纯文本文件');
        },
      );
    },
  );

  testWidgets(
    'file-only supplements switch to insert and stay readable in turn history',
    (tester) async {
      final firstResponse = Completer<AgentResponse>();
      final file = _textFile('supplement', '补充.txt', '只整理这两个ID');
      await withPage(
        tester,
        (controller, requests) async {
          await tester.enterText(input, '开始整理');
          await tester.pump();
          await tester.tap(send);
          await tester.pump();
          expect(controller.busy, true);
          expect(pause, findsOneWidget);
          await pick(tester, 'files');
          expect(send, findsOneWidget);
          expect(pause, findsNothing);
          await sendWhileRunning(tester, 'insert');
          final supplement = controller.messages.last;
          expect(supplement.files.single.id, 'supplement');
          expect(supplement.isFollowUp, true);
          expect(supplement.state, 'queued');
          expect(pause, findsOneWidget);
          firstResponse.complete(const AgentResponse('正在整理', '', []));
          await tester.pumpAndSettle();
          expect(requests, hasLength(2));
          expect(
            _wireText(requests.last.lastWhere((m) => m['role'] == 'user')),
            contains('只整理这两个ID'),
          );
          await tester.tap(find.text('已完成'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('file-supplement')));
          await tester.pumpAndSettle();
          expect(find.text('只整理这两个ID'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭文件'));
          await tester.pumpAndSettle();
        },
        filePicker: () async => [file],
        response: (index) async => index == 1
            ? firstResponse.future
            : const AgentResponse('已收到补充', '', []),
      );
    },
  );

  testWidgets('queued file message waits for the current task to finish', (
    tester,
  ) async {
    final firstResponse = Completer<AgentResponse>();
    final file = _textFile('next-task', '下一项.csv', 'id\n1258084');
    await withPage(
      tester,
      (controller, requests) async {
        await tester.enterText(input, '先整理收藏');
        await tester.pump();
        await tester.tap(send);
        await tester.pump();
        final firstRoot = controller.messages.first.id;
        expect(controller.busy, true);
        await pick(tester, 'files');
        await tester.enterText(input, '完成后整理文件中的漫画');
        await tester.pump();
        await sendWhileRunning(tester, 'queue');

        expect(requests.length, 1);
        expect(controller.pendingMessages, hasLength(1));
        final pendingId = controller.pendingMessages.single.id;
        expect(controller.pendingMessages.single.files.single.id, 'next-task');
        expect(find.text('排队 1 条'), findsOneWidget);
        expect(
          controller.messages.any((message) => message.id == pendingId),
          false,
        );
        expect(draft, findsNothing);
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(pause, findsOneWidget);

        firstResponse.complete(const AgentResponse('收藏已整理完毕', '', []));
        await tester.pumpAndSettle();
        expect(requests.length, 2);
        expect(controller.pendingMessages, isEmpty);
        expect(find.byKey(const ValueKey('agent-queue-open')), findsNothing);
        final nextRoot = controller.messages.singleWhere(
          (message) => message.id == pendingId,
        );
        expect(nextRoot.isFollowUp, false);
        expect(nextRoot.id, isNot(firstRoot));
        final nextInput = requests.last.lastWhere(
          (message) => message['role'] == 'user',
        );
        expect(_wireText(nextInput), contains('完成后整理文件中的漫画'));
        expect(_wireText(nextInput), contains('id\n1258084'));
        expect(controller.busy, false);
      },
      filePicker: () async => [file],
      response: (index) async => index == 1
          ? firstResponse.future
          : const AgentResponse('文件中的漫画已整理完毕', '', []),
    );
  });

  testWidgets('one continue action resumes the stopped task before its queue', (
    tester,
  ) async {
    final firstResponse = Completer<AgentResponse>();
    await withPage(
      tester,
      (controller, requests) async {
        await tester.enterText(input, '当前任务');
        await tester.pump();
        await tester.tap(send);
        await tester.pump();
        await tester.enterText(input, '下一任务');
        await tester.pump();
        await sendWhileRunning(tester, 'queue');
        await tester.tap(pause);
        await tester.pumpAndSettle();
        expect(controller.busy, false);
        expect(controller.error, isNotNull);
        expect(controller.pendingMessages, hasLength(1));
        expect(requests.length, 1);
        expect(find.text('继续'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('agent-queue-resume')));
        await tester.pumpAndSettle();
        expect(requests.length, 3);
        expect(
          _wireText(requests[1].lastWhere((m) => m['role'] == 'user')),
          '当前任务',
        );
        expect(
          _wireText(requests[2].lastWhere((m) => m['role'] == 'user')),
          '下一任务',
        );
        expect(controller.pendingMessages, isEmpty);
        expect(controller.error, isNull);
        expect(controller.busy, false);

        firstResponse.complete(const AgentResponse('已取消请求的迟到结果', '', []));
        await tester.pumpAndSettle();
        expect(requests.length, 3);
        expect(controller.messages.any((m) => m.text.contains('迟到结果')), false);
      },
      response: (index) async => index == 1
          ? firstResponse.future
          : AgentResponse('任务 $index 已完成', '', []),
    );
  });
}
