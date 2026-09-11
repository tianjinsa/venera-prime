import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_context.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_images.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_wire.dart';
import 'package:venera/utils/io.dart' show IO;
import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_test_support.dart';

// Only the explicit loopback protocol test bypasses Flutter's mock HttpClient.
class _LocalHttpOverrides extends HttpOverrides {}

AgentImageDraft resourceImage(String id, {Uint8List? bytes}) {
  final data = bytes ?? File('assets/app_icon.png').readAsBytesSync();
  return AgentImageDraft(
    AgentImageAttachment(
      id: id,
      name: '$id.png',
      mimeType: 'image/png',
      byteLength: data.length,
    ),
    data,
  );
}

void main() {
  late Directory root;
  late AgentStore store;
  AgentController? controller;
  const vision = AgentModel(
    id: 'vision',
    name: '识图模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
    supportsVision: true,
  );
  const textOnly = AgentModel(
    id: 'text',
    name: '文本模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  const comic = AgentComic(sourceKey: 'jm', comicId: '123', title: '展示记录');

  AgentMessage saveUser(
    String conversation,
    String id,
    AgentImageDraft image, {
    String text = '识别图片',
  }) {
    final message = AgentMessage(
      id: id,
      conversationId: conversation,
      role: 'user',
      parts: [
        {'type': 'text', 'text': text},
        image.attachment.toJson(),
      ],
      createdAt: 1,
    );
    store.saveMessageWithImages(message, [image]);
    return message;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'venera-agent-image-resources-',
    );
    configureAgentTestPaths(root.path);
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(
      const AgentSettings(models: [vision, textOnly]),
      {},
    );
  });
  tearDown(() async {
    controller?.dispose();
    controller = null;
    store.close();
    await root.delete(recursive: true);
  });

  test(
    'image validation uses bytes and rejects invalid or oversized files',
    () async {
      final original = resourceImage('content');
      final image = await readAgentImage(
        XFile.fromData(original.bytes, name: 'renamed.txt'),
      );
      expect(image.attachment.mimeType, 'image/png');
      expect(image.bytes, original.bytes);
      expect(image.attachment.byteLength, original.bytes.length);
      await expectLater(
        readAgentImage(
          XFile.fromData(
            Uint8List.fromList(utf8.encode('<svg/>')),
            name: 'fake.png',
          ),
        ),
        throwsA(
          isA<AgentException>().having((e) => e.code, 'code', 'INVALID_IMAGE'),
        ),
      );
      await expectLater(
        readAgentImage(
          XFile.fromData(Uint8List(agentImageMaxBytes + 1), name: 'large.png'),
        ),
        throwsA(
          isA<AgentException>().having(
            (e) => e.code,
            'code',
            'IMAGE_TOO_LARGE',
          ),
        ),
      );
    },
  );

  test(
    'native picker lifecycle flag is cleared after cancellation or failure',
    () async {
      await expectLater(
        IO.withFileSelection(() async {
          expect(IO.isSelectingFiles, true);
          throw const FormatException('cancelled');
        }),
        throwsFormatException,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(IO.isSelectingFiles, false);
    },
  );

  test(
    'image-only and text-plus-images requests use multimodal content and survive reopen',
    () async {
      final first = resourceImage('first');
      final second = resourceImage('second');
      final third = resourceImage('third');
      final requests = <List<AgentJson>>[];
      controller = AgentController(
        store,
        client: ScriptedClient((_, wire, _, _) async {
          requests.add(wire);
          return const AgentResponse('已识别', '', []);
        }),
      );
      await controller!.send('', images: [first]);
      expect(controller!.conversation.title, 'first.png');
      await controller!.send('比较两张图', images: [second, third]);
      final users = requests.last.where((m) => m['role'] == 'user').toList();
      expect(users[0]['content'], [
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/png;base64,${base64Encode(first.bytes)}',
          },
        },
      ]);
      expect(users[1]['content'][0], {'type': 'text', 'text': '比较两张图'});
      expect(users[1]['content'], hasLength(3));
      expect(
        users[1]['content'][1]['image_url']['url'],
        startsWith('data:image/png;base64,'),
      );
      final id = controller!.conversation.id;
      final recorded = controller!.messages.first;
      expect(jsonEncode(recorded.parts), isNot(contains('base64')));
      controller!.dispose();
      controller = null;
      store = await AgentStore.open('${root.path}/agent');
      expect(store.imageBytes(id, first.attachment.id), first.bytes);
      final restored = agentWire(
        store.messages(id),
        vision,
        imageDataUrl: store.imageDataUrl,
      );
      expect(
        restored.where((m) => m['role'] == 'user').first['content'],
        users.first['content'],
      );
    },
  );

  test(
    'models without vision reject images before storing a message or making a request',
    () async {
      var requests = 0;
      controller = AgentController(
        store,
        client: ScriptedClient((_, _, _, _) async {
          requests++;
          return const AgentResponse('', '', []);
        }),
      );
      controller!.selectModel(textOnly.id);
      await expectLater(
        controller!.send('识图', images: [resourceImage('blocked')]),
        throwsA(
          isA<AgentException>().having(
            (e) => e.code,
            'code',
            'VISION_UNSUPPORTED',
          ),
        ),
      );
      expect(store.messages(controller!.conversation.id), isEmpty);
      expect(requests, 0);
    },
  );

  test(
    'supplemental images persist through queued input, regeneration and editing',
    () async {
      final started = Completer<void>();
      final pending = Completer<AgentResponse>();
      final requests = <List<AgentJson>>[];
      controller = AgentController(
        store,
        client: ScriptedClient((_, wire, run, _) async {
          requests.add(wire);
          if (requests.length == 1) {
            started.complete();
            return run.wait(pending.future);
          }
          return const AgentResponse('两张图已处理', '', []);
        }),
      );
      final first = resourceImage('root-image');
      final follow = resourceImage('follow-image');
      final task = controller!.send('先看这一张', images: [first]);
      await started.future;
      await controller!.send('还有这张', images: [follow]);
      expect(controller!.messages.last.state, 'queued');
      expect(controller!.messages.last.isFollowUp, true);
      pending.complete(const AgentResponse('第一张已处理', '', []));
      await task;
      await controller!.regenerate();
      var users = requests.last.where((m) => m['role'] == 'user').toList();
      expect(users, hasLength(2));
      expect(
        users.every(
          (m) => (m['content'] as List).any((p) => p['type'] == 'image_url'),
        ),
        true,
      );
      expect(
        store.imageBytes(controller!.conversation.id, follow.attachment.id),
        follow.bytes,
      );
      await controller!.editAndResend(controller!.messages.first, '重新识别原图');
      users = requests.last.where((m) => m['role'] == 'user').toList();
      expect(users, hasLength(1));
      expect(users.single['content'][0]['text'], '重新识别原图');
      expect(
        store.imageBytes(controller!.conversation.id, first.attachment.id),
        first.bytes,
      );
      expect(
        store.imageBytes(controller!.conversation.id, follow.attachment.id),
        isNull,
      );
    },
  );

  test(
    'interrupted image conversations can continue after closing the store',
    () async {
      final started = Completer<void>();
      controller = AgentController(
        store,
        client: ScriptedClient((_, _, run, delta) async {
          delta('text', '识别到一部分');
          started.complete();
          return run.wait(Completer<AgentResponse>().future);
        }),
      );
      final image = resourceImage('recover');
      final task = controller!.send('识别图片', images: [image]);
      await started.future;
      final id = controller!.conversation.id;
      controller!.dispose();
      controller = null;
      await task;
      store = await AgentStore.open('${root.path}/agent');
      controller = AgentController(
        store,
        client: ScriptedClient((_, wire, _, _) async {
          expect(
            wire.firstWhere(
              (m) => m['role'] == 'user',
            )['content'][1]['image_url']['url'],
            'data:image/png;base64,${base64Encode(image.bytes)}',
          );
          expect(wire.any((m) => m['content'] == '识别到一部分'), true);
          return const AgentResponse('已继续', '', []);
        }),
      );
      expect(controller!.conversation.id, id);
      await controller!.send('继续识别');
      expect(controller!.error, isNull);
    },
  );

  test(
    'compaction keeps current-task images and releases old images only from model context',
    () async {
      final conversation = store.createConversation(modelId: vision.id);
      final old = saveUser(conversation.id, 'old', resourceImage('old-image'));
      final answer = AgentMessage(
        id: 'old-answer',
        conversationId: conversation.id,
        role: 'assistant',
        parts: [
          {'type': 'text', 'text': '旧图信息'},
        ],
        createdAt: 2,
      );
      store.saveMessage(answer);
      final current = saveUser(
        conversation.id,
        'current',
        resourceImage('current-image'),
      );
      final context = AgentConversationContext(
        summary: '旧图已识别',
        throughMessageId: answer.id,
      );
      final wire = agentWire(
        store.messages(conversation.id),
        vision,
        context: context,
        imageDataUrl: store.imageDataUrl,
      );
      final users = wire.where((m) => m['role'] == 'user').toList();
      expect(users, hasLength(1));
      expect(
        users.single['content'][1]['image_url']['url'],
        store.imageDataUrl(current, current.images.single),
      );
      expect(
        store.imageBytes(conversation.id, old.images.single.id),
        isNotNull,
      );
      store.saveContext(conversation.id, context);
      store.saveMessage(
        AgentMessage(
          id: 'current-answer',
          conversationId: conversation.id,
          role: 'assistant',
          parts: [
            {'type': 'text', 'text': '当前图片识别结果'},
          ],
          createdAt: 3,
        ),
      );
      controller = AgentController(
        store,
        client: ScriptedClient((_, messages, _, _) async {
          expect(messages.last['content'], agentCompactionPrompt);
          final imageContent =
              messages.firstWhere((m) => m['role'] == 'user')['content']
                  as List;
          expect(imageContent.any((part) => part['type'] == 'image_url'), true);
          return const AgentResponse('包含识图结果的摘要', '', []);
        }),
      );
      await controller!.requestCompaction();
      expect(controller!.error, isNull);
      expect(store.conversationContext(conversation.id).summary, '包含识图结果的摘要');
      expect(
        store.imageBytes(conversation.id, current.images.single.id),
        isNotNull,
      );
      expect(
        store.imageBytes(conversation.id, old.images.single.id),
        isNotNull,
      );
    },
  );

  test(
    'the real HTTP client sends multiple Base64 images as JSON and reads image-token usage',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final localModel = AgentModel(
        id: 'vision',
        name: '本机协议测试',
        model: 'vision-test',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        supportsVision: true,
        stream: false,
      );
      await store.saveSettings(AgentSettings(models: [localModel]), {});
      final images = [
        resourceImage('http-first'),
        resourceImage('http-second'),
      ];
      final handled = server.first.then((request) async {
        try {
          expect(request.uri.path, '/v1/chat/completions');
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          final content =
              (body['messages'] as List).firstWhere(
                    (m) => m['role'] == 'user',
                  )['content']
                  as List;
          expect(content, hasLength(3));
          expect(content.first, {'type': 'text', 'text': '识别两张图'});
          for (var i = 0; i < images.length; i++) {
            final url = content[i + 1]['image_url']['url'] as String;
            expect(url, startsWith('data:image/png;base64,'));
            expect(base64Decode(url.split(',').last), images[i].bytes);
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'message': {'content': '收到两张图片'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 600,
                'completion_tokens': 47,
                'total_tokens': 647,
              },
            }),
          );
        } finally {
          await request.response.close();
        }
      });
      try {
        final dio = Dio()
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () =>
                _LocalHttpOverrides().createHttpClient(null),
          );
        controller = AgentController(store, client: AgentClient(dio: dio));
        await controller!.send('识别两张图', images: images);
        expect(controller!.error, isNull);
        await handled.timeout(const Duration(seconds: 2));
        expect(controller!.messages.last.text, '收到两张图片');
        expect(controller!.usage?.totalTokens, 647);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'version-two conversations migrate without losing history or model settings',
    () async {
      final conversation = store.createConversation(modelId: vision.id);
      store.saveMessage(
        AgentMessage(
          id: 'legacy-text',
          conversationId: conversation.id,
          role: 'user',
          parts: [
            {'type': 'text', 'text': '需要保留的旧记录'},
          ],
          createdAt: 1,
        ),
      );
      store.saveContext(
        conversation.id,
        const AgentConversationContext(
          summary: '旧摘要',
          throughMessageId: 'legacy-text',
        ),
      );
      store.close();
      final db = sqlite3.open('${root.path}/agent/agent.db');
      db.execute(
        'DROP TABLE message_images; PRAGMA auto_vacuum = NONE; VACUUM; PRAGMA user_version = 2;',
      );
      db.dispose();
      store = await AgentStore.open('${root.path}/agent');
      expect(store.messages(conversation.id).single.text, '需要保留的旧记录');
      expect(store.conversationContext(conversation.id).summary, '旧摘要');
      expect(store.settings.defaultModel?.supportsVision, true);
      final image = resourceImage('new-image');
      saveUser(conversation.id, 'new-user', image);
      expect(
        store.imageBytes(conversation.id, image.attachment.id),
        image.bytes,
      );
      store.deleteConversation(conversation.id);
      expect(store.messages(conversation.id), isEmpty);
    },
  );

  test(
    'image insertion is atomic and cannot reassign another conversations attachment',
    () {
      final first = store.createConversation();
      final other = store.createConversation();
      final image = resourceImage('unique');
      saveUser(first.id, 'owner', image);
      expect(
        () => saveUser(other.id, 'conflict', image),
        throwsA(isA<SqliteException>()),
      );
      expect(store.messages(other.id), isEmpty);
      expect(store.imageBytes(other.id, image.attachment.id), isNull);
      expect(store.imageBytes(first.id, image.attachment.id), image.bytes);
    },
  );

  test(
    'bulk deletion removes all owned resources, reclaims disk space and keeps other conversations',
    () {
      final first = store.createConversation();
      final second = store.createConversation();
      final keep = store.createConversation();
      final large = resourceImage(
        'large',
        bytes: Uint8List(2 * 1024 * 1024)..fillRange(0, 2 * 1024 * 1024, 7),
      );
      saveUser(first.id, 'large-owner', large);
      final secondMessage = saveUser(
        second.id,
        'second-owner',
        resourceImage('second-image'),
      );
      saveUser(keep.id, 'keep-owner', resourceImage('keep-image'));
      store.saveMessage(
        AgentMessage(
          id: 'log',
          conversationId: first.id,
          role: 'assistant',
          parts: [
            {
              'type': 'tool_call',
              'id': 'tool',
              'name': 'search_source',
              'arguments': {'query': '日志'},
              'result': {
                'ok': true,
                'data': {'text': '完整运行日志'},
              },
              'state': 'done',
            },
          ],
          createdAt: 4,
        ),
      );
      store.remember(first.id, comic);
      store.addShowcase(first.id, [comic], title: '漫画展示');
      store.recordOperationComics(first.id, 'later', [comic]);
      store.saveUndo('undo', first.id, [
        {'comic': comic.toJson()},
      ]);
      store.saveContext(
        first.id,
        const AgentConversationContext(summary: '摘要', throughMessageId: 'log'),
      );
      final before = store
          .conversations()
          .firstWhere((c) => c.id == first.id)
          .storageBytes;
      expect(before, greaterThan(large.bytes.length));
      final database = File('${root.path}/agent/agent.db');
      final diskBefore = database.lengthSync();
      store.deleteConversations([first.id, second.id, first.id]);
      expect(store.conversations().map((c) => c.id), [keep.id]);
      expect(store.imageBytes(first.id, large.attachment.id), isNull);
      expect(
        store.imageBytes(second.id, secondMessage.images.single.id),
        isNull,
      );
      expect(store.imageBytes(keep.id, 'keep-image'), isNotNull);
      expect(database.lengthSync(), lessThan(diskBefore - 1024 * 1024));
      final db = sqlite3.open(database.path);
      try {
        for (final table in [
          'messages',
          'comic_seen',
          'showcases',
          'undo_records',
          'conversation_context',
        ]) {
          expect(
            db.select(
              'SELECT count(*) AS n FROM $table WHERE conversation IN (?,?);',
              [first.id, second.id],
            ).single['n'],
            0,
          );
        }
        expect(
          db.select('SELECT count(*) AS n FROM message_images;').single['n'],
          1,
        );
        expect(
          db.select('SELECT count(*) AS n FROM showcase_items;').single['n'],
          0,
        );
        expect(
          db
              .select('SELECT count(*) AS n FROM showcase_operations;')
              .single['n'],
          0,
        );
        expect(db.select('PRAGMA foreign_key_check;'), isEmpty);
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'deleting other histories keeps the current response streaming',
    () async {
      final other = store.createConversation();
      saveUser(other.id, 'other-user', resourceImage('other-image'));
      store.createConversation(modelId: vision.id);
      final started = Completer<void>();
      final continued = Completer<void>();
      final finish = Completer<void>();
      controller = AgentController(
        store,
        client: ScriptedClient((_, _, run, delta) async {
          delta('text', '前半段');
          started.complete();
          await run.wait(continued.future);
          delta('text', '后半段');
          await run.wait(finish.future);
          return const AgentResponse('前半段后半段', '', []);
        }),
      );
      final task = controller!.send('继续生成');
      await started.future;
      await controller!.deleteConversations([other]);
      expect(controller!.busy, true);
      continued.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller!.messages.last.text, '前半段后半段');
      finish.complete();
      await task;
      expect(controller!.error, isNull);
    },
  );

  test(
    'deleting the active conversation stops it before reclaiming its images',
    () async {
      final started = Completer<void>();
      controller = AgentController(
        store,
        client: ScriptedClient((_, _, run, _) async {
          started.complete();
          return run.wait(Completer<AgentResponse>().future);
        }),
      );
      final task = controller!.send('识图中', images: [resourceImage('active')]);
      await started.future;
      final deleted = controller!.conversation;
      await controller!.deleteConversations([deleted]);
      await task;
      expect(controller!.busy, false);
      expect(controller!.conversation.id, isNot(deleted.id));
      expect(controller!.error, isNull);
      expect(store.messages(deleted.id), isEmpty);
      expect(store.imageBytes(deleted.id, 'active'), isNull);
    },
  );
}
