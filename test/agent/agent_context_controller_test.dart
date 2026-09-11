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
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_storage_tools_test.dart' show TestSource, details;
import 'agent_test_support.dart';

void main() {
  late Directory root;
  late AgentStore store;
  late LocalFavoritesManager favorites;
  late ReadLaterManager later;
  late AgentTools tools;
  late List<ComicSource> sources;
  AgentController? controller;
  const model = AgentModel(
    id: 'm',
    name: '测试模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  const comic = AgentComic(sourceKey: 'jm', comicId: '123', title: '真实漫画');
  bool isSummary(List<AgentJson> wire) =>
      wire.last['content'] == agentCompactionPrompt;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-agent-context-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    favorites = LocalFavoritesManager()..close();
    later = ReadLaterManager()..close();
    await favorites.init();
    await later.init();
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(const AgentSettings(models: [model]), {});
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

  test('an Agent task continues beyond the old tool round limit', () async {
    var count = 0;
    controller = AgentController(
      store,
      tools: tools,
      client: ScriptedClient((_, _, _, _) async {
        count++;
        return count <= 20
            ? AgentResponse('步骤$count', '', [
                AgentToolCall('tool-$count', 'list_sources', '{}'),
              ])
            : const AgentResponse('完成20轮操作', '', []);
      }),
    );
    await controller!.send('执行长任务');
    expect(count, 21);
    expect(controller!.messages.last.text, '完成20轮操作');
    expect(controller!.error, isNull);
    expect(controller!.messages.expand((m) => m.tools).length, 20);
    expect(
      store.settings.models.single.toJson().containsKey('max_tool_rounds'),
      false,
    );
  });

  test(
    'supplement during a response skips unstarted tools and joins the same task',
    () async {
      final started = Completer<void>();
      final response = Completer<AgentResponse>();
      var count = 0;
      final client = ScriptedClient((_, wire, run, delta) async {
        if (++count == 1) {
          delta('reasoning', '正在判断');
          started.complete();
          return run.wait(response.future);
        }
        expect(
          wire.where((m) => m['role'] == 'user').map((m) => m['content']),
          ['把123加入稍后再看', '不要添加，先告诉我结果'],
        );
        final skipped = jsonDecode(
          wire.singleWhere((m) => m['role'] == 'tool')['content'],
        );
        expect(skipped['error']['code'], 'INPUT_UPDATED');
        return const AgentResponse('已按补充要求处理', '', []);
      });
      controller = AgentController(store, client: client, tools: tools);
      store.remember(controller!.conversation.id, comic);
      final running = controller!.send('把123加入稍后再看');
      await started.future;
      await controller!.send('不要添加，先告诉我结果');
      expect(controller!.busy, true);
      final supplement = controller!.messages.last;
      expect(supplement.followUpTo, controller!.messages.first.id);
      expect(supplement.state, 'queued');
      response.complete(
        const AgentResponse('准备添加', '', [
          AgentToolCall('add', 'later_add', '{"comics":["jm:123"]}'),
        ]),
      );
      await running;
      expect(later.getAll(), isEmpty);
      expect(count, 2);
      expect(supplement.state, 'done');
      expect(controller!.messages.last.text, '已按补充要求处理');
      expect(
        AgentController.retryable(controller!.messages[1].tools.single),
        false,
      );
    },
  );

  test(
    'supplement preserves the running operation and skips later calls',
    () async {
      final started = Completer<void>();
      final pending = Completer<Res<ComicDetails>>();
      var sourceCalls = 0;
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^\d+$'),
          loadComicInfo: (_) {
            sourceCalls++;
            started.complete();
            return pending.future;
          },
        ),
      );
      var count = 0;
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient((_, wire, _, _) async {
          if (++count == 1) {
            return const AgentResponse('', '', [
              AgentToolCall('first', 'later_add', '{"comics":["jm:123"]}'),
              AgentToolCall('next', 'later_add', '{"comics":["jm:456"]}'),
            ]);
          }
          final receipts = wire
              .where((m) => m['role'] == 'tool')
              .map((m) => jsonDecode(m['content']))
              .toList();
          expect(receipts[0]['data']['summary']['ok'], 1);
          expect(receipts[1]['error']['code'], 'INPUT_UPDATED');
          return const AgentResponse('只完成第一本', '', []);
        }),
      );
      final running = controller!.send('将123和456加入稍后再看');
      await started.future;
      await controller!.send('只保留第一本');
      pending.complete(Res(details('jm', '123')));
      await running;
      expect(later.getAll().map((m) => m.id), ['123']);
      expect(sourceCalls, 1);
      expect(controller!.error, isNull);
    },
  );

  test(
    'a new requirement releases pending confirmation without executing it',
    () async {
      await store.saveSettings(
        const AgentSettings(models: [model], confirmPolicy: 'all'),
        {},
      );
      var count = 0;
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient(
          (_, _, _, _) async => ++count == 1
              ? const AgentResponse('', '', [
                  AgentToolCall('add', 'later_add', '{"comics":["jm:123"]}'),
                ])
              : const AgentResponse('已取消这次添加', '', []),
        ),
      );
      store.remember(controller!.conversation.id, comic);
      final confirming = Completer<void>();
      controller!.addListener(() {
        if (controller!.confirmation != null && !confirming.isCompleted) {
          confirming.complete();
        }
      });
      final running = controller!.send('加入稍后再看');
      await confirming.future;
      await controller!.send('取消添加');
      await running.timeout(const Duration(seconds: 2));
      expect(controller!.confirmation, isNull);
      expect(later.getAll(), isEmpty);
      expect(controller!.messages[1].tools.single['state'], 'skipped');
    },
  );

  for (final tokens in [899, 900]) {
    test(
      'automatic compression starts at 90 percent, reported tokens=$tokens',
      () async {
        final small = AgentModel.fromJson({
          ...model.toJson(),
          'context_window_tokens': 1000,
        });
        await store.saveSettings(AgentSettings(models: [small]), {});
        var requests = 0;
        var summaries = 0;
        final client = ScriptedClient((_, wire, _, _) async {
          if (isSummary(wire)) {
            summaries++;
            expect(wire.where((m) => m['role'] == 'tool').length, 1);
            return const AgentResponse(
              '目标：查看源。已完成源查询，无写入。',
              '',
              [],
              usage: AgentUsage(totalTokens: 999),
            );
          }
          if (++requests == 1) {
            return AgentResponse(
              '先看漫画源',
              '',
              [const AgentToolCall('source', 'list_sources', '{}')],
              usage: AgentUsage(
                inputTokens: tokens - 100,
                cachedTokens: 600,
                outputTokens: 100,
                totalTokens: tokens,
              ),
            );
          }
          if (tokens == 900) {
            expect(wire[1]['content'], contains('目标：查看源'));
            expect(
              wire.where((m) => m['role'] == 'user').single['content'],
              '查看源，不要进行写入',
            );
          }
          return const AgentResponse(
            '查询完成',
            '',
            [],
            usage: AgentUsage(
              inputTokens: 120,
              outputTokens: 30,
              totalTokens: 150,
            ),
          );
        });
        controller = AgentController(store, tools: tools, client: client);
        await controller!.send('查看源，不要进行写入');
        expect(summaries, tokens == 900 ? 1 : 0);
        expect(requests, 2);
        expect(controller!.messages.length, 3);
        expect(controller!.usage?.totalTokens, 150);
        expect(controller!.contextState.compactionCount, summaries);
        expect(
          client.toolRequests.where((list) => list.isEmpty).length,
          summaries,
        );
        if (tokens == 900) {
          expect(
            store.conversationContext(controller!.conversation.id).summary,
            contains('无写入'),
          );
        }
      },
    );
  }

  test(
    'latest usage replaces prior statistics and missing usage stays unknown',
    () async {
      var count = 0;
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient(
          (_, _, _, _) async => AgentResponse(
            '完成',
            '',
            [],
            usage: ++count <= 2 ? AgentUsage(totalTokens: count * 100) : null,
          ),
        ),
      );
      await controller!.send('第一轮');
      expect(controller!.usage?.totalTokens, 100);
      await controller!.send('第二轮');
      expect(controller!.usage?.totalTokens, 200);
      await controller!.send('第三轮');
      expect(controller!.usage, isNull);
      expect(
        store.conversationContext(controller!.conversation.id).usage,
        isNull,
      );
    },
  );

  test(
    'manual compression survives restart and retains original history',
    () async {
      final client = ScriptedClient(
        (_, wire, _, _) async => isSummary(wire)
            ? const AgentResponse(
                '摘要：已按要求完成查询。',
                '',
                [],
                usage: AgentUsage(totalTokens: 888),
              )
            : const AgentResponse(
                '完整历史正文',
                '完整历史思考',
                [],
                usage: AgentUsage(totalTokens: 100),
              ),
      );
      controller = AgentController(store, tools: tools, client: client);
      await controller!.send('查询漫画');
      final id = controller!.conversation.id;
      final original = controller!.messages
          .map((m) => jsonEncode(m.parts))
          .toList();
      await controller!.requestCompaction();
      expect(controller!.messages.map((m) => jsonEncode(m.parts)), original);
      expect(controller!.usage, isNull);
      expect(controller!.contextState.compactionCount, 1);
      controller!.dispose();
      controller = null;
      store = await AgentStore.open('${root.path}/agent');
      expect(store.conversationContext(id).summary, contains('摘要'));
      expect(store.messages(id).map((m) => jsonEncode(m.parts)), original);
      controller = AgentController(
        store,
        client: ScriptedClient((_, wire, _, _) async {
          expect(wire[1]['content'], contains('摘要'));
          expect(wire.last['content'], '再看下一本');
          return const AgentResponse('继续回复', '', []);
        }),
      );
      await controller!.send('再看下一本');
      expect(controller!.messages.last.text, '继续回复');
    },
  );

  test(
    'failed or cancelled compaction never replaces the saved context',
    () async {
      var mode = 'normal';
      final started = Completer<void>();
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient((_, wire, run, _) async {
          if (!isSummary(wire)) {
            return const AgentResponse(
              '历史正文',
              '',
              [],
              usage: AgentUsage(totalTokens: 100),
            );
          }
          if (mode == 'fail') throw const AgentException('MODEL_ERROR', '测试错误');
          if (mode == 'cancel') {
            started.complete();
            return run.wait(Completer<AgentResponse>().future);
          }
          return const AgentResponse('已有摘要', '', []);
        }),
      );
      await controller!.send('第一轮');
      await controller!.requestCompaction();
      await controller!.send('第二轮');
      final saved = controller!.contextState;
      mode = 'fail';
      await controller!.requestCompaction();
      expect(controller!.contextState.summary, saved.summary);
      expect(controller!.contextState.throughMessageId, saved.throughMessageId);
      expect(controller!.contextState.usage?.totalTokens, 100);
      expect(controller!.error, contains('压缩失败'));
      mode = 'cancel';
      final task = controller!.requestCompaction();
      await started.future;
      controller!.stop();
      await task;
      expect(
        store.conversationContext(controller!.conversation.id).throughMessageId,
        saved.throughMessageId,
      );
      expect(
        store.conversationContext(controller!.conversation.id).compactionCount,
        1,
      );
    },
  );

  test(
    'input during manual compaction is processed immediately afterwards',
    () async {
      final started = Completer<void>();
      final summary = Completer<AgentResponse>();
      var replies = 0;
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient((_, wire, run, _) async {
          if (isSummary(wire)) {
            started.complete();
            return run.wait(summary.future);
          }
          if (++replies == 2) expect(wire.last['content'], '增加一个要求');
          return const AgentResponse('完成', '', []);
        }),
      );
      await controller!.send('初始任务');
      final task = controller!.requestCompaction();
      await started.future;
      await controller!.send('增加一个要求');
      summary.complete(const AgentResponse('已完成初始任务', '', []));
      await task;
      expect(replies, 2);
      expect(controller!.messages.where((m) => m.state == 'queued'), isEmpty);
    },
  );

  test(
    'streaming checkpoint and queued input recover after reopening without replaying a write',
    () async {
      final started = Completer<void>();
      var requests = 0;
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient((_, _, run, delta) async {
          if (++requests == 1) {
            return const AgentResponse('', '', [
              AgentToolCall('saved-add', 'later_add', '{"comics":["jm:123"]}'),
            ]);
          }
          delta('text', '已生成但还没完成的正文');
          started.complete();
          return run.wait(Completer<AgentResponse>().future);
        }),
      );
      store.remember(controller!.conversation.id, comic);
      final task = controller!.send('把123加入稍后再看');
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final id = controller!.conversation.id;
      expect(store.messages(id).last.text, '已生成但还没完成的正文');
      expect(store.messages(id).last.state, 'running');
      await controller!.send('还要告诉我作者');
      controller!.dispose();
      controller = null;
      await task;
      store = await AgentStore.open('${root.path}/agent');
      final restored = store.messages(id);
      expect(restored.last.state, 'queued');
      expect(restored[2].state, 'interrupted');
      expect(restored[1].tools.single['result']['data']['summary']['ok'], 1);
      controller = AgentController(
        store,
        client: ScriptedClient((_, wire, _, _) async {
          expect(wire.where((m) => m['role'] == 'tool').length, 1);
          expect(
            wire.where((m) => m['role'] == 'user').map((m) => m['content']),
            ['把123加入稍后再看', '还要告诉我作者', '继续刚才的任务'],
          );
          expect(wire.any((m) => m['content'] == '已生成但还没完成的正文'), true);
          return const AgentResponse('已接着处理，没有重复添加', '', []);
        }),
      );
      expect(controller!.error, isNotNull);
      await controller!.send('继续刚才的任务');
      expect(later.getAll().length, 1);
      expect(controller!.messages.where((m) => m.isFollowUp).length, 2);
      expect(controller!.messages.any((m) => m.text == '已生成但还没完成的正文'), true);
    },
  );

  test(
    'regeneration retains every supplement to the original request',
    () async {
      final first = Completer<AgentResponse>();
      var count = 0;
      final started = Completer<void>();
      controller = AgentController(
        store,
        tools: tools,
        client: ScriptedClient((_, wire, run, _) async {
          if (++count == 1) {
            started.complete();
            return run.wait(first.future);
          }
          expect(
            wire.where((m) => m['role'] == 'user').map((m) => m['content']),
            ['原始要求', '补充条件'],
          );
          return const AgentResponse('包含补充条件的回复', '', []);
        }),
      );
      final task = controller!.send('原始要求');
      await started.future;
      await controller!.send('补充条件');
      first.complete(const AgentResponse('第一步', '', []));
      await task;
      await controller!.regenerate();
      expect(count, 3);
      expect(controller!.messages.where((m) => m.isFollowUp).length, 1);
    },
  );
}
