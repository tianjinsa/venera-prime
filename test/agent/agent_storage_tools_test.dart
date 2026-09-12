import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_context.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_test_support.dart';

class TestSource implements ComicSource {
  @override
  final String key;
  @override
  final String name;
  @override
  String get version => 'test';
  @override
  bool get isLogged => false;
  @override
  final SearchPageData? searchPageData;
  @override
  final LoadComicFunc? loadComicInfo;
  @override
  final RegExp? idMatcher;
  @override
  final LinkHandler? linkHandler;
  TestSource(
    this.key, {
    this.searchPageData,
    this.loadComicInfo,
    this.idMatcher,
    this.linkHandler,
  }) : name = key;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ComicDetails details(String source, String id) => ComicDetails.fromJson({
  'title': '真实标题',
  'subtitle': '作者',
  'cover': 'https://example.invalid/cover',
  'description': '完整简介',
  'tags': <String, List<String>>{},
  'sourceKey': source,
  'comicId': id,
  'thumbnails': ['https://example.invalid/private-page'],
});

void main() {
  late Directory root;
  late AgentStore store;
  late AgentConversation conversation;
  late AgentTools tools;
  late LocalFavoritesManager favorites;
  late ReadLaterManager later;
  late List<ComicSource> sources;
  late AgentToolContext context;
  const comic = AgentComic(
    sourceKey: 'jm',
    comicId: '123',
    title: '真实标题',
    subtitle: '作者',
    description: '完整简介',
    cover: 'https://example.invalid/cover',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-agent-tools-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    favorites = LocalFavoritesManager()..close();
    later = ReadLaterManager()..close();
    await favorites.init();
    await later.init();
    favorites.createFolder('目标');
    store = await AgentStore.open('${root.path}/agent');
    conversation = store.createConversation();
    sources = [];
    tools = AgentTools(
      store,
      favorites: favorites,
      later: later,
      initializeSources: () async {},
      sources: () => sources,
      sourceTimeout: const Duration(milliseconds: 50),
    );
    context = AgentToolContext(conversation.id, AgentRun());
  });
  tearDown(() async {
    store.close();
    favorites.close();
    later.close();
    await root.delete(recursive: true);
  });

  void user(String text) => store.saveMessage(
    AgentMessage(
      id: agentId(),
      conversationId: conversation.id,
      role: 'user',
      parts: [
        {'type': 'text', 'text': text},
      ],
      createdAt: agentNow(),
    ),
  );

  test(
    'all 19 tool schemas are distinct and exclude unsupported destructive capabilities',
    () {
      final names = AgentTools.schemas
          .map((s) => s['function']['name'])
          .toSet();
      expect(names.length, 19);
      expect(
        names,
        containsAll(['fav_check', 'later_check', 'showcase_comics']),
      );
      expect(names, isNot(contains('fav_delete_folder')));
    },
  );

  test('batch deduplicates, preserves metadata and notifies once', () async {
    store.remember(conversation.id, comic);
    var changes = 0;
    void listener() {
      changes++;
    }

    later.addListener(listener);
    final result = await tools.execute('later_add', {
      'comics': [
        {...comic.toJson(), 'title': '伪造标题', 'cover': 'https://forged.invalid'},
        'jm:123',
      ],
    }, context);
    expect(result['data']['summary'], {
      'total': 2,
      'ok': 1,
      'skipped': 1,
      'failed': 0,
      'missing': 0,
      'already_exists': 0,
    });
    expect(changes, 1);
    final saved = later.getAll().single;
    expect(saved.title, '真实标题');
    expect(saved.description, '完整简介');
    expect(saved.cover, comic.cover);
    later.removeListener(listener);
    final again = await tools.execute('later_add', {
      'comics': ['jm:123'],
    }, context);
    expect(again['data']['results'][0]['reason'], 'ALREADY_EXISTS');
    final absent = await tools.execute('later_check', {
      'comics': ['jm:none'],
    }, context);
    expect(absent['data']['results'][0]['marker'], -1);
  });

  test(
    'batch limits and malformed refs reject the entire input before writing',
    () async {
      store.remember(conversation.id, comic);
      for (final input in [
        <Object>[],
        List.filled(51, 'jm:123'),
        [
          'jm:123',
          {'source_key': 'jm', 'comic_id': 123},
        ],
      ]) {
        final result = await tools.execute('later_add', {
          'comics': input,
        }, context);
        expect(result['ok'], false);
        expect(later.getAll(), isEmpty);
      }
    },
  );

  test('partial metadata failures do not discard successful rows', () async {
    store.remember(conversation.id, comic);
    final result = await tools.execute('later_add', {
      'comics': ['jm:123', 'missing:404'],
    }, context);
    expect(result['data']['summary'], {
      'total': 2,
      'ok': 1,
      'skipped': 0,
      'failed': 1,
      'missing': 0,
      'already_exists': 0,
    });
    expect(later.getAll().single.id, '123');
  });

