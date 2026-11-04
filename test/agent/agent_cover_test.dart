import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_images.dart';
import 'package:venera/agent/agent_image_view.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_wire.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_storage_tools_test.dart' show TestSource, details;
import 'agent_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AgentStore store;
  late AgentTools tools;
  late AgentConversation conversation;
  late AgentMessage message;
  late AgentToolContext context;
  late Uint8List png;
  late Uint8List loaded;
  late List<ComicSource> sources;
  final loads = <(String, String?, String?)>[];
  const vision = AgentModel(
    id: 'vision',
    name: '识图',
    baseUrl: 'https://provider.invalid/v1',
    model: 'test',
    supportsVision: true,
  );
  const comic = AgentComic(
    sourceKey: 'jm',
    comicId: '123',
    title: '真实漫画',
    cover: 'https://covers.invalid/123.png',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-cover-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    LocalFavoritesManager().close();
    ReadLaterManager().close();
    CacheManager.instance = null;
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(
      const AgentSettings(models: [vision], defaultModelId: 'vision'),
      {},
    );
    conversation = store.createConversation(modelId: vision.id);
    message = AgentMessage(
      id: 'step',
      conversationId: conversation.id,
      role: 'assistant',
      parts: [],
      createdAt: 1,
    );
    store.saveMessage(message);
    context = AgentToolContext(
      conversation.id,
      AgentRun(),
      messageId: message.id,
      supportsVision: true,
    );
    png = File('assets/app_icon.png').readAsBytesSync();
    loaded = png;
    loads.clear();
    sources = [
      TestSource('jm', loadComicInfo: (id) async => Res(details('jm', id))),
    ];
    tools = AgentTools(
      store,
      initializeSources: () async {},
      sources: () => sources,
      coverLoader: (url, key, id, run) async {
        loads.add((url, key, id));
        return loaded;
      },
    );
  });
  tearDown(() async {
    await CacheManager.instance?.close();
    CacheManager.instance = null;
    store.close();
    LocalFavoritesManager().close();
    ReadLaterManager().close();
    await root.delete(recursive: true);
  });

  Future<AgentJson> read(AgentJson args) =>
      tools.execute('comic_read_cover', args, context);

  test(
    'reads known metadata directly, persists image bytes with conversation isolation and cleanup',
    () async {
      store.remember(conversation.id, comic);
      final result = await read({'source_key': 'jm', 'comic_id': '123'});
      expect(result['ok'], true);
      expect(loads.single, (comic.cover, 'jm', '123'));
      final attachment = AgentImageAttachment.fromJson(
        agentObject(result['data']['image']),
      );
      expect(store.imageBytes(conversation.id, attachment.id), png);
      expect(
        store.imageBytes(store.createConversation().id, attachment.id),
        isNull,
      );
      expect(jsonEncode(result), isNot(contains('base64')));
      store.close();
      store = await AgentStore.open('${root.path}/agent');
      expect(store.imageBytes(conversation.id, attachment.id), png);
      store.deleteConversation(conversation.id);
      expect(store.imageBytes(conversation.id, attachment.id), isNull);
    },
  );

  test(
    'resolves unknown comic details and supports direct URLs with optional source headers',
    () async {
      expect((await read({'source_key': 'jm', 'comic_id': '456'}))['ok'], true);
      expect(loads.single, ('https://example.invalid/cover', 'jm', '456'));
      expect(
        (await read({'cover_url': '//covers.invalid/direct.png'}))['ok'],
        true,
      );
      expect(loads.last, ('https://covers.invalid/direct.png', null, null));
      expect(
        (await read({
          'cover_url': 'https://covers.invalid/direct.png',
          'source_key': 'jm',
        }))['ok'],
        true,
      );
      expect(loads.last.$2, 'jm');
    },
  );

  test(
    'rejects unsupported models and invalid parameters before fetching',
    () async {
      final unsupported = await tools.execute(
        'comic_read_cover',
        {'cover_url': comic.cover},
        AgentToolContext(conversation.id, AgentRun(), messageId: message.id),
      );
      expect(unsupported['error']['code'], 'VISION_UNSUPPORTED');
      for (final args in <AgentJson>[
        {},
        {'comic_id': '123'},
        {'source_key': 'jm'},
        {'cover_url': 'file:///private/data'},
        {'cover_url': 'javascript:alert(1)'},
        {'cover_url': 'https://user:password@covers.invalid/image'},
        {'cover_url': 3},
      ]) {
        expect((await read(args))['error']['code'], 'INVALID_ARGUMENT');
      }
      expect(loads, isEmpty);
    },
  );

  test('reuses thumbnail cache and image format validation', () async {
    const url = 'http://127.0.0.1:1/must-not-request.png';
    await CacheManager().writeCache('$url@null', png);
    final cachedTools = AgentTools(store);
    final result = await cachedTools.execute('comic_read_cover', {
      'cover_url': url,
    }, context);
    expect(result['ok'], true);
    expect(
      store.imageBytes(conversation.id, result['data']['image']['id']),
      png,
    );
    loaded = Uint8List.fromList(utf8.encode('<html>fake image</html>'));
    expect(
      (await read({'cover_url': comic.cover}))['error']['code'],
      'INVALID_IMAGE',
    );
    loaded = Uint8List(agentImageMaxBytes + 1);
    expect(
      (await read({'cover_url': comic.cover}))['error']['code'],
      'IMAGE_TOO_LARGE',
    );
  });

  test('cancelled and failed downloads produce no success receipt', () async {
    final pending = Completer<Uint8List>();
    final slowTools = AgentTools(
      store,
      coverLoader: (_, _, _, _) => pending.future,
    );
    final result = slowTools.execute('comic_read_cover', {
      'cover_url': comic.cover,
    }, context);
    await Future<void>.delayed(Duration.zero);
    context.run.cancel();
    expect((await result)['error']['code'], 'CANCELLED');
    pending.complete(png);
    final broken = AgentTools(
      store,
      coverLoader: (_, _, _, _) async =>
          throw StateError('private request error'),
    );
    final error = await broken.execute(
      'comic_read_cover',
      {'cover_url': comic.cover},
      AgentToolContext(
        conversation.id,
        AgentRun(),
        messageId: message.id,
        supportsVision: true,
      ),
    );
    expect(error['error']['code'], 'COVER_LOAD_FAILED');
    expect(jsonEncode(error), isNot(contains('private request')));
  });

  for (final protocol in AgentProtocol.values) {
    test(
      '${protocol.id} sends real cover bytes after all tool receipts',
      () async {
        final result = await read({'cover_url': comic.cover});
        message.parts.addAll([
          {
            'type': 'tool_call',
            'id': 'cover',
            'name': 'comic_read_cover',
            'arguments': {'cover_url': comic.cover},
            'state': 'done',
            'result': result,
          },
          {
            'type': 'tool_call',
            'id': 'other',
            'name': 'list_sources',
            'arguments': {},
            'state': 'done',
            'result': {'ok': true, 'data': []},
          },
        ]);
        store.saveMessage(message);
        final model = AgentModel.fromJson({
          ...vision.toJson(),
          'protocol': protocol.id,
        });
        final wire = agentWire(
          [message],
          model,
          imageDataUrl: store.imageDataUrl,
        );
        expect(wire.map((m) => m['role']), [
          'system',
          'assistant',
          'tool',
          'tool',
          'user',
        ]);
        final body = AgentClient.requestBody(
          model: model,
          thinkingId: null,
          messages: wire,
          tools: AgentTools.schemas,
        );
        final encoded = jsonEncode(body);
        expect(encoded, contains(base64Encode(png)));
        if (protocol != AgentProtocol.messages) {
          expect(encoded, contains('data:image/png;base64,'));
        }
        if (protocol == AgentProtocol.messages) {
          final blocks = (body['messages'] as List).last['content'] as List;
          expect(blocks.where((b) => b['type'] == 'tool_result').length, 2);
          expect(blocks.last['source']['data'], base64Encode(png));
        }
        const textModel = AgentModel(
          id: 'text',
          name: 'text',
          baseUrl: 'https://provider.invalid',
          model: 'text',
        );
        expect(
          jsonEncode(
            agentWire([message], textModel, imageDataUrl: store.imageDataUrl),
          ),
          isNot(contains(base64Encode(png))),
        );
      },
    );
  }

  test(
    'controller round-trip makes cover image available on the next request',
    () async {
      var requests = 0;
      final client = ScriptedClient((model, wire, run, delta) async {
        if (requests++ == 0) {
          return const AgentResponse('', '', [
            AgentToolCall(
              'cover',
              'comic_read_cover',
              '{"cover_url":"https://covers.invalid/123.png"}',
            ),
          ]);
        }
        expect(jsonEncode(wire), contains(base64Encode(png)));
        return const AgentResponse('已查看封面', '', []);
      });
      final controller = AgentController(store, tools: tools, client: client);
      addTearDown(controller.dispose);
      await controller.send('分析漫画封面');
      expect(controller.messages.last.text, '已查看封面');
      expect(controller.error, isNull);
    },
  );

  testWidgets('cover receipt provides a thumbnail and full-size preview', (
    tester,
  ) async {
    final result = await tester.runAsync(
      () => read({'cover_url': comic.cover}),
    );
    message.parts.add({
      'type': 'tool_call',
      'id': 'cover',
      'name': 'comic_read_cover',
      'arguments': {'cover_url': comic.cover},
      'state': 'done',
      'result': result,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMessageParts(
            message: message,
            indices: const [0],
            busy: false,
            imageLoader: (m, image) =>
                store.imageBytes(m.conversationId, image.id),
            canRetry: (_) => false,
            onRetry: (_) {},
            onShowcase: (_) {},
            hasUndo: (_) => false,
            onUndo: (_) {},
          ),
        ),
      ),
    );
    expect(find.byType(AgentImageTile), findsOneWidget);
    await tester.tap(find.byType(AgentImageTile));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
