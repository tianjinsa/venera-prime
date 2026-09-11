import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/agent/agent_models.dart';
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
    });
    expect(later.getAll().single.id, '123');
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
    'showcase only accepts seen identities and uses their authoritative metadata',
    () async {
      store.remember(conversation.id, comic);
      final result = await tools.execute('showcase_comics', {
        'comics': [
          {...comic.toJson(), 'title': '伪造', 'cover': 'https://forged.invalid'},
          'jm:unknown',
        ],
      }, context);
      final groups = store.showcases(conversation.id);
      expect(groups.single.comics.single.title, comic.title);
      expect(result['data']['skipped'][0]['reason'], 'HALLUCINATED_REF');
      store.hideComic(groups.single.id, comic);
      expect(store.showcases(conversation.id), isEmpty);
      final another = store.createConversation();
      final denied = await tools.execute('showcase_comics', {
        'comics': ['jm:123'],
      }, AgentToolContext(another.id, AgentRun()));
      expect(denied['ok'], false);
    },
  );

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
    'resolve limits preserve remaining candidates and reject unsupported URL domains',
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
        'limit': 2,
      }, context);
      expect(first['data']['candidates'].length, 2);
      expect(first['data'].containsKey('items'), false);
      final remaining = await tools.execute('search_source', {
        'source_key': 'single',
        'keyword': 'book',
        'continuation': first['data']['continuation'],
      }, context);
      expect(remaining['data']['items'].length, 6);
      expect(calls, 1);
      final unsupported = await tools.execute('comic_resolve', {
        'query': 'https://unsupported.invalid/123',
      }, context);
      expect(unsupported['error']['code'], 'NO_LINK_SUPPORT');
      expect(calls, 1);
    },
  );

  test('id from the model alone cannot trigger a direct request', () async {
    var requests = 0;
    sources.add(
      TestSource(
        'jm',
        idMatcher: RegExp(r'^\d+$'),
        loadComicInfo: (_) async {
          requests++;
          return Res(details('jm', '999'));
        },
      ),
    );
    final result = await tools.execute('later_add', {
      'comics': [
        {'source_key': 'jm', 'comic_id': '999', 'title': '看似完整'},
      ],
    }, context);
    expect(result['data']['summary']['failed'], 1);
    expect(requests, 0);
    expect(later.getAll(), isEmpty);
  });

  test(
    'search fills defaults and preserves overflow with a scoped continuation',
    () async {
      List<String>? options;
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
      expect(first['data']['items'].length, 20);
      expect(first['data']['has_more'], true);
      final token = first['data']['continuation'];
      final second = await tools.execute('search_source', {
        'source_key': 'jm',
        'keyword': 'name',
        'continuation': token,
      }, context);
      expect(second['data']['items'].length, 3);
      expect(second['data']['has_more'], false);
      final invalid = await tools.execute('search_source', {
        'source_key': 'jm',
        'keyword': 'different',
        'continuation': token,
      }, context);
      expect(invalid['error']['code'], 'INVALID_CURSOR');
    },
  );

  test('cursor source rejects invented and cross-query cursors', () async {
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
          return Res([
            Comic('A', '', 'id', '', [], '', 'cursor', null, null),
          ], subData: cursor == null ? 'opaque:next' : null);
        }),
      ),
    );
    final invalid = await tools.execute('search_source', {
      'source_key': 'cursor',
      'keyword': 'q',
      'cursor': 'made-up',
    }, context);
    expect(invalid['error']['code'], 'INVALID_CURSOR');
    final first = await tools.execute('search_source', {
      'source_key': 'cursor',
      'keyword': 'q',
    }, context);
    expect(first['data']['next_cursor'], 'opaque:next');
    final second = await tools.execute('search_source', {
      'source_key': 'cursor',
      'keyword': 'q',
      'cursor': 'opaque:next',
    }, context);
    expect(second['data']['has_more'], false);
    expect(received, [null, 'opaque:next']);
  });

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
    'conversation deletion cascades, while turn truncation preserves showcase',
    () async {
      user('第一轮');
      final first = store.messages(conversation.id).single;
      user('第二轮');
      store.remember(conversation.id, comic);
      store.addShowcase(conversation.id, [comic], title: '保留');
      store.saveUndo('undo', conversation.id, [
        {'kind': 'later', 'comic': comic.toJson()},
      ]);
      store.truncateFrom(first, include: false);
      expect(store.messages(conversation.id).length, 1);
      expect(store.showcases(conversation.id).length, 1);
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
