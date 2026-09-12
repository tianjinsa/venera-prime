import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_context.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_wire.dart';

import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_images_resources_test.dart' show resourceImage;
import 'agent_test_support.dart';
import 'agent_text_files_test.dart' show textFile;

class _QueueTools extends AgentTools {
  final calls = <String>[];
  AgentJson Function(String name)? respond;
  _QueueTools(super.store);

  @override
  Future<AgentJson> execute(
    String name,
    AgentJson arguments,
    AgentToolContext context,
  ) async {
    context.run.check();
    calls.add(name);
    if (respond != null) return respond!(name);
    return {
      'ok': true,
      'data': {'executed': name},
    };
  }
}

typedef _Reply =
    Future<AgentResponse> Function(
      AgentModel model,
      List<AgentJson> wire,
      AgentRun run,
      AgentDelta delta,
    );

List<Object?> _userContent(List<AgentJson> wire) => [
  for (final message in wire)
    if (message['role'] == 'user') message['content'],
];

void main() {
  late Directory directory;
  late AgentStore store;
  late _QueueTools tools;
  AgentController? controller;
  const model = AgentModel(
    id: 'vision',
    name: '测试模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
    supportsVision: true,
  );

  AgentController attach(_Reply reply) => controller = AgentController(
    store,
    client: ScriptedClient(reply),
    tools: tools,
  );

  AgentMessage savedUser(
    String conversation,
    String text, {
    bool pending = false,
    List<AgentImageDraft> images = const [],
    List<AgentTextDraft> files = const [],
  }) {
    final message = AgentMessage(
      id: agentId(),
      conversationId: conversation,
      role: 'user',
      parts: [
        {'type': 'text', 'text': text},
        for (final image in images) image.attachment.toJson(),
        for (final file in files) file.attachment.toJson(),
      ],
      modelId: model.id,
      createdAt: agentNow(),
      state: pending ? 'pending_task' : 'done',
    );
    store.saveMessageWithAttachments(message, images: images, files: files);
    return message;
  }

  AgentMessage savedAnswer(String conversation, String text) {
    final message = AgentMessage(
      id: agentId(),
      conversationId: conversation,
      role: 'assistant',
      parts: [
        {'type': 'text', 'text': text},
      ],
      modelId: model.id,
      createdAt: agentNow(),
    );
    store.saveMessage(message);
    return message;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-agent-queue-');
    configureAgentTestPaths(directory.path);
    store = await AgentStore.open('${directory.path}/agent');
    await store.saveSettings(const AgentSettings(models: [model]), {});
    tools = _QueueTools(store);
  });

  tearDown(() async {
    controller?.dispose();
    controller = null;
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'FIFO tasks begin only after the preceding multi-round task completes',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        switch (++requests) {
          case 1:
            started.complete();
            return run.wait(first.future);
          case 2:
            expect(_userContent(wire), ['CURRENT']);
            expect(tools.calls, ['list_sources']);
            return const AgentResponse('CURRENT_DONE', '', []);
          case 3:
            expect(_userContent(wire), ['CURRENT', 'NEXT_A']);
            expect(wire[wire.length - 2]['content'], 'CURRENT_DONE');
            return const AgentResponse('A_STEP', '', [
              AgentToolCall('a', 'list_sources', '{}'),
            ]);
          case 4:
            expect(_userContent(wire), ['CURRENT', 'NEXT_A']);
            return const AgentResponse('A_DONE', '', []);
          case 5:
            expect(_userContent(wire), ['CURRENT', 'NEXT_A', 'NEXT_B']);
            expect(wire[wire.length - 2]['content'], 'A_DONE');
            return const AgentResponse('B_DONE', '', []);
          default:
            throw StateError('Unexpected extra request');
        }
      });
      final busyStates = <bool>[];
      c.addListener(() => busyStates.add(c.busy));
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT_A', mode: AgentSendMode.queue);
      await c.send('NEXT_B', mode: AgentSendMode.queue);
      expect(c.pendingMessages.map((message) => message.text), [
        'NEXT_A',
        'NEXT_B',
      ]);
      expect(store.pendingMessages(c.conversation.id), hasLength(2));
      expect(
        c.messages.where((message) => message.role == 'user'),
        hasLength(1),
      );
      first.complete(
        const AgentResponse('CURRENT_STEP', '', [
          AgentToolCall('current', 'list_sources', '{}'),
        ]),
      );

      await active;

      expect(requests, 5);
      expect(c.error, isNull);
      expect(c.pendingMessages, isEmpty);
      expect(busyStates.where((busy) => !busy), hasLength(1));
      expect(c.messages.where((m) => m.role == 'user').map((m) => m.text), [
        'CURRENT',
        'NEXT_A',
        'NEXT_B',
      ]);
      expect(
        c.messages.where((m) => m.role == 'user').every((m) => !m.isFollowUp),
        true,
      );
      expect(
        store.messages(c.conversation.id).map((m) => m.id),
        c.messages.map((m) => m.id),
      );
    },
  );

  test(
    'queueing does not release or replace a pending write confirmation',
    () async {
      await store.saveSettings(
        const AgentSettings(models: [model], confirmPolicy: 'all'),
        {},
      );
      var requests = 0;
      final c = attach((_, wire, _, _) async {
        requests++;
        if (requests == 1) {
          return const AgentResponse('', '', [
            AgentToolCall('write', 'later_add', '{"comics":["jm:123"]}'),
          ]);
        }
        if (requests == 2) expect(_userContent(wire), ['CURRENT']);
        return AgentResponse('DONE_$requests', '', []);
      });
      final confirming = Completer<void>();
      c.addListener(() {
        if (c.confirmation != null && !confirming.isCompleted) {
          confirming.complete();
        }
      });
      final active = c.send('CURRENT');
      await confirming.future;
      final confirmation = c.confirmation;

      await c.send('NEXT_A', mode: AgentSendMode.queue);
      await c.send('NEXT_B', mode: AgentSendMode.queue);
      await Future<void>.delayed(Duration.zero);

      expect(c.confirmation, same(confirmation));
      expect(requests, 1);
      expect(tools.calls, isEmpty);
      c.answerConfirmation(true);
      await active;
      expect(requests, 4);
      expect(tools.calls, ['later_add']);
      expect(c.messages[1].tools.single['state'], 'done');
      expect(c.error, isNull);
    },
  );

  test(
    'insertions finish their own tool rounds before a queued task starts',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        switch (++requests) {
          case 1:
            started.complete();
            return run.wait(first.future);
          case 2:
            expect(_userContent(wire), ['CURRENT', 'CORRECTION']);
            expect(controller!.pendingMessages, hasLength(1));
            return const AgentResponse('APPLYING_CORRECTION', '', [
              AgentToolCall('inspect', 'list_sources', '{}'),
            ]);
          case 3:
            expect(_userContent(wire), ['CURRENT', 'CORRECTION']);
            expect(controller!.pendingMessages, hasLength(1));
            return const AgentResponse('CORRECTED_DONE', '', []);
          case 4:
            expect(_userContent(wire), ['CURRENT', 'CORRECTION', 'NEXT']);
            return const AgentResponse('NEXT_DONE', '', []);
          default:
            throw StateError('Unexpected extra request');
        }
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT', mode: AgentSendMode.queue);
      await c.send('CORRECTION');
      final inserted = c.messages.last;
      expect(inserted.followUpTo, c.messages.first.id);
      first.complete(const AgentResponse('ORIGINAL_RESPONSE', '', []));

      await active;

      expect(requests, 4);
      expect(c.error, isNull);
      expect(inserted.state, 'done');
      expect(tools.calls, ['list_sources']);
      expect(c.messages.singleWhere((m) => m.text == 'NEXT').isFollowUp, false);
    },
  );

  test(
    'an insertion at the final response notification still precedes the queue',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        if (++requests == 1) {
          started.complete();
          return run.wait(first.future);
        }
        expect(
          _userContent(wire),
          requests == 2
              ? ['CURRENT', 'LAST_MOMENT']
              : ['CURRENT', 'LAST_MOMENT', 'NEXT'],
        );
        return AgentResponse('DONE_$requests', '', []);
      });
      var inserted = false;
      c.addListener(() {
        if (!inserted &&
            c.messages.isNotEmpty &&
            c.messages.last.text == 'CURRENT_DONE' &&
            c.messages.last.state == 'done') {
          inserted = true;
          unawaited(c.send('LAST_MOMENT'));
        }
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT', mode: AgentSendMode.queue);
      first.complete(const AgentResponse('CURRENT_DONE', '', []));
      await active;
      expect(inserted, true);
      expect(requests, 3);
      expect(c.error, isNull);
    },
  );

  test(
    'an insertion can cancel confirmation without losing independent queued tasks',
    () async {
      await store.saveSettings(
        const AgentSettings(models: [model], confirmPolicy: 'all'),
        {},
      );
      var requests = 0;
      final c = attach((_, wire, _, _) async {
        if (++requests == 1) {
          return const AgentResponse('', '', [
            AgentToolCall('write', 'later_add', '{"comics":["jm:123"]}'),
          ]);
        }
        if (requests == 2) {
          expect(_userContent(wire), ['CURRENT', 'CANCEL_WRITE']);
          final receipt = jsonDecode(
            wire.singleWhere((m) => m['role'] == 'tool')['content'],
          );
          expect(receipt['error']['code'], 'INPUT_UPDATED');
        } else {
          expect(_userContent(wire), ['CURRENT', 'CANCEL_WRITE', 'NEXT']);
        }
        return AgentResponse('DONE_$requests', '', []);
      });
      final confirming = Completer<void>();
      c.addListener(() {
        if (c.confirmation != null && !confirming.isCompleted) {
          confirming.complete();
        }
      });
      final active = c.send('CURRENT');
      await confirming.future;
      await c.send('NEXT', mode: AgentSendMode.queue);
      await c.send('CANCEL_WRITE');
      await active;
      expect(requests, 3);
      expect(tools.calls, isEmpty);
      expect(c.error, isNull);
    },
  );

  test(
    'pause and reopen preserve FIFO attachments and resume the unfinished task first',
    () async {
      final started = Completer<void>();
      final c = attach((_, _, run, delta) {
        delta('text', 'PARTIAL_CURRENT');
        started.complete();
        return run.wait(Completer<AgentResponse>().future);
      });
      final active = c.send('CURRENT');
      await started.future;
      final image = resourceImage('queue-image');
      final file = textFile('queue-file', 'ONLY_FOR_NEXT_A');
      await c.send(
        'NEXT_A',
        mode: AgentSendMode.queue,
        images: [image],
        files: [file],
      );
      c.stop();
      await active;
      expect(c.hasUnfinishedTask, true);
      await c.send('NEXT_B', mode: AgentSendMode.queue);
      expect(c.busy, false);
      expect(c.pendingMessages, hasLength(2));
      final conversationId = c.conversation.id;
      c.dispose();
      controller = null;
      store = await AgentStore.open('${directory.path}/agent');
      tools = _QueueTools(store);
      var requests = 0;
      final reopened = attach((_, wire, _, _) async {
        requests++;
        if (requests == 1) {
          expect(_userContent(wire), ['CURRENT']);
          expect(jsonEncode(wire), isNot(contains('ONLY_FOR_NEXT_A')));
          expect(jsonEncode(wire), isNot(contains('NEXT_B')));
          return const AgentResponse('CURRENT_DONE', '', []);
        }
        if (requests == 2) {
          final content = _userContent(wire).last as List;
          expect(content.first['text'], 'NEXT_A');
          expect(content[1]['text'], contains('ONLY_FOR_NEXT_A'));
          expect(
            content[2]['image_url']['url'],
            'data:image/png;base64,${base64Encode(image.bytes)}',
          );
          expect(jsonEncode(wire), isNot(contains('NEXT_B')));
        } else {
          expect(_userContent(wire).last, 'NEXT_B');
        }
        return AgentResponse('DONE_$requests', '', []);
      });
      expect(reopened.conversation.id, conversationId);
      expect(reopened.pendingMessages.map((m) => m.text), ['NEXT_A', 'NEXT_B']);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);

      await reopened.resume();

      expect(requests, 3);
      expect(reopened.error, isNull);
      expect(reopened.pendingMessages, isEmpty);
      expect(
        store.imageBytes(conversationId, image.attachment.id),
        image.bytes,
      );
      expect(
        store.textFileBytes(conversationId, file.attachment.id),
        file.bytes,
      );
      expect(
        store.messages(conversationId).map((m) => m.id),
        reopened.messages.map((m) => m.id),
      );
    },
  );

  test(
    'a failed queued task blocks later tasks until it has been resumed',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        requests++;
        if (requests == 1) {
          started.complete();
          return run.wait(first.future);
        }
        if (requests == 2) {
          throw const AgentException('NETWORK_ERROR', '模拟请求失败');
        }
        expect(
          _userContent(wire),
          requests == 3
              ? ['CURRENT', 'NEXT_A']
              : ['CURRENT', 'NEXT_A', 'NEXT_B'],
        );
        return AgentResponse('DONE_$requests', '', []);
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT_A', mode: AgentSendMode.queue);
      await c.send('NEXT_B', mode: AgentSendMode.queue);
      first.complete(const AgentResponse('CURRENT_DONE', '', []));
      await active;

      expect(requests, 2);
      expect(c.error, '模拟请求失败');
      expect(c.messages.last.state, 'failed');
      expect(c.pendingMessages.map((m) => m.text), ['NEXT_B']);
      expect(c.hasUnfinishedTask, true);
      await c.resume();
      expect(requests, 4);
      expect(c.pendingMessages, isEmpty);
      expect(c.error, isNull);
    },
  );

  test(
    'manual compaction does not load or start pending attachments',
    () async {
      final conversation = store.createConversation(modelId: model.id);
      savedUser(conversation.id, 'CURRENT');
      final image = resourceImage('summary-queued-image');
      final file = textFile('summary-queued-file', 'FUTURE_FILE_SECRET');
      savedUser(
        conversation.id,
        'NEXT',
        pending: true,
        images: [image],
        files: [file],
      );
      savedAnswer(conversation.id, 'CURRENT_DONE');
      var requests = 0;
      final c = attach((_, wire, _, _) async {
        if (++requests == 1) {
          expect(wire.last['content'], agentCompactionPrompt);
          expect(jsonEncode(wire), isNot(contains('FUTURE_FILE_SECRET')));
          expect(jsonEncode(wire), isNot(contains('summary-queued-image')));
          expect(_userContent(wire), ['CURRENT', agentCompactionPrompt]);
          return const AgentResponse('已完成 CURRENT', '', []);
        }
        expect(_userContent(wire).last, isA<List>());
        expect(jsonEncode(wire), contains('FUTURE_FILE_SECRET'));
        return const AgentResponse('NEXT_DONE', '', []);
      });
      expect(c.hasUnfinishedTask, false);

      await c.requestCompaction();

      expect(requests, 1);
      expect(c.pendingMessages, hasLength(1));
      expect(c.error, isNull);
      expect(c.contextState.hasSummary, true);
      await c.resume();
      expect(requests, 2);
      expect(c.pendingMessages, isEmpty);
      expect(c.error, isNull);
    },
  );

  test(
    'wire filtering preserves the active root and never reads future attachments',
    () {
      final conversation = store.createConversation(modelId: model.id);
      final current = savedUser(conversation.id, 'CURRENT');
      final pending = savedUser(
        conversation.id,
        'NEXT',
        pending: true,
        images: [resourceImage('future-image')],
        files: [textFile('future-file', 'FUTURE')],
      );
      final answer = savedAnswer(conversation.id, 'CURRENT_DONE');
      final wire = agentWire(
        [current, pending, answer],
        model,
        context: AgentConversationContext(
          summary: '已完成 CURRENT',
          throughMessageId: answer.id,
        ),
        imageDataUrl: (_, _) =>
            throw StateError('Future images must not be read'),
        textFileContent: (_, _) =>
            throw StateError('Future text files must not be read'),
      );
      expect(_userContent(wire), ['CURRENT']);
      expect(jsonEncode(wire), isNot(contains('NEXT')));
    },
  );

  test(
    'cancelling one queued task deletes only its owned attachments',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        if (++requests == 1) {
          started.complete();
          return run.wait(first.future);
        }
        expect(jsonEncode(wire), isNot(contains('DROP')));
        expect(jsonEncode(wire), contains('KEEP'));
        return const AgentResponse('KEEP_DONE', '', []);
      });
      final active = c.send('CURRENT');
      await started.future;
      final image = resourceImage('cancel-image');
      final removedFile = textFile('cancel-file', 'DROP_CONTENT');
      final keptFile = textFile('keep-file', 'KEEP_CONTENT');
      await c.send(
        'DROP',
        mode: AgentSendMode.queue,
        images: [image],
        files: [removedFile],
      );
      await c.send('KEEP', mode: AgentSendMode.queue, files: [keptFile]);
      final keptId = c.pendingMessages.last.id;
      c.cancelQueuedMessage(c.pendingMessages.first.id);

      expect(c.pendingMessages.map((m) => m.text), ['KEEP']);
      expect(store.imageBytes(c.conversation.id, image.attachment.id), isNull);
      expect(
        store.textFileBytes(c.conversation.id, removedFile.attachment.id),
        isNull,
      );
      expect(
        store.textFileBytes(c.conversation.id, keptFile.attachment.id),
        keptFile.bytes,
      );
      first.complete(const AgentResponse('CURRENT_DONE', '', []));
      await active;
      c.cancelQueuedMessage(keptId);
      store.cancelQueuedMessage(c.conversation.id, keptId);
      expect(
        store.messages(c.conversation.id).any((m) => m.id == keptId),
        true,
      );
      expect(
        store.textFileBytes(c.conversation.id, keptFile.attachment.id),
        keptFile.bytes,
      );
      expect(requests, 2);
      expect(c.error, isNull);
    },
  );

  for (final edit in [false, true]) {
    test(
      '${edit ? 'editing' : 'regenerating'} the current task preserves its queue and files',
      () async {
        final started = Completer<void>();
        var requests = 0;
        final c = attach((_, wire, run, _) async {
          if (++requests == 1) {
            started.complete();
            return run.wait(Completer<AgentResponse>().future);
          }
          if (requests == 2) {
            expect(_userContent(wire), [edit ? 'EDITED' : 'CURRENT']);
            expect(controller!.pendingMessages, hasLength(1));
            return const AgentResponse('CURRENT_DONE', '', []);
          }
          expect(jsonEncode(wire), contains('QUEUED_FILE_CONTENT'));
          return const AgentResponse('NEXT_DONE', '', []);
        });
        final active = c.send('CURRENT');
        await started.future;
        final file = textFile('retained-file', 'QUEUED_FILE_CONTENT');
        await c.send('NEXT', mode: AgentSendMode.queue, files: [file]);
        c.stop();
        await active;

        if (edit) {
          await c.editAndResend(c.messages.first, 'EDITED');
        } else {
          await c.regenerate();
        }

        expect(requests, 3);
        expect(c.error, isNull);
        expect(c.pendingMessages, isEmpty);
        expect(
          store.textFileBytes(c.conversation.id, file.attachment.id),
          file.bytes,
        );
      },
    );
  }

  test(
    'editing an unstarted task preserves order and leaves the current request running',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        if (++requests == 1) {
          started.complete();
          return run.wait(first.future);
        }
        expect(
          _userContent(wire).last,
          requests == 2 ? 'EDITED_NEXT_A' : 'NEXT_B',
        );
        return AgentResponse('DONE_$requests', '', []);
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT_A', mode: AgentSendMode.queue);
      await c.send('NEXT_B', mode: AgentSendMode.queue);
      await c.editAndResend(c.pendingMessages.first, 'EDITED_NEXT_A');
      expect(c.busy, true);
      expect(c.isStopping, false);
      expect(requests, 1);
      expect(c.pendingMessages.map((m) => m.text), ['EDITED_NEXT_A', 'NEXT_B']);
      first.complete(const AgentResponse('CURRENT_DONE', '', []));
      await active;
      expect(requests, 3);
      expect(c.error, isNull);
    },
  );

  test(
    'switching conversations preserves a paused queue without running it elsewhere',
    () async {
      final started = Completer<void>();
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        requests++;
        if (requests == 1) {
          started.complete();
          return run.wait(Completer<AgentResponse>().future);
        }
        expect(_userContent(wire), switch (requests) {
          2 => ['OTHER'],
          3 => ['CURRENT'],
          _ => ['CURRENT', 'NEXT'],
        });
        return AgentResponse('DONE_$requests', '', []);
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT', mode: AgentSendMode.queue);
      final original = c.conversation;
      await c.newConversation();
      await active;
      expect(c.pendingMessages, isEmpty);
      await c.send('OTHER');
      await c.selectConversation(original);
      expect(c.pendingMessages.map((m) => m.text), ['NEXT']);
      expect(requests, 2);
      await c.resume();
      expect(requests, 4);
      expect(c.error, isNull);
    },
  );

  test(
    'tool retry ignores future roots and preserves successful write receipts',
    () async {
      final started = Completer<void>();
      final first = Completer<AgentResponse>();
      var reads = 0;
      tools.respond = (name) {
        if (name == 'list_sources' && ++reads == 1) {
          return const AgentException('TIMEOUT', '模拟读取超时').toJson();
        }
        return {
          'ok': true,
          'data': {'executed': name},
        };
      };
      var requests = 0;
      final c = attach((_, wire, run, _) async {
        if (++requests == 1) {
          started.complete();
          return run.wait(first.future);
        }
        if (requests == 2) {
          throw const AgentException('NETWORK_ERROR', '模型请求失败');
        }
        if (requests == 3) {
          expect(_userContent(wire), ['CURRENT']);
          final receipts = wire
              .where((m) => m['role'] == 'tool')
              .map((message) => jsonDecode(message['content']) as Map);
          expect(receipts, hasLength(2));
          expect(receipts.every((receipt) => receipt['ok'] == true), true);
        } else {
          expect(_userContent(wire), ['CURRENT', 'NEXT']);
        }
        return AgentResponse('DONE_$requests', '', []);
      });
      final active = c.send('CURRENT');
      await started.future;
      await c.send('NEXT', mode: AgentSendMode.queue);
      first.complete(
        const AgentResponse('', '', [
          AgentToolCall('write', 'later_add', '{"comics":["jm:123"]}'),
          AgentToolCall('read', 'list_sources', '{}'),
        ]),
      );
      await active;
      final message = c.messages.firstWhere(
        (message) => message.tools.isNotEmpty,
      );
      final failed = message.tools.last;
      expect(c.canRetry(message, failed), true);
      expect(c.pendingMessages, hasLength(1));

      await c.retryTool(message, failed);

      expect(requests, 4);
      expect(tools.calls, ['later_add', 'list_sources', 'list_sources']);
      expect(c.pendingMessages, isEmpty);
      expect(c.error, isNull);
    },
  );

  test(
    'queue mode starts immediately when there is no unfinished task',
    () async {
      var requests = 0;
      final c = attach((_, wire, _, _) async {
        requests++;
        expect(_userContent(wire), ['FIRST']);
        return const AgentResponse('DONE', '', []);
      });
      await c.send('FIRST', mode: AgentSendMode.queue);
      expect(requests, 1);
      expect(c.pendingMessages, isEmpty);
      expect(c.messages.first.isFollowUp, false);
      expect(c.hasUnfinishedTask, false);
      expect(c.error, isNull);
    },
  );
}
