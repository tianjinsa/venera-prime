import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_storage_tools_test.dart' show TestSource, details;
import 'agent_test_support.dart';

class ScriptedClient extends AgentClient {
  final Future<AgentResponse> Function(
    AgentModel,
    List<AgentJson>,
    AgentRun,
    AgentDelta,
  )
  respond;
  final requests = <String>[];
  final toolRequests = <List<AgentJson>>[];
  ScriptedClient(this.respond) : super(dio: Dio());
  @override
  Future<AgentResponse> complete({
    required AgentModel model,
    required String apiKey,
    required String? thinkingId,
    required List<AgentJson> messages,
    required List<AgentJson> tools,
    required AgentRun run,
    required AgentDelta onDelta,
  }) {
    requests.add('${model.id}:$thinkingId');
    toolRequests.add(tools);
    return respond(model, messages, run, onDelta);
  }
}

void main() {
  late Directory root;
  late AgentStore store;
  late LocalFavoritesManager favorites;
  late ReadLaterManager later;
  late AgentTools tools;
  late List<ComicSource> sources;
  AgentController? controller;
  const model = AgentModel(
    id: 'original',
    name: '原模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  const other = AgentModel(
    id: 'other',
    name: '其他模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  const comic = AgentComic(sourceKey: 'jm', comicId: '123', title: '真实漫画');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-agent-controller-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    favorites = LocalFavoritesManager()..close();
    later = ReadLaterManager()..close();
    await favorites.init();
    await later.init();
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(
      const AgentSettings(models: [model, other], defaultModelId: 'original'),
      {},
    );
    sources = [];
    tools = AgentTools(
      store,
      favorites: favorites,
      later: later,
      initializeSources: () async {},
      sources: () => sources,
    );
  });
  tearDown(() async {
    controller?.dispose();
    controller = null;
    store.close();
    favorites.close();
    later.close();
    await root.delete(recursive: true);
  });

  test(
    'end-to-end turn persists effects, showcase, and original model on regeneration',
    () async {
      var requests = 0;
      final client = ScriptedClient((_, messages, _, _) async {
        requests++;
        if (requests.isOdd) {
          return const AgentResponse('', '', [
            AgentToolCall('add', 'later_add', '{"comics":["jm:123"]}'),
            AgentToolCall(
              'show',
              'showcase_comics',
              '{"comics":["jm:123"],"title":"结果"}',
            ),
          ]);
        }
        expect(messages.where((m) => m['role'] == 'tool').length, 2);
        return const AgentResponse('**完成**，已在展示栏列出。', '', []);
      });
      controller = AgentController(store, client: client, tools: tools);
      final c = controller!;
      store.remember(c.conversation.id, comic);
      await c.send('加入稍后再看');
      expect(later.getAll().length, 1);
      expect(c.showcases.where((g) => g.kind == 'discovery').length, 1);
      expect(c.showcases.where((g) => g.kind == 'later').length, 1);
      expect(c.messages.length, 3);
      expect(c.messages.last.text, contains('完成'));
      expect(store.messages(c.conversation.id).last.state, 'done');
      c.selectModel('other');
      await c.regenerate();
      expect(
        client.requests.every((request) => request.startsWith('original:')),
        true,
      );
      expect(later.getAll().length, 1);
      expect(c.showcases.where((g) => g.kind == 'discovery').length, 2);
      expect(c.showcases.where((g) => g.kind == 'later').length, 1);
      expect(
        c.messages[1].tools.first['result']['data']['summary']['skipped'],
        1,
      );
    },
  );

  test(
    'retry failed read tool preserves successful writes in the same and later rounds',
    () async {
      var requests = 0;
      final client = ScriptedClient((_, wire, _, _) async {
        requests++;
        if (requests == 1) {
          return const AgentResponse('', '', [
            AgentToolCall(
              'bad',
              'list_search_options',
              '{"source_key":"missing"}',
            ),
            AgentToolCall('good', 'later_add', '{"comics":["jm:123"]}'),
          ]);
        }
        if (requests == 2) {
          return const AgentResponse('', '', [
            AgentToolCall('later', 'later_add', '{"comics":["jm:456"]}'),
          ]);
        }
        if (requests > 3) {
          expect(
            wire
                .where((m) => m['role'] == 'tool')
                .map((m) => m['tool_call_id']),
            ['bad', 'good', 'later'],
          );
        }
        return const AgentResponse('回复', '', []);
      });
      controller = AgentController(store, client: client, tools: tools);
      final c = controller!;
      store.remember(c.conversation.id, comic);
      store.remember(
        c.conversation.id,
        const AgentComic(sourceKey: 'jm', comicId: '456', title: '后续漫画'),
      );
      await c.send('整理漫画');
      final message = c.messages[1];
      final failed = message.tools.first;
      expect(c.canRetry(message, failed), true);
      sources.add(TestSource('missing'));
      var writes = 0;
      void listener() {
        writes++;
      }

      later.addListener(listener);
      await c.retryTool(message, failed);
      later.removeListener(listener);
      expect(writes, 0);
      expect(failed['state'], 'done');
      expect(later.getAll().length, 2);
      expect(
        store
            .messages(c.conversation.id)
            .expand((m) => m.tools)
            .map((p) => p['id']),
        ['bad', 'good', 'later'],
      );
      expect(c.messages.last.text, '回复');
    },
  );

  test(
    'stop followed by a late source completion cannot write or mutate the conversation',
    () async {
      final pending = Completer<Res<ComicDetails>>();
      final started = Completer<void>();
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^\d+$'),
          loadComicInfo: (_) {
            started.complete();
            return pending.future;
          },
        ),
      );
      var calls = 0;
      final client = ScriptedClient((_, _, _, _) async {
        calls++;
        return calls == 1
            ? const AgentResponse('', '', [
                AgentToolCall('slow', 'later_add', '{"comics":["jm:123"]}'),
              ])
            : const AgentResponse('已根据现有记录继续。', '', []);
      });
      controller = AgentController(store, client: client, tools: tools);
      final c = controller!;
      final task = c.send('将 123 加入稍后再看');
      await started.future;
      c.stop();
      await task.timeout(const Duration(seconds: 2));
      expect(c.busy, false);
      expect(c.messages.last.state, 'interrupted');
      expect(
        c.messages.last.tools.single['result']['error']['code'],
        'CANCELLED',
      );
      pending.complete(Res(details('jm', '123')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(later.getAll(), isEmpty);
      await c.resume();
      expect(later.getAll(), isEmpty);
      expect(c.messages.last.text, '已根据现有记录继续。');
    },
  );

  test('confirmation is opt-in and cancellation releases its wait', () async {
    await store.saveSettings(
      const AgentSettings(models: [model], confirmPolicy: 'all'),
      {},
    );
    final client = ScriptedClient(
      (_, _, _, _) async => const AgentResponse('', '', [
        AgentToolCall('add', 'later_add', '{"comics":["jm:123"]}'),
      ]),
    );
    controller = AgentController(store, client: client, tools: tools);
    final c = controller!;
    store.remember(c.conversation.id, comic);
    final waiting = Completer<void>();
    c.addListener(() {
      if (c.confirmation != null && !waiting.isCompleted) waiting.complete();
    });
    final task = c.send('加入稍后再看');
    await waiting.future.timeout(const Duration(seconds: 2));
    expect(later.getAll(), isEmpty);
    c.stop();
    await task.timeout(const Duration(seconds: 2));
    expect(c.confirmation, null);
    expect(later.getAll(), isEmpty);
  });

  test(
    'dispose saves interrupted text and discards late network output',
    () async {
      final started = Completer<void>();
      final gate = Completer<AgentResponse>();
      final client = ScriptedClient((_, _, run, delta) {
        delta('text', '已收到的内容');
        started.complete();
        return run.wait(gate.future);
      });
      controller = AgentController(store, client: client, tools: tools);
      final task = controller!.send('你好');
      await started.future;
      final conversationId = controller!.conversation.id;
      controller!.dispose();
      controller = null;
      await task;
      gate.complete(const AgentResponse('迟到内容', '', []));
      store = await AgentStore.open('${root.path}/agent');
      final last = store.messages(conversationId).last;
      expect(last.text, '已收到的内容');
      expect(last.state, 'interrupted');
      controller = AgentController(
        store,
        client: ScriptedClient(
          (_, _, _, _) async => const AgentResponse('恢复后的回复', '', []),
        ),
      );
      expect(controller!.error, isNotNull);
      await controller!.resume();
      expect(controller!.messages.last.text, '恢复后的回复');
      expect(controller!.error, isNull);
    },
  );

  test(
    'dispose releases a queued send without accessing closed storage',
    () async {
      final started = Completer<void>();
      final client = ScriptedClient((_, _, run, _) {
        started.complete();
        return run.wait(Completer<AgentResponse>().future);
      });
      controller = AgentController(store, client: client, tools: tools);
      final c = controller!;
      final active = c.send('第一个请求');
      await started.future;
      final queued = c.send('第二个请求');
      c.dispose();
      await Future.wait([active, queued]).timeout(const Duration(seconds: 2));
      expect(c.busy, false);
    },
  );

  test(
    'partially successful batch and unknown write failure are not blindly retryable',
    () {
      expect(
        AgentController.retryable({
          'name': 'later_add',
          'result': {
            'ok': true,
            'data': {
              'summary': {'ok': 1, 'failed': 1},
            },
          },
        }),
        false,
      );
      expect(
        AgentController.retryable({
          'name': 'fav_add',
          'result': const AgentException('TOOL_FAILED', 'unknown').toJson(),
        }),
        false,
      );
    },
  );
}