  test(
    'add tools resolve unseen ids internally and report missing entries',
    () async {
      final lookedUp = <String>[];
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^\d+$'),
          loadComicInfo: (id) async {
            lookedUp.add(id);
            return id == '404'
                ? const Res.error('未找到漫画')
                : Res(details('jm', id));
          },
        ),
      );
      user('将图片中的漫画加入稍后再看和目标收藏夹');
      final result = await tools.execute('later_add', {
        'comics': ['jm:123', 'jm:404'],
      }, context);
      expect(lookedUp, ['123', '404']);
      expect(result['data']['summary']['ok'], 1);
      expect(result['data']['summary']['missing'], 1);
      expect(result['data']['missing'].single['comic_id'], '404');
      expect(result['data']['missing'].single['message'], contains('未找到漫画'));
      lookedUp.clear();
      await tools.execute('fav_add', {
        'folder': '目标',
        'comics': ['jm:123'],
      }, context);
      final duplicate = await tools.execute('later_add', {
        'comics': ['jm:123'],
      }, context);
      expect(duplicate['data']['summary']['already_exists'], 1);
      expect(lookedUp, isEmpty);
      expect(store.showcases(conversation.id).map((g) => g.kind).toSet(), {
        'favorites',
        'later',
      });
    },
  );

  test(
    'remove tools check membership directly and list all missing comics',
    () async {
      store.remember(conversation.id, comic);
      const absent = AgentComic(
        sourceKey: 'jm',
        comicId: '456',
        title: '未加入的漫画',
      );
      store.remember(conversation.id, absent);
      await tools.execute('fav_add', {
        'folder': '目标',
        'comics': ['jm:123'],
      }, context);
      await tools.execute('later_add', {
        'comics': ['jm:123'],
      }, context);
      for (final name in ['fav_remove', 'later_remove']) {
        final result = await tools.execute(name, {
          'comics': ['jm:123', 'jm:456', 'jm:789'],
          if (name == 'fav_remove') 'folder': '目标',
        }, context);
        expect(result['data']['summary']['ok'], 1);
        expect(result['data']['summary']['missing'], 2);
        expect((result['data']['missing'] as List).map((m) => m['comic_id']), [
          '456',
          '789',
        ]);
        expect(result['data']['missing'][0]['title'], '未加入的漫画');
        expect(result['data']['missing'][0]['reason'], 'NOT_PRESENT');
      }
      expect(store.showcases(conversation.id), isEmpty);
    },
  );

  test(
    'operation showcases group by collection and folder and survive reopening',
    () async {
      store.remember(conversation.id, comic);
      favorites.createFolder('另一个收藏夹');
      for (final folder in ['目标', '另一个收藏夹', '目标']) {
        await tools.execute('fav_add', {
          'folder': folder,
          'comics': ['jm:123'],
        }, context);
      }
      await tools.execute('later_add', {
        'comics': ['jm:123'],
      }, context);
      final groups = store.showcases(conversation.id);
      expect(groups.length, 3);
      expect(
        groups.where((g) => g.kind == 'favorites').map((g) => g.folder).toSet(),
        {'目标', '另一个收藏夹'},
      );
      expect(groups.every((g) => g.comics.length == 1), true);
      store.addShowcase(conversation.id, [comic], title: '展示一');
      store.addShowcase(conversation.id, [comic], title: '展示二', replace: true);
      expect(store.showcases(conversation.id).length, 4);
      store.close();
      store = await AgentStore.open('${root.path}/agent');
      expect(
        store
            .showcases(conversation.id)
            .where((g) => g.kind == 'favorites')
            .length,
        2,
      );
      final laterGroup = store
          .showcases(conversation.id)
          .singleWhere((g) => g.kind == 'later');
      store.hideShowcase(laterGroup.id);
      const another = AgentComic(
        sourceKey: 'jm',
        comicId: '456',
        title: '另一部漫画',
      );
      store.recordOperationComics(conversation.id, 'later', [another]);
      expect(
        store
            .showcases(conversation.id)
            .singleWhere((g) => g.kind == 'later')
            .comics
            .map((c) => c.comicId),
        ['456'],
      );
    },
  );

  test(
    'editing invalidates a covered summary and always clears stale usage',
    () {
      user('第一轮');
      final first = store.messages(conversation.id).single;
      final answer = AgentMessage(
        id: 'a',
        conversationId: conversation.id,
        role: 'assistant',
        createdAt: 1,
        parts: [
          {'type': 'text', 'text': '已完成'},
        ],
      );
      store.saveMessage(answer);
      user('第二轮');
      final nextUser = store.messages(conversation.id).last;
      store.saveContext(
        conversation.id,
        const AgentConversationContext(
          summary: '第一轮摘要',
          throughMessageId: 'a',
          usage: AgentUsage(totalTokens: 500),
          usageModelId: 'm',
          compactionCount: 1,
        ),
      );
      store.truncateFrom(nextUser);
      expect(store.conversationContext(conversation.id).summary, '第一轮摘要');
      expect(store.conversationContext(conversation.id).usage, isNull);
      store.truncateFrom(first, include: false);
      expect(store.conversationContext(conversation.id).hasSummary, false);
    },
  );

  test(
    'version one histories gain operation groups without repeating collection writes',
    () async {
      store.remember(conversation.id, comic);
      user('加入收藏和稍后再看');
      store.saveMessage(
        AgentMessage(
          id: 'old-response',
          conversationId: conversation.id,
          role: 'assistant',
          createdAt: 2,
          parts: [
            for (final name in ['fav_add', 'later_add'])
              {
                'type': 'tool_call',
                'id': name,
                'name': name,
                'state': 'done',
                'arguments': {
                  'comics': ['jm:123'],
                  if (name == 'fav_add') 'folder': '目标',
                },
                'result': {
                  'ok': true,
                  'data': {
                    'results': [
                      {...comic.ref, 'status': 'added'},
                    ],
                  },
                },
              },
          ],
        ),
      );
      store.close();
      final legacy = sqlite3.open('${root.path}/agent/agent.db');
      legacy.execute(
        'DROP TABLE conversation_context; DROP TABLE showcase_operations; PRAGMA user_version = 1;',
      );
      legacy.dispose();
      store = await AgentStore.open('${root.path}/agent');
      expect(store.showcases(conversation.id).map((g) => g.kind).toSet(), {
        'favorites',
        'later',
      });
      expect(later.getAll(), isEmpty);
      expect(favorites.count('目标'), 0);
      expect(store.messages(conversation.id).length, 2);
    },
  );

  test('detail results retain long descriptions and all tags', () async {
    final long = '完整内容' * 2000;
    sources.add(
      TestSource(
        'jm',
        idMatcher: RegExp(r'^\d+$'),
        loadComicInfo: (id) async => Res(
          ComicDetails.fromJson({
            'sourceKey': 'jm',
            'comicId': id,
            'title': '长标题' * 300,
            'cover': '',
            'description': long,
            'tags': {'分类': List.generate(35, (i) => '标签$i')},
          }),
        ),
      ),
    );
    user('查看123');
    final result = await tools.execute('comic_open_by_id', {
      'source_key': 'jm',
      'comic_id': '123',
    }, context);
    expect(result['data']['description'], long);
    expect(result['data']['title'], '长标题' * 300);
    expect(result['data']['tags'].length, 35);
  });

  test('same id in different sources remains distinct in favorites', () async {
    const second = AgentComic(
      sourceKey: 'other',
      comicId: '123',
      title: '另一来源',
    );
    store.remember(conversation.id, comic);
    store.remember(conversation.id, second);
    var notifications = 0;
    void listener() {
      notifications++;
    }

    favorites.addListener(listener);
    final result = await tools.execute('fav_add', {
      'folder': '目标',
      'comics': ['jm:123', 'other:123'],
    }, context);
    expect(result['data']['summary']['ok'], 2);
    expect(favorites.count('目标'), 2);
    expect(notifications, 1);
    favorites.removeListener(listener);
    favorites.createFolder('另一个');
    await tools.execute('fav_add', {
      'folder': '另一个',
      'comics': ['jm:123'],
    }, context);
    final status = await tools.execute('fav_check', {
      'comics': ['jm:123', 'jm:0'],
    }, context);
    expect(status['data']['results'][0]['folders'], containsAll(['目标', '另一个']));
    expect(status['data']['results'][0]['folder'], null);
    expect(status['data']['results'][1]['folder'], -1);
  });

  test(
    'remove and undo only restore actual deletions, without overwriting later edits',
    () async {
      store.remember(conversation.id, comic);
      await tools.execute('fav_add', {
        'folder': '目标',
        'comics': ['jm:123'],
      }, context);
      final removal = await tools.execute('fav_remove', {
        'comics': ['jm:123', 'jm:missing'],
      }, context);
      expect(favorites.count('目标'), 0);
      expect(removal['data']['summary']['skipped'], 1);
      final undoId = removal['data']['undo_id'] as String;
      expect(tools.undo(undoId, context)['restored'], 1);
      expect(store.hasUndo(undoId, conversation.id), false);
      await tools.execute('later_add', {
        'comics': ['jm:123'],
      }, context);
      final laterRemoval = await tools.execute('later_remove', {
        'comics': ['jm:123'],
      }, context);
      later.add(const Comic('后来修改', '', '123', '', [], '', 'jm', null, null));
      expect(
        tools.undo(laterRemoval['data']['undo_id'], context)['skipped'],
        1,
      );
      expect(later.getAll().single.title, '后来修改');
    },
  );

  test(
    'removing a comic from several folders tolerates an existing cover cache',
    () async {
      store.remember(conversation.id, comic);
      favorites.createFolder('其它');
      for (final folder in ['目标', '其它']) {
        await tools.execute('fav_add', {
          'folder': folder,
          'comics': ['jm:123'],
        }, context);
      }
      final coverName = ('123${ComicType.fromKey('jm').value}').hashCode;
      final cache = File('${root.path}/favorite_cover/$coverName');
      await cache.parent.create(recursive: true);
      await cache.writeAsBytes([1, 2, 3]);
      final result = await tools.execute('fav_remove', {
        'comics': ['jm:123'],
      }, context);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(result['data']['summary']['ok'], 1);
      expect(favorites.count('目标'), 0);
      expect(favorites.count('其它'), 0);
    },
  );

  test('move to existing destination preserves source and counters', () async {
    store.remember(conversation.id, comic);
    favorites.createFolder('另一个');
    for (final folder in ['目标', '另一个']) {
      await tools.execute('fav_add', {
        'folder': folder,
        'comics': ['jm:123'],
      }, context);
    }
    final result = await tools.execute('fav_move', {
      'from_folder': '目标',
      'to_folder': '另一个',
      'comics': ['jm:123'],
    }, context);
    expect(result['data']['results'][0]['status'], 'skipped');
    expect(favorites.count('目标'), 1);
    expect(favorites.count('另一个'), 1);
  });

  test(
    'showcase fetches unseen identities and uses cached or source metadata',
    () async {
      store.remember(conversation.id, comic);
      final lookedUp = <String>[];
      sources.add(
        TestSource(
          'jm',
          loadComicInfo: (id) async {
            lookedUp.add(id);
            return id == 'unknown'
                ? const Res.error('未找到漫画')
                : Res(details('jm', id));
          },
        ),
      );
      final result = await tools.execute('showcase_comics', {
        'comics': [
          {...comic.toJson(), 'title': '伪造', 'cover': 'https://forged.invalid'},
          'jm:unknown',
          'jm:456',
          'jm:456',
        ],
      }, context);
      final groups = store.showcases(conversation.id);
      expect(groups.single.comics.map((c) => c.comicId), ['123', '456']);
      expect(groups.single.comics.first.title, comic.title);
      expect(groups.single.comics.last.title, '真实标题');
      expect(result['data']['count'], 2);
      expect(result['data']['summary'], {
        'total': 4,
        'ok': 2,
        'skipped': 1,
        'failed': 1,
      });
      expect(result['data']['skipped'][0]['reason'], 'NOT_FOUND');
      expect(result['data']['skipped'][0]['message'], contains('未找到漫画'));
      expect(result['data']['skipped'][1]['reason'], 'DUPLICATE_IN_BATCH');
      expect(lookedUp, ['unknown', '456']);
      for (final item in groups.single.comics) {
        store.hideComic(groups.single.id, item);
      }
      expect(store.showcases(conversation.id), isEmpty);
      final another = store.createConversation();
      final loaded = await tools.execute('showcase_comics', {
        'comics': ['jm:123'],
      }, AgentToolContext(another.id, AgentRun()));
      expect(loaded['ok'], true);
      expect(loaded['data']['count'], 1);
      expect(lookedUp, ['unknown', '456', '123']);
    },
  );

  test('failed showcase replacement preserves the previous group', () async {
    store.addShowcase(conversation.id, [comic], title: '已有展示');
    final result = await tools.execute('showcase_comics', {
      'comics': ['missing:339981', 'missing:1258084'],
      'mode': 'replace',
    }, context);
    expect(result['ok'], true);
    expect(result['data']['count'], 0);
    expect(result['data']['summary']['failed'], 2);
    expect(result['data']['set_id'], isNull);
    expect(result['data']['skipped'], hasLength(2));
    expect(result['data']['skipped'][0]['reason'], 'SOURCE_NOT_FOUND');
    expect(result['data']['skipped'][1]['comic_id'], '1258084');
    expect(store.showcases(conversation.id).single.title, '已有展示');
  });

  for (final name in ['comic_open_by_id', 'comic_get']) {
    test('$name accepts unseen ids without an id matcher', () async {
      final lookedUp = <String>[];
      sources.add(
        TestSource(
          'jm',
          loadComicInfo: (id) async {
            lookedUp.add(id);
            return Res(details('jm', id));
          },
        ),
      );
      for (final id in ['339981', 'album:1258084']) {
        final result = await tools.execute(name, {
          'source_key': 'jm',
          'comic_id': id,
        }, context);
        expect(result['ok'], true);
        expect(result['data']['comic_id'], id);
        expect(result['data']['title'], '真实标题');
        expect(store.seen(conversation.id, 'jm', id), isNotNull);
      }
      expect(lookedUp, ['339981', 'album:1258084']);
      expect(store.messages(conversation.id), isEmpty);
    });
  }

  test(
    'source ids are passed unchanged, normalized by the source, and thumbnails are excluded',
    () async {
      String? received;
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^(jm)?\d+$'),
          loadComicInfo: (id) async {
            received = id;
            return Res(details('jm', '123'));
          },
        ),
      );
      user('把 jm123 加入稍后再看');
      final result = await tools.execute('comic_open_by_id', {
        'source_key': 'jm',
        'comic_id': 'jm123',
      }, context);
      expect(received, 'jm123');
      expect(result['data']['comic_id'], '123');
      expect(jsonEncode(result), isNot(contains('private-page')));
      final added = await tools.execute('later_add', {
        'comics': ['jm:jm123', 'jm:123'],
      }, context);
      expect(added['data']['summary']['ok'], 1);
      expect(added['data']['summary']['skipped'], 1);
      expect(later.getAll().single.id, '123');
    },
  );

  test('canonical aliases also work for status and removal', () async {
    store.remember(conversation.id, comic);
    store.remember(conversation.id, comic, alias: 'jm123');
    await tools.execute('later_add', {
      'comics': ['jm:123'],
    }, context);
    final status = await tools.execute('later_check', {
      'comics': ['jm:jm123'],
    }, context);
    expect(status['data']['results'][0]['in_read_later'], true);
    final removal = await tools.execute('later_remove', {
      'comics': ['jm:jm123'],
    }, context);
    expect(removal['data']['summary']['ok'], 1);
    expect(later.getAll(), isEmpty);
  });

  test(
    'resolve accepts ids and supported links absent from user text',
    () async {
      final lookedUp = <String>[];
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^\d+$'),
          linkHandler: LinkHandler([
            'comics.invalid',
          ], (link) => Uri.parse(link).pathSegments.last),
          loadComicInfo: (id) async {
            lookedUp.add(id);
            return Res(details('jm', id));
          },
        ),
      );
      final byId = await tools.execute('comic_resolve', {
        'source_key': 'jm',
        'query': '339981',
      }, context);
      expect(byId['ok'], true);
      expect(byId['data']['resolved_by'], 'id_match');
      expect(byId['data']['candidates'].single['comic_id'], '339981');
      final byLink = await tools.execute('comic_resolve', {
        'query': 'https://comics.invalid/album/1258084',
      }, context);
      expect(byLink['ok'], true);
      expect(byLink['data']['resolved_by'], 'url_extract');
      expect(byLink['data']['candidates'].single['comic_id'], '1258084');
      expect(lookedUp, ['339981', '1258084']);
      expect(store.messages(conversation.id), isEmpty);
    },
  );

  test(
    'resolve returns a complete search page and rejects unsupported URL domains',
    () async {
      var calls = 0;
      sources.add(
        TestSource(
          'single',
          searchPageData: SearchPageData(null, (_, _, _) async {
            calls++;
            return Res(
              List.generate(
                8,
                (i) => Comic(
                  'Comic $i',
                  '',
                  '$i',
                  '',
                  [],
                  '',
                  'single',
                  null,
                  null,
                ),
              ),
              subData: 1,
            );
          }, null),
        ),
      );
      final first = await tools.execute('comic_resolve', {
        'query': 'book',
      }, context);
      expect(first['ok'], true);
      expect(first['data']['candidates'].length, 8);
      expect(first['data'].containsKey('items'), false);
      expect(first['data'].containsKey('continuation'), false);
      expect(first['data']['resolved_by'], 'search');
      expect(first['data']['source_key'], 'single');
      expect(first['data']['keyword'], 'book');
      expect(first['data']['options'], isEmpty);
      expect(first['data']['has_more'], false);
      expect(first['data']['exhausted'], true);
      expect(calls, 1);
      final unsupported = await tools.execute('comic_resolve', {
        'query': 'https://unsupported.invalid/123',
      }, context);
      expect(unsupported['error']['code'], 'NO_LINK_SUPPORT');
      expect(calls, 1);
    },
  );

  for (final name in ['fav_add', 'later_add']) {
    test(
      '$name fetches unseen ids and reports individual source failures',
      () async {
        final lookedUp = <String>[];
        sources.add(
          TestSource(
            'jm',
            loadComicInfo: (id) async {
              lookedUp.add(id);
              if (id == 'offline') throw StateError('连接中断');
              if (id == '404') return const Res.error('漫画不存在');
              return Res(details('jm', id));
            },
          ),
        );
        final result = await tools.execute(name, {
          if (name == 'fav_add') 'folder': '目标',
          'comics': [
            {
              'source_key': 'jm',
              'comic_id': '339981',
              'title': '模型提供的标题',
              'cover': 'https://forged.invalid',
            },
            'jm:1258084',
            'jm:339981',
            'jm:404',
            'jm:offline',
          ],
        }, context);
        expect(result['ok'], true);
        expect(result['data']['summary'], {
          'total': 5,
          'ok': 2,
          'skipped': 1,
          'failed': 2,
          'missing': 1,
          'already_exists': 0,
        });
        expect(lookedUp, ['339981', '1258084', '404', 'offline']);
        expect(result['data']['results'][2]['reason'], 'DUPLICATE_IN_BATCH');
        expect(result['data']['missing'].single['comic_id'], '404');
        expect(result['data']['missing'].single['message'], contains('漫画不存在'));
        expect(result['data']['results'][4]['reason'], 'SOURCE_REQUEST_FAILED');
        expect(result['data']['results'][4]['message'], contains('连接中断'));
        final saved = name == 'fav_add'
            ? favorites.getFolderComics('目标')
            : later.getAll();
        expect(saved.map((c) => c.id).toSet(), {'339981', '1258084'});
        expect(saved.every((c) => c.title == '真实标题'), true);
        expect(saved.every((c) => c.cover == comic.cover), true);
        expect(store.messages(conversation.id), isEmpty);
      },
    );
  }

  test(
    'local collection metadata can be reused by a new conversation offline',
    () async {
      later.add(AgentTools.toComic(comic));
      final added = await tools.execute('fav_add', {
        'folder': '目标',
        'comics': ['jm:123'],
      }, context);
      expect(added['data']['summary']['ok'], 1);
      final another = store.createConversation();
      final shown = await tools.execute('showcase_comics', {
        'comics': ['jm:123'],
      }, AgentToolContext(another.id, AgentRun()));
      expect(shown['data']['count'], 1);
      expect(
        store.showcases(another.id).single.comics.single.title,
        comic.title,
      );
      expect(sources, isEmpty);
    },
  );

  test(
    'sources without details report their capability error per comic',
    () async {
      sources.add(TestSource('jm'));
      final result = await tools.execute('later_add', {
        'comics': ['jm:339981'],
      }, context);
      expect(result['data']['summary']['failed'], 1);
      expect(result['data']['summary']['missing'], 0);
      expect(result['data']['results'].single['reason'], 'NO_DETAIL_SUPPORT');
      expect(result['data']['results'].single['message'], contains('不提供漫画详情'));
      expect(later.getAll(), isEmpty);
    },
  );

  test(
    'search returns every native page item and reuses its metadata for adding',
    () async {
      List<String>? options;
      var sourceInitializations = 0;
      tools = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {
          if (++sourceInitializations > 1) throw StateError('源已不可用');
        },
        sources: () => sources,
      );
      sources.add(
        TestSource(
          'jm',
          searchPageData: SearchPageData(
            [
              SearchOptions(
                LinkedHashMap.of({'new': '最新', 'old': '最早'}),
                '排序',
                'select',
                'new',
              ),
            ],
            (keyword, page, values) async {
              options = values;
              return Res(
                List.generate(
                  23,
                  (i) =>
                      Comic('Comic $i', '', '$i', '', [], '', 'jm', null, null),
                ),
                subData: 1,
              );
            },
            null,
          ),
        ),
      );
      final first = await tools.execute('search_source', {
        'source_key': 'jm',
        'keyword': 'name',
      }, context);
      expect(options, ['new']);
      expect(first['ok'], true);
      expect(
        (first['data']['items'] as List).map((item) => item['comic_id']),
        List.generate(23, (i) => '$i'),
      );
      expect(first['data'].containsKey('continuation'), false);
      expect(first['data']['style'], 'page');
      expect(first['data']['page'], 1);
      expect(first['data']['max_page'], 1);
      expect(first['data']['options'], ['new']);
      expect(first['data']['next_page'], isNull);
      expect(first['data']['next_cursor'], isNull);
      expect(first['data']['has_more'], false);
      expect(first['data']['exhausted'], true);
      final added = await tools.execute('later_add', {
        'comics': ['jm:22'],
      }, context);
      expect(added['data']['summary']['ok'], 1);
      expect(later.getAll().single.title, 'Comic 22');
      expect(sourceInitializations, 1);
    },
  );

  test(
    'native page numbers and explicit options work without prior calls',
    () async {
      final received = <AgentJson>[];
      sources.add(
        TestSource(
          'pages',
          searchPageData: SearchPageData(
            [
              SearchOptions(
                LinkedHashMap.of({'new': '最新', 'old': '最早'}),
                '排序',
                'select',
                'new',
              ),
            ],
            (keyword, page, options) async {
              received.add({
                'keyword': keyword,
                'page': page,
                'options': options,
              });
              return Res([
                Comic(
                  'Page $page',
                  '',
                  '$page',
                  '',
                  [],
                  '',
                  'pages',
                  null,
                  null,
                ),
              ], subData: 3);
            },
            null,
          ),
        ),
      );
      final first = await tools.execute('search_source', {
        'source_key': 'pages',
        'keyword': 'book',
        'page': 2,
        'options': ['old'],
      }, context);
      expect(first['ok'], true);
      final data = first['data'];
      expect(data['page'], 2);
      expect(data['max_page'], 3);
      expect(data['next_page'], 3);
      expect(data['has_more'], true);
      final last = await tools.execute('search_source', {
        'source_key': data['source_key'],
        'keyword': data['keyword'],
        'options': data['options'],
        'page': data['next_page'],
      }, context);
      expect(last['data']['items'].single['comic_id'], '3');
      expect(last['data']['next_page'], isNull);
      expect(last['data']['has_more'], false);
      expect(last['data']['exhausted'], true);
      expect(received, [
        {
          'keyword': 'book',
          'page': 2,
          'options': ['old'],
        },
        {
          'keyword': 'book',
          'page': 3,
          'options': ['old'],
        },
      ]);
    },
  );

  test(
    'cursor source accepts valid unseen cursors and reports source errors',
    () async {
      final received = <String?>[];
      sources.add(
        TestSource(
          'cursor',
          searchPageData: SearchPageData(null, null, (
            keyword,
            cursor,
            options,
          ) async {
            received.add(cursor);
            if (cursor == 'expired') return const Res.error('游标已过期');
            return Res(
              List.generate(
                cursor == null ? 25 : 1,
                (i) => Comic(
                  'Comic $i',
                  '',
                  '$i',
                  '',
                  [],
                  '',
                  'cursor',
                  null,
                  null,
                ),
              ),
              subData: cursor == null ? 'opaque:next' : null,
            );
          }),
        ),
      );
      final resumed = await tools.execute('search_source', {
        'source_key': 'cursor',
        'keyword': 'q',
        'cursor': 'from-history',
      }, context);
      expect(resumed['ok'], true);
      expect(resumed['data']['has_more'], false);
      final first = await tools.execute('search_source', {
        'source_key': 'cursor',
        'keyword': 'q',
      }, context);
      expect(first['data']['items'].length, 25);
      expect(first['data'].containsKey('continuation'), false);
      expect(first['data']['style'], 'cursor');
      expect(first['data']['next_page'], isNull);
      expect(first['data']['next_cursor'], 'opaque:next');
      expect(first['data']['has_more'], true);
      // Simulate restarting the tools while continuing a saved conversation.
      final restarted = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {},
        sources: () => sources,
      );
      final second = await restarted.execute('search_source', {
        'source_key': 'cursor',
        'keyword': 'q',
        'cursor': first['data']['next_cursor'],
      }, context);
      expect(second['data']['has_more'], false);
      final expired = await restarted.execute('search_source', {
        'source_key': 'cursor',
        'keyword': 'q',
        'cursor': 'expired',
      }, context);
      expect(expired['error']['code'], 'SEARCH_FAILED');
      expect(expired['error']['message'], contains('游标已过期'));
      expect(received, ['from-history', null, 'opaque:next', 'expired']);
    },
  );

  test(
    'favorite operations need neither sources nor the read-later database',
    () async {
      later.close();
      var sourceInitializations = 0;
      final localTools = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {
          sourceInitializations++;
          throw StateError('源不可用');
        },
        sources: () => sources,
      );
      favorites.addComic(
        '目标',
        FavoriteItem(
          id: '123',
          name: '离线漫画',
          coverPath: '',
          author: '作者',
          type: ComicType.fromKey('jm'),
          tags: [],
        ),
      );

      Future<AgentJson> call(String name, AgentJson arguments) async {
        final fresh = store.createConversation();
        final result = await localTools.execute(
          name,
          arguments,
          AgentToolContext(fresh.id, AgentRun()),
        );
        expect(result['ok'], true, reason: name);
        expect(later.isInitialized, false, reason: name);
        expect(sourceInitializations, 0, reason: name);
        return result['data'] is Map ? agentObject(result['data']) : result;
      }

      await call('fav_list_folders', {});
      final listed = await call('fav_list', {'folder': '目标'});
      expect(listed['total'], 1);
      final searched = await call('fav_search', {'keyword': '离线'});
      expect(searched['total'], 1);
      final checked = await call('fav_check', {
        'comics': ['jm:123', 'jm:456'],
      });
      expect(checked['results'][0]['in_favorites'], true);
      expect(checked['results'][1]['in_favorites'], false);
      final existing = await call('fav_add', {
        'folder': '目标',
        'comics': ['jm:123'],
      });
      expect(existing['summary']['already_exists'], 1);
      final created = await call('fav_create_folder', {'name': '新收藏夹'});
      expect(created['status'], 'created');
      final duplicate = await call('fav_create_folder', {'name': '新收藏夹'});
      expect(duplicate['reason'], 'ALREADY_EXISTS');
      expect(
        favorites.folderNames.where((name) => name == '新收藏夹'),
        hasLength(1),
      );
      final moved = await call('fav_move', {
        'from_folder': '目标',
        'to_folder': '新收藏夹',
        'comics': ['jm:123', 'jm:456'],
      });
      expect(moved['summary']['ok'], 1);
      expect(moved['summary']['missing'], 1);
      final removed = await call('fav_remove', {
        'folder': '新收藏夹',
        'comics': ['jm:123', 'jm:456'],
      });
      expect(removed['summary']['ok'], 1);
      expect(removed['summary']['missing'], 1);
      expect(favorites.count('目标'), 0);
      expect(favorites.count('新收藏夹'), 0);
    },
  );

  test(
    'read-later operations need neither sources nor the favorites database',
    () async {
      favorites.close();
      later.add(AgentTools.toComic(comic));
      var sourceInitializations = 0;
      final localTools = AgentTools(
        store,
        favorites: favorites,
        later: later,
        initializeSources: () async {
          sourceInitializations++;
          throw StateError('源不可用');
        },
        sources: () => sources,
      );
      Future<AgentJson> call(String name, AgentJson arguments) async {
        final fresh = store.createConversation();
        final result = await localTools.execute(
          name,
          arguments,
          AgentToolContext(fresh.id, AgentRun()),
        );
        expect(result['ok'], true, reason: name);
        expect(favorites.isInitialized, false, reason: name);
        expect(sourceInitializations, 0, reason: name);
        return agentObject(result['data']);
      }

      final listed = await call('later_list', {});
      expect(listed['total'], 1);
      final searched = await call('later_list', {'keyword': '真实'});
      expect(searched['total'], 1);
      final checked = await call('later_check', {
        'comics': ['jm:123', 'jm:456'],
      });
      expect(checked['results'][0]['in_read_later'], true);
      expect(checked['results'][1]['in_read_later'], false);
      final existing = await call('later_add', {
        'comics': ['jm:123'],
      });
      expect(existing['summary']['already_exists'], 1);
      final removed = await call('later_remove', {
        'comics': ['jm:123', 'jm:456'],
      });
      expect(removed['summary']['ok'], 1);
      expect(removed['summary']['missing'], 1);
      expect(later.getAll(), isEmpty);
    },
  );

  test(
    'opening details without status leaves local databases closed',
    () async {
      favorites.close();
      later.close();
      sources.add(
        TestSource('jm', loadComicInfo: (id) async => Res(details('jm', id))),
      );
      final result = await tools.execute('comic_open_by_id', {
        'source_key': 'jm',
        'comic_id': '339981',
        'include_status': false,
      }, context);
      expect(result['ok'], true);
      expect(favorites.isInitialized, false);
      expect(later.isInitialized, false);
      expect(result['data'].containsKey('in_favorites'), false);
    },
  );

  test(
    'cached showcase metadata does not open either collection database',
    () async {
      store.remember(conversation.id, comic);
      favorites.close();
      later.close();
      final result = await tools.execute('showcase_comics', {
        'comics': ['jm:123'],
      }, context);
      expect(result['ok'], true);
      expect(result['data']['count'], 1);
      expect(favorites.isInitialized, false);
      expect(later.isInitialized, false);
    },
  );

  test(
    'missing destination folders return a resource error without creating them',
    () async {
      for (final name in ['fav_add', 'fav_move']) {
        final result = await tools.execute(name, {
          if (name == 'fav_add') 'folder': '不存在的目标',
          if (name == 'fav_move') ...{
            'from_folder': '目标',
            'to_folder': '不存在的目标',
          },
          'comics': ['jm:123'],
        }, context);
        expect(result['error']['code'], 'FOLDER_NOT_FOUND');
        expect(favorites.existsFolder('不存在的目标'), false);
      }
      final invalid = await tools.execute('fav_create_folder', {
        'name': '非法"名称',
      }, context);
      expect(invalid['error']['code'], 'INVALID_ARGUMENT');
    },
  );

  test(
    'late source result after cancellation never writes a collection',
    () async {
      final response = Completer<Res<ComicDetails>>();
      final started = Completer<void>();
      sources.add(
        TestSource(
          'jm',
          idMatcher: RegExp(r'^\d+$'),
          loadComicInfo: (_) {
            started.complete();
            return response.future;
          },
        ),
      );
      user('加入 123');
      final task = tools.execute('later_add', {
        'comics': ['jm:123'],
      }, context);
      await started.future;
      context.run.cancel();
      final result = await task;
      expect(result['error']['code'], 'CANCELLED');
      response.complete(Res(details('jm', '123')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(later.contains('123', ComicType.fromKey('jm')), false);
      expect(store.seen(conversation.id, 'jm', '123'), null);
    },
  );

  test('late source result after timeout never writes a collection', () async {
    final response = Completer<Res<ComicDetails>>();
    sources.add(
      TestSource(
        'jm',
        idMatcher: RegExp(r'^\d+$'),
        loadComicInfo: (_) => response.future,
      ),
    );
    user('加入 123');
    final result = await tools.execute('later_add', {
      'comics': ['jm:123'],
    }, context);
    expect(result['data']['results'][0]['reason'], 'TIMEOUT');
    response.complete(Res(details('jm', '123')));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(later.getAll(), isEmpty);
  });

  test(
    'late showcase metadata after cancellation cannot create a group',
    () async {
      final response = Completer<Res<ComicDetails>>();
      final started = Completer<void>();
      sources.add(
        TestSource(
          'jm',
          loadComicInfo: (_) {
            started.complete();
            return response.future;
          },
        ),
      );
      final task = tools.execute('showcase_comics', {
        'comics': ['jm:339981'],
      }, context);
      await started.future;
      context.run.cancel();
      final result = await task;
      expect(result['error']['code'], 'CANCELLED');
      response.complete(Res(details('jm', '339981')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(store.showcases(conversation.id), isEmpty);
      expect(store.seen(conversation.id, 'jm', '339981'), isNull);
    },
  );

  test(
    'conversation deletion cascades, while turn truncation preserves showcase',
    () async {
      user('第一轮');
      final first = store.messages(conversation.id).single;
      user('第二轮');
      store.remember(conversation.id, comic);
      store.addShowcase(conversation.id, [comic], title: '保留');
      store.recordOperationComics(conversation.id, 'later', [comic]);
      store.saveContext(
        conversation.id,
        const AgentConversationContext(usage: AgentUsage(totalTokens: 100)),
      );
      store.saveUndo('undo', conversation.id, [
        {'kind': 'later', 'comic': comic.toJson()},
      ]);
      store.truncateFrom(first, include: false);
      expect(store.messages(conversation.id).length, 1);
      expect(store.showcases(conversation.id).length, 2);
      store.deleteConversation(conversation.id);
      final db = sqlite3.open(
        '${root.path}/agent/agent.db',
        mode: OpenMode.readOnly,
      );
      for (final table in [
        'messages',
        'comic_seen',
        'showcases',
        'showcase_items',
        'undo_records',
        'showcase_operations',
        'conversation_context',
      ]) {
        expect(db.select('SELECT COUNT(*) FROM $table;').first.values.first, 0);
      }
      db.dispose();
    },
  );

  test(
    'configuration and interrupted tool states survive restart locally',
    () async {
      const model = AgentModel(
        id: 'm',
        name: '测试',
        baseUrl: 'https://example.invalid/v1',
        model: 'test',
        supportsVision: true,
        includeReasoning: true,
      );
      await store.saveSettings(const AgentSettings(models: [model]), {
        'm': 'secret-for-test',
      });
      store.saveMessage(
        AgentMessage(
          id: 'pending',
          conversationId: conversation.id,
          role: 'assistant',
          createdAt: 1,
          state: 'running',
          parts: [
            {
              'type': 'tool_call',
              'id': 'call',
              'name': 'later_add',
              'arguments': {
                'comics': ['jm:123'],
              },
              'state': 'running',
            },
          ],
        ),
      );
      store.close();
      store = await AgentStore.open('${root.path}/agent');
      expect(store.settings.models.single.supportsVision, true);
      expect(store.secrets['m'], 'secret-for-test');
      expect(File('${root.path}/appdata.json').existsSync(), false);
      expect(
        File('${root.path}/agent/config.json').readAsStringSync(),
        isNot(contains('secret-for-test')),
      );
      final pending = store.messages(conversation.id).single;
      expect(pending.state, 'interrupted');
      expect(pending.tools.single['state'], 'interrupted');
    },
  );
}
