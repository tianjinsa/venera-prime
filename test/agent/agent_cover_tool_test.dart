import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_wire.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_storage_tools_test.dart' show TestSource, details;
import 'agent_test_support.dart';

AgentComic coverComic(String id) => AgentComic(
  sourceKey: 'jm',
  comicId: id,
  title: '封面测试$id',
  cover: 'https://example.invalid/cover$id.jpg',
);

void main() {
  late Directory root;
  late AgentStore store;
  late AgentConversation conversation;
  late AgentTools tools;
  late LocalFavoritesManager favorites;
  late ReadLaterManager later;
  late List<ComicSource> sources;
  late List<String> loadedUrls;
  final png = File('assets/app_icon.png').readAsBytesSync();

  AgentToolContext context({String? messageId, bool vision = true}) =>
      AgentToolContext(
        conversation.id,
        AgentRun(),
        messageId: messageId,
        supportsVision: vision,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-agent-cover-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    favorites = LocalFavoritesManager()..close();
    later = ReadLaterManager()..close();
    await favorites.init();
    await later.init();
    store = await AgentStore.open('${root.path}/agent');
    conversation = store.createConversation();
    sources = [];
    loadedUrls = [];
  });
  tearDown(() async {
    store.close();
    favorites.close();
    later.close();
    await root.delete(recursive: true);
  });

  void build({Uint8List? bytes}) {
    tools = AgentTools(
      store,
      favorites: favorites,
      later: later,
      initializeSources: () async {},
      sources: () => sources,
      sourceTimeout: const Duration(milliseconds: 100),
      loadCover: (url, sourceKey, comicId, checkStop) async {
        loadedUrls.add(url);
        return bytes ?? png;
      },
    );
  }

  test('a cover of a known comic is returned as an image attachment', () async {
    build();
    final comic = coverComic('10');
    store.remember(conversation.id, comic);
    final result = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': '10',
    }, context());
    expect(result['ok'], true, reason: jsonEncode(result));
    final data = agentObject(result['data']);
    expect(data['url'], comic.cover);
    expect(data['source_key'], 'jm');
    expect(data['comic_id'], '10');
    expect(data['title'], '封面测试10');
    final image = agentObject(data['image']);
    expect(image['type'], 'image');
    expect(image['mime_type'], 'image/png');
    expect(image['byte_length'], png.length);
    expect(image['name'], endsWith('.png'));
    expect(loadedUrls, [comic.cover]);
    // The bytes are released exactly once, to the caller that stores them.
    final images = tools.takeImages(result);
    expect(images.single.bytes, png);
    expect(tools.takeImages(result), isEmpty);
  });

  test('the cover of an unseen comic is read from its details once', () async {
    var requests = 0;
    sources.add(
      TestSource(
        'jm',
        loadComicInfo: (id) async {
          requests++;
          return Res(details('jm', id));
        },
      ),
    );
    build();
    final first = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': '77',
    }, context());
    expect(first['ok'], true, reason: jsonEncode(first));
    expect(loadedUrls, ['https://example.invalid/cover']);
    // The remembered comic makes a second cover read use the cache.
    final second = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': '77',
    }, context());
    expect(second['ok'], true);
    expect(requests, 1);
  });

  test('a cover URL is accepted when the source returns none', () async {
    build();
    final result = await tools.execute('comic_cover', {
      'url': 'https://example.invalid/direct-cover.png',
    }, context());
    expect(result['ok'], true, reason: jsonEncode(result));
    expect(loadedUrls, ['https://example.invalid/direct-cover.png']);
    expect(agentObject(result['data'])['url'], contains('direct-cover.png'));
  });

  test(
    'exactly one target is required and it must be an http address',
    () async {
      build();
      for (final args in <AgentJson>[
        {},
        {'source_key': 'jm'},
        {'comic_id': '10'},
        {
          'source_key': 'jm',
          'comic_id': '10',
          'url': 'https://example.invalid/x.png',
        },
        {'source_key': 'jm', 'url': 'https://example.invalid/x.png'},
        {'comic_id': '10', 'url': 'https://example.invalid/x.png'},
        {'url': 'file:///etc/passwd'},
        {'url': 'ftp://example.invalid/x.png'},
        {'url': 'https://user:secret@example.invalid/x.png'},
        {'url': '   '},
      ]) {
        final result = await tools.execute('comic_cover', args, context());
        expect(result['ok'], false, reason: jsonEncode(args));
        expect(
          result['error']['code'],
          'INVALID_ARGUMENT',
          reason: jsonEncode(args),
        );
      }
    },
  );

  test(
    'failed, empty and invalid cover bytes are reported per cause',
    () async {
      sources.add(
        TestSource('jm', loadComicInfo: (id) async => Res(details('jm', id))),
      );
      build(
        bytes: Uint8List.fromList(utf8.encode('<html>not an image</html>')),
      );
      final invalid = await tools.execute('comic_cover', {
        'source_key': 'jm',
        'comic_id': '404',
      }, context());
      expect(invalid['error']['code'], 'INVALID_IMAGE');
      expect(tools.takeImages(invalid), isEmpty);

      tools = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {},
        sources: () => sources,
        loadCover: (_, _, _, _) async => Uint8List(0),
      );
      final empty = await tools.execute('comic_cover', {
        'source_key': 'jm',
        'comic_id': '405',
      }, context());
      expect(empty['error']['code'], 'COVER_REQUEST_FAILED');

      tools = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {},
        sources: () => sources,
        loadCover: (_, _, _, _) async => throw StateError('404 not found'),
      );
      final failed = await tools.execute('comic_cover', {
        'source_key': 'jm',
        'comic_id': '406',
      }, context());
      expect(failed['error']['code'], 'COVER_REQUEST_FAILED');
    },
  );

  test('a comic without a cover address is not fetched', () async {
    sources.add(
      TestSource(
        'jm',
        loadComicInfo: (id) async => Res(
          ComicDetails.fromJson({
            'title': '无封面',
            'cover': '',
            'sourceKey': 'jm',
            'comicId': id,
            'tags': <String, List<String>>{},
          }),
        ),
      ),
    );
    build();
    final result = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': 'no-cover',
    }, context());
    expect(result['error']['code'], 'NO_COVER');
    expect(loadedUrls, isEmpty);
  });

  test('an unknown comic of a missing source reports the source', () async {
    build();
    final result = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': 'unknown',
    }, context());
    expect(result['error']['code'], 'SOURCE_NOT_FOUND');
  });

  test(
    'the receipt states whether a model without vision can see it',
    () async {
      build();
      store.remember(conversation.id, coverComic('11'));
      final textOnly = await tools.execute('comic_cover', {
        'source_key': 'jm',
        'comic_id': '11',
      }, context(vision: false));
      expect(agentObject(textOnly['data'])['vision'], contains('未开启图片输入'));
    },
  );

  test(
    'the response stores the bytes and the wire re-sends them once',
    () async {
      build();
      store.remember(conversation.id, coverComic('12'));
      const model = AgentModel(
        id: 'm',
        name: '识图',
        baseUrl: 'https://example.invalid/v1',
        model: 'test',
        supportsVision: true,
      );
      final assistant = AgentMessage(
        id: 'assistant',
        conversationId: conversation.id,
        role: 'assistant',
        parts: [
          {
            'type': 'tool_call',
            'id': 'call',
            'name': 'comic_cover',
            'arguments': {'source_key': 'jm', 'comic_id': '12'},
            'state': 'running',
          },
        ],
        modelId: model.id,
        createdAt: agentNow(),
      );
      store.saveMessage(assistant);
      final result = await tools.execute('comic_cover', {
        'source_key': 'jm',
        'comic_id': '12',
      }, context(messageId: assistant.id));
      final call = assistant.tools.single;
      final images = tools.takeImages(result);
      call['images'] = [images.single.attachment.toJson()];
      call['result'] = result;
      call['state'] = 'done';
      store.saveMessage(assistant);
      for (final image in images) {
        store.saveMessageImage(assistant.id, image);
      }
      expect(
        store.imageBytes(conversation.id, images.single.attachment.id),
        png,
      );

      final wire = agentWire(
        [
          AgentMessage(
            id: 'user',
            conversationId: conversation.id,
            role: 'user',
            parts: [
              {'type': 'text', 'text': '看看封面'},
            ],
            createdAt: agentNow(),
          ),
          store.messages(conversation.id).last,
        ],
        model,
        imageDataUrl: store.imageDataUrl,
      );
      final imageMessage = wire.last;
      expect(imageMessage['role'], 'user');
      final content = imageMessage['content'] as List;
      expect((content.first as Map)['type'], 'text');
      final part = content[1] as Map;
      expect(part['type'], 'image_url');
      expect(part['image_url']['url'], startsWith('data:image/png;base64,'));
      expect(
        base64Decode((part['image_url']['url'] as String).split(',').last),
        png,
      );
      // The receipt no longer needs to carry a second Base64 copy.
      expect(agentToolImages(assistant.tools), hasLength(1));

      // A text-only model still receives the receipt, but no image.
      const textModel = AgentModel(
        id: 't',
        name: '文本',
        baseUrl: 'https://example.invalid/v1',
        model: 'test',
      );
      final textWire = agentWire(
        [
          AgentMessage(
            id: 'user',
            conversationId: conversation.id,
            role: 'user',
            parts: [
              {'type': 'text', 'text': '看看封面'},
            ],
            createdAt: agentNow(),
          ),
          assistant,
        ],
        textModel,
        imageDataUrl: store.imageDataUrl,
      );
      expect(
        textWire.any((m) => m['role'] == 'user' && m['content'] is List),
        false,
      );
    },
  );

  test('stored images follow their message when it is deleted', () async {
    build();
    store.remember(conversation.id, coverComic('13'));
    final assistant = AgentMessage(
      id: 'assistant',
      conversationId: conversation.id,
      role: 'assistant',
      parts: [
        {
          'type': 'tool_call',
          'id': 'call',
          'name': 'comic_cover',
          'arguments': {'source_key': 'jm', 'comic_id': '13'},
          'state': 'running',
        },
      ],
      createdAt: agentNow(),
    );
    store.saveMessage(assistant);
    final result = await tools.execute('comic_cover', {
      'source_key': 'jm',
      'comic_id': '13',
    }, context(messageId: assistant.id));
    final image = tools.takeImages(result).single;
    final call = assistant.tools.single;
    call['images'] = [image.attachment.toJson()];
    store.saveMessage(assistant);
    store.saveMessageImage(assistant.id, image);
    expect(store.imageBytes(conversation.id, image.attachment.id), isNotNull);
    // A message cannot own bytes it does not describe as a part.
    call.remove('images');
    store.saveMessage(assistant);
    expect(
      () => store.saveMessageImage(assistant.id, image),
      throwsA(isA<AgentException>()),
    );
    store.deleteConversation(conversation.id);
    expect(store.imageBytes(conversation.id, image.attachment.id), isNull);
  });
}
