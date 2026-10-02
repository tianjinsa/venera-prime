import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_app_bridge.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_source_backups.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/foundation/res.dart';
import 'agent_test_support.dart';

class RichSource implements ComicSource {
  @override
  final String key;
  @override
  String get name => '源$key';
  @override
  String version;
  @override
  bool isLogged;
  @override
  final SearchPageData? searchPageData;
  @override
  final LoadComicFunc? loadComicInfo;
  @override
  final LoadComicPagesFunc? loadComicPages;
  @override
  final List<ExplorePageData> explorePages;
  @override
  final CategoryData? categoryData;
  @override
  final CategoryComicsData? categoryComicsData;
  @override
  final CommentsLoader? commentsLoader;
  @override
  final ChapterCommentsLoader? chapterCommentsLoader;
  @override
  final FavoriteData? favoriteData;
  @override
  RegExp? get idMatcher => null;
  @override
  LinkHandler? get linkHandler => null;
  @override
  String get filePath => '/sources/$key.js';
  RichSource(
    this.key, {
    this.version = '1.0.0',
    this.isLogged = true,
    this.searchPageData,
    this.loadComicInfo,
    this.loadComicPages,
    this.explorePages = const [],
    this.categoryData,
    this.categoryComicsData,
    this.commentsLoader,
    this.chapterCommentsLoader,
    this.favoriteData,
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Comic comic(String source, String id, [String? title]) =>
    Comic(title ?? '漫画$id', '', id, '作者', ['标签'], '', source, null, null);

History history(String source, String id, int time, {int ep = 2}) =>
    History.fromMap({
      'type': ComicType.fromKey(source).value,
      'time': time,
      'title': '历史$id',
      'subtitle': '作者',
      'cover': 'https://example.invalid/$id',
      'ep': ep,
      'page': 5,
      'id': id,
      'readEpisode': ['1', '2'],
      'max_page': 20,
    });

class FakeBridge extends AgentAppBridge {
  final historyItems = <History>[];
  final localItems = <LocalComic>[];
  final queue = <AgentDownloadTask>[];
  final downloaded = <(String, List<String>?)>[];
  final controlled = <String>[];
  final opened = <String>[];
  final settings = <String, Object?>{};
  final updateItems = <AgentComicUpdate>[];
  final deletedChapters = <String>[];
  final libraries = <AgentSourceLibrary>[];
  final catalog = <AgentCatalogSource>[];
  final installed = <String>[];
  final statistics = <ReadingStatistic>[];
  final updatesAvailable = <String, String>{};
  final updatedSources = <String>[];
  List<ComicSource>? sources;
  final logItems = <LogItem>[];
  final code = <String, String>{};
  late AgentSourceBackups backups;
  String? followed;
  var saves = 0;

  @override
  bool get historyReady => true;
  @override
  bool get localReady => true;
  @override
  Future<void> initHistory() async {}
  @override
  List<History> histories() => historyItems.toList();
  @override
  History? findHistory(String id, ComicType type) =>
      historyItems.where((h) => h.id == id && h.type == type).firstOrNull;
  @override
  void removeHistories(List<ComicID> ids) => historyItems.removeWhere(
    (h) => ids.any((id) => id.id == h.id && id.type == h.type),
  );
  @override
  void addHistory(History value) => historyItems.add(value);
  @override
  Future<void> initLocal() async {}
  @override
  List<LocalComic> localComics() => localItems.toList();
  @override
  LocalComic? findLocal(String id, ComicType type) =>
      localItems.where((c) => c.id == id && c.comicType == type).firstOrNull;
  @override
  void deleteLocal(LocalComic comic) => localItems.remove(comic);
  @override
  void deleteLocalChapters(LocalComic comic, List<String> chapters) {
    deletedChapters.add('${comic.id}:${chapters.join(',')}');
    final index = localItems.indexOf(comic);
    final remaining = comic.downloadedChapters
        .where((id) => !chapters.contains(id))
        .toList();
    if (remaining.isEmpty) {
      localItems.removeAt(index);
    } else {
      localItems[index] = LocalComic(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        tags: comic.tags,
        directory: comic.directory,
        chapters: comic.chapters,
        cover: comic.cover,
        comicType: comic.comicType,
        downloadedChapters: remaining,
        createdAt: comic.createdAt,
      );
    }
  }

  @override
  List<AgentDownloadTask> downloads() => queue.toList();
  @override
  bool isDownloading(String id, ComicType type) => queue.any(
    (t) => t.comicId == id && ComicType.fromKey(t.sourceKey) == type,
  );
  @override
  void download(
    ComicSource source,
    ComicDetails details,
    List<String>? chapters,
  ) => downloaded.add(('${source.key}:${details.comicId}', chapters));
  @override
  bool controlDownload(String id, ComicType type, String action) {
    if (!isDownloading(id, type)) return false;
    controlled.add('$action:$id');
    return true;
  }

  @override
  String? followedFolder() => followed;
  @override
  List<AgentComicUpdate> updates(String folder) => updateItems.toList();
  @override
  Stream<UpdateProgress> checkUpdates(String folder) async* {
    yield UpdateProgress(2, 1, 0, 1);
    yield UpdateProgress(2, 2, 1, 1, null, '源超时');
  }

  @override
  Future<void> setFollowedFolder(String? folder) async {
    followed = folder;
    saves++;
  }

  @override
  List<AgentSourceLibrary> sourceLibraries() => libraries.toList();
  @override
  void addSourceLibrary(String name, String url) => libraries.add(
    AgentSourceLibrary(
      id: 'lib${libraries.length + 1}',
      name: name.isEmpty ? Uri.parse(url).host : name,
      url: url,
      enabled: true,
    ),
  );
  @override
  void removeSourceLibrary(String id) =>
      libraries.removeWhere((library) => library.id == id);
  @override
  Object? setting(String key) => settings[key];
  @override
  void setSetting(String key, Object? value) => settings[key] = value;
  @override
  Future<void> saveSettings() async => saves++;
  @override
  Future<int> checkSourceUpdates() async => updatesAvailable.length;
  @override
  Map<String, String> availableSourceUpdates() => updatesAvailable;
  @override
  Future<bool> updateSource(ComicSource source) async {
    updatedSources.add(source.key);
    return true;
  }

  @override
  Future<(List<AgentCatalogSource>, List<String>)> sourceCatalog() async =>
      (catalog.toList(), <String>[]);
  @override
  Future<ComicSource> installSource(AgentCatalogSource entry) async {
    installed.add(entry.key);
    final source = RichSource(entry.key, version: entry.version);
    sources?.add(source);
    return source;
  }

  @override
  List<LogItem> logs() => logItems.toList();
  @override
  Future<String> readSourceCode(ComicSource source) async => code[source.key]!;
  @override
  Future<void> writeSourceCode(ComicSource source, String value) async {
    if (value.contains('BROKEN')) throw Exception('SyntaxError: BROKEN');
    code[source.key] = value;
  }

  @override
  AgentSourceBackups get sourceBackups => backups;

  @override
  Future<void> initStatistics() async {}
  @override
  List<ReadingStatistic> readingStatistics(int days) => statistics;
  @override
  int readingSeconds() => 7200;
  @override
  void open(Widget Function() builder) => opened.add('page');
  @override
  void openComic(String sourceKey, String id, {String? title, String? cover}) =>
      opened.add('details:$sourceKey:$id');
  @override
  void openReader(
    ComicDetails details, {
    int? chapter,
    int? page,
    int? group,
  }) => opened.add('reader:${details.comicId}:$chapter:$page');
  @override
  void openLocalReader(LocalComic comic) => opened.add('local:${comic.id}');
  @override
  void openSearch(String keyword, {String? sourceKey, List<String>? options}) =>
      opened.add('search:$keyword:$sourceKey');
  @override
  void openPage(AgentAppPage page) => opened.add(page.id);
}

void main() {
  late Directory root;
  late AgentStore store;
  late AgentTools tools;
  late LocalFavoritesManager favorites;
  late ReadLaterManager later;
  late List<ComicSource> sources;
  late FakeBridge app;
  late AgentToolContext context;
  var detailRequests = 0;

  ComicDetails details(String source, String id, {int chapters = 75}) =>
      ComicDetails.fromJson({
        'title': '详情$id',
        'subtitle': '作者',
        'cover': 'https://example.invalid/$id',
        'description': '简介',
        'tags': <String, List<String>>{},
        'sourceKey': source,
        'comicId': id,
        'subId': 'sub-$id',
        'chapters': {for (var i = 1; i <= chapters; i++) 'c$i': '第$i话'},
      });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-agent-more-tools-');
    configureAgentTestPaths(root.path);
    appdata.settings['webdav'] = [];
    favorites = LocalFavoritesManager()..close();
    later = ReadLaterManager()..close();
    await favorites.init();
    await later.init();
    store = await AgentStore.open('${root.path}/agent');
    sources = [];
    app = FakeBridge()
      ..sources = sources
      ..backups = AgentSourceBackups(Directory('${root.path}/backups'));
    detailRequests = 0;
    tools = AgentTools(
      store,
      favorites: favorites,
      later: later,
      initializeSources: () async {},
      sources: () => sources,
      sourceTimeout: const Duration(milliseconds: 200),
      app: app,
    );
    context = AgentToolContext(store.createConversation().id, AgentRun());
  });
  tearDown(() async {
    store.close();
    favorites.close();
    later.close();
    await root.delete(recursive: true);
  });

  Future<AgentJson> call(String name, AgentJson args) async {
    final result = await tools.execute(name, args, context);
    expect(result['ok'], true, reason: '$name: ${jsonEncode(result)}');
    return agentObject(result['data']);
  }

  RichSource detailSource(String key, {int chapters = 75}) {
    final source = RichSource(
      key,
      loadComicInfo: (id) async {
        detailRequests++;
        return Res(details(key, id, chapters: chapters));
      },
      loadComicPages: (_, _) async => const Res([]),
    );
    sources.add(source);
    return source;
  }

  test('advertised tools are batch-first, labelled and schema-valid', () {
    final names = AgentTools.schemas
        .map((s) => s['function']['name'] as String)
        .toList();
    expect(names.toSet().length, names.length);
    expect(names.length, 55);
    for (final name in names) {
      expect(agentToolLabels, contains(name), reason: name);
      final params = AgentTools.schemas.firstWhere(
        (s) => s['function']['name'] == name,
      )['function']['parameters'];
      expect(params['additionalProperties'], false, reason: name);
      expect(
        (params['required'] as List).every(
          (k) => (params['properties'] as Map).containsKey(k),
        ),
        true,
        reason: name,
      );
    }
    expect(AgentTools.writeTools.every(names.contains), true);
    // Batch tools replace single-item variants, and superseded or excluded
    // capabilities are not offered.
    for (final name in [
      'fav_check',
      'later_check',
      'fav_search',
      'comic_open_by_id',
      'list_search_options',
      'updates_mark_read',
      'settings_get',
      'settings_set',
    ]) {
      expect(names, isNot(contains(name)));
    }
    for (final name in [
      'fav_add',
      'later_add',
      'showcase_comics',
      'fav_create_folder',
      'fav_rename_folder',
      'download_start',
      'net_fav_add',
      'source_install',
      'history_remove',
    ]) {
      final properties =
          AgentTools.schemas.firstWhere(
                (s) => s['function']['name'] == name,
              )['function']['parameters']['properties']
              as Map;
      expect(
        properties.values.any((p) => p is Map && p['type'] == 'array'),
        true,
        reason: name,
      );
    }
    expect(jsonEncode(AgentTools.schemas), isNot(contains('loadComicPages')));
  });

  test('comic details list 30 chapters and page the rest from cache', () async {
    detailSource('jm');
    final detail = await call('comic_get', {
      'source_key': 'jm',
      'comic_id': '7',
    });
    final chapters = detail['chapters'] as Map;
    expect(chapters['count'], 75);
    expect(chapters['items'], hasLength(30));
    expect(chapters['items'][0], {'index': 1, 'id': 'c1', 'title': '第1话'});
    expect(chapters['total_pages'], 3);
    expect(chapters['has_more'], true);
    expect(detail['in_favorites'], false);
    expect(detail['history'], isNull);
    final last = await call('comic_chapters', {
      'source_key': 'jm',
      'comic_id': '7',
      'page': 3,
    });
    expect(last['items'], hasLength(15));
    expect(last['items'].first['index'], 61);
    expect(last['has_more'], false);
    expect(detailRequests, 1);
    expect(
      agentToolCaption({
        'name': 'comic_chapters',
        'state': 'done',
        'result': {'ok': true, 'data': last},
      }),
      '第 3/3 页 · 共 75 章',
    );
  });

  test('grouped chapters are numbered within groups', () async {
    sources.add(
      RichSource(
        'jm',
        loadComicInfo: (id) async => Res(
          ComicDetails.fromJson({
            'title': '分组',
            'cover': '',
            'tags': <String, List<String>>{},
            'sourceKey': 'jm',
            'comicId': id,
            'chapters': {
              '正篇': {'a1': '一', 'a2': '二'},
              '番外': {'b1': '外一'},
            },
          }),
        ),
      ),
    );
    final page = await call('comic_chapters', {
      'source_key': 'jm',
      'comic_id': '1',
      'group': '番外',
    });
    expect(page['items'], [
      {'group': '番外', 'group_index': 2, 'index': 1, 'id': 'b1', 'title': '外一'},
    ]);
    expect(page['groups'], [
      {'title': '正篇', 'count': 2},
      {'title': '番外', 'count': 1},
    ]);
  });

  test('multi-source search pages, caches and isolates failures', () async {
    final calls = <String>[];
    sources.addAll([
      RichSource(
        'paged',
        searchPageData: SearchPageData(null, (keyword, page, _) async {
          calls.add('paged:$page');
          return Res(
            List.generate(30, (i) => comic('paged', '$page-$i')),
            subData: 4,
          );
        }, null),
      ),
      RichSource(
        'cursor',
        searchPageData: SearchPageData(null, null, (keyword, next, _) async {
          calls.add('cursor:$next');
          return Res([comic('cursor', 'x$next')], subData: 'after-$next');
        }),
      ),
      RichSource(
        'broken',
        searchPageData: SearchPageData(null, (_, _, _) async {
          return const Res.error('维护中');
        }, null),
      ),
    ]);
    app.settings['searchSources'] = ['cursor', 'paged', 'broken', 'missing'];
    final first = await call('search_all', {'keyword': 'q', 'per_source': 10});
    final results = (first['results'] as List).cast<Map>();
    expect(results.map((r) => r['source_key']), ['cursor', 'paged', 'broken']);
    expect(first['summary'], {'total': 3, 'ok': 2, 'skipped': 0, 'failed': 1});
    final paged = results[1];
    expect(paged['page'], 1);
    expect(paged['max_page'], 4);
    expect(paged['next_page'], 2);
    expect(paged['count_on_page'], 30);
    expect(paged['items'], hasLength(10));
    expect(paged['truncated'], true);
    expect(results[0]['next_cursor'], 'after-null');
    expect(results[2]['error']['code'], 'SEARCH_FAILED');

    final second = await call('search_all', {
      'keyword': 'q',
      'page': 2,
      'cursors': {'cursor': 'after-null'},
      'source_keys': ['paged', 'cursor'],
    });
    expect((second['results'] as List).map((r) => r['page']), [2, null]);
    // Repeating a page is served from the cache keyed by all parameters.
    await call('search_source', {
      'source_key': 'paged',
      'keyword': 'q',
      'page': 2,
    });
    final repeated = await call('search_source', {
      'source_key': 'paged',
      'keyword': 'q',
      'page': 2,
    });
    expect(repeated['from_cache'], true);
    await call('search_source', {
      'source_key': 'paged',
      'keyword': 'other',
      'page': 2,
    });
    expect(calls, [
      'cursor:null',
      'paged:1',
      'paged:2',
      'cursor:after-null',
      'paged:2',
    ]);
    // Cursor sources cannot jump to a page without their cursor.
    final skipped = await call('search_all', {
      'keyword': 'q',
      'page': 3,
      'source_keys': ['cursor'],
    });
    expect(skipped['results'][0]['reason'], 'CURSOR_REQUIRED');
  });

  test('categories, explore pages and rankings are paged by source', () async {
    final loads = <String>[];
    sources.add(
      RichSource(
        'jm',
        explorePages: [
          ExplorePageData(
            '最新',
            ExplorePageType.multiPageComicList,
            (page) async => Res([comic('jm', 'n$page')], subData: 2),
            null,
            null,
            null,
          ),
          ExplorePageData(
            '推荐',
            ExplorePageType.singlePageWithMultiPart,
            null,
            null,
            () async => Res([
              ExplorePagePart('热门', [
                comic('jm', 'h1'),
                comic('jm', 'h2'),
              ], null),
            ]),
            null,
          ),
        ],
        categoryData: CategoryData(
          title: '分类',
          key: 'jm-category',
          enableRankingPage: true,
          categories: [
            FixedCategoryPart('题材', [
              for (var i = 0; i < 60; i++)
                CategoryItem(
                  '题材$i',
                  PageJumpTarget('jm', 'category', {
                    'category': 'genre',
                    'param': '$i',
                  }),
                ),
            ]),
            FixedCategoryPart('标签', [
              CategoryItem(
                '热血',
                PageJumpTarget('jm', 'search', {'text': '热血'}),
              ),
            ]),
          ],
        ),
        categoryComicsData: CategoryComicsData(
          options: [
            CategoryComicsOptions(
              '排序',
              LinkedHashMap.of({'new': '最新', 'hot': '最热'}),
              [],
              null,
            ),
            CategoryComicsOptions('仅排行', LinkedHashMap.of({'x': 'x'}), [
              'genre',
            ], null),
          ],
          load: (category, param, options, page) async {
            loads.add('$category/$param/${options.join(',')}/$page');
            return Res([comic('jm', 'c$param')], subData: 3);
          },
          rankingData: RankingData(
            {'day': '日榜', 'week': '周榜'},
            (option, page) async => Res([comic('jm', '$option$page')]),
            null,
          ),
        ),
      ),
    );
    final info = await call('source_info', {'source_key': 'jm'});
    expect(info['explore_pages'], [
      {'title': '最新', 'type': 'multiPageComicList'},
      {'title': '推荐', 'type': 'singlePageWithMultiPart'},
    ]);
    expect(info['category_groups'], [
      {'title': '题材', 'count': 60},
      {'title': '标签', 'count': 1},
    ]);
    expect(info['ranking_options'], {'day': '日榜', 'week': '周榜'});
    final categories = await call('source_categories', {'source_key': 'jm'});
    expect(categories['total'], 61);
    expect(categories['total_pages'], 2);
    expect(categories['items'][1], {
      'group': '题材',
      'label': '题材1',
      'kind': 'category',
      'category': 'genre',
      'param': '1',
    });
    final tags = await call('source_categories', {
      'source_key': 'jm',
      'group': '标签',
    });
    expect(tags['items'][0]['keyword'], '热血');

    final listed = await call('category_comics', {
      'source_key': 'jm',
      'category': 'genre',
      'param': '4',
    });
    // Options hidden for this category are not sent.
    expect(listed['options'], ['new']);
    expect(listed['max_page'], 3);
    expect(listed['next_page'], 2);
    await call('category_comics', {
      'source_key': 'jm',
      'category': 'genre',
      'param': '4',
      'options': ['hot'],
      'page': 2,
    });
    expect(loads, ['genre/4/new/1', 'genre/4/hot/2']);

    final latest = await call('explore_load', {
      'source_key': 'jm',
      'title': '最新',
      'page': 2,
    });
    expect(latest['items'][0]['comic_id'], 'n2');
    expect(latest['has_more'], false);
    final parts = await call('explore_load', {
      'source_key': 'jm',
      'title': '推',
    });
    expect(parts['parts'][0]['count'], 2);
    final ranking = await call('ranking_comics', {
      'source_key': 'jm',
      'option': '周榜',
    });
    expect(ranking['option'], 'week');
    expect(ranking['items'][0]['comic_id'], 'week1');
    // Items from discovery can be showcased without another request.
    final shown = await call('showcase_comics', {
      'comics': ['jm:h1', 'jm:week1'],
    });
    expect(shown['count'], 2);
  });

  test('comments use the detail sub id and report pages', () async {
    String? subId;
    sources.add(
      RichSource(
        'jm',
        loadComicInfo: (id) async => Res(details('jm', id)),
        commentsLoader: (id, sub, page, reply) async {
          subId = sub;
          return Res([
            Comment.fromJson({
              'userName': '读者',
              'content': '好看',
              'id': 1,
              'replyCount': 2,
            }),
          ], subData: 5);
        },
      ),
    );
    final comments = await call('comic_comments', {
      'source_key': 'jm',
      'comic_id': '9',
      'page': 2,
    });
    expect(subId, 'sub-9');
    expect(comments['max_page'], 5);
    expect(comments['has_more'], true);
    expect(comments['comments'][0]['user'], '读者');
    final unsupported = await tools.execute('comic_comments', {
      'source_key': 'jm',
      'comic_id': '9',
      'chapter_id': 'c1',
    }, context);
    expect(unsupported['error']['code'], 'NO_COMMENT_SUPPORT');
  });

  test(
    'local favorites and folders are searchable, batched and paged',
    () async {
      for (var i = 0; i < 120; i++) {
        favorites.createFolder('夹$i');
      }
      final folders = await call('fav_list_folders', {'page': 3});
      expect(folders['total'], 120);
      expect(folders['items'], hasLength(20));
      expect(folders['total_pages'], 3);
      final filtered = await call('fav_list_folders', {'keyword': '夹11'});
      expect(filtered['total'], 11);

      final created = await call('fav_create_folder', {
        'names': ['新A', '新A', '夹1', '"bad'],
      });
      expect(created['summary'], {
        'total': 4,
        'ok': 1,
        'skipped': 2,
        'failed': 1,
      });
      // Saved conversations may still retry the single-name form.
      final legacy = await call('fav_create_folder', {'name': '旧式'});
      expect(legacy['status'], 'created');

      app.settings['quickFavorite'] = '新A';
      final renamed = await call('fav_rename_folder', {
        'renames': [
          {'folder': '新A', 'new_name': '改名A'},
          {'folder': '不存在', 'new_name': 'x'},
          {'folder': '夹2', 'new_name': '夹3'},
        ],
      });
      expect(renamed['summary'], {
        'total': 3,
        'ok': 1,
        'skipped': 0,
        'failed': 2,
      });
      expect(renamed['results'][1]['reason'], 'FOLDER_NOT_FOUND');
      expect(renamed['results'][2]['reason'], 'FOLDER_EXISTS');
      expect(favorites.existsFolder('改名A'), true);
      expect(app.settings['quickFavorite'], '改名A');
      expect(app.saves, 1);

      store.remember(
        context.conversationId,
        const AgentComic(
          sourceKey: 'jm',
          comicId: '1',
          title: '海贼王',
          subtitle: '尾田',
        ),
      );
      await call('fav_add', {
        'folder': '夹5',
        'comics': ['jm:1'],
      });
      final searched = await call('fav_list', {'keyword': '尾田'});
      expect(searched['total'], 1);
      expect(searched['items'][0]['folder'], '夹5');
    },
  );

  test('history lists, removes and restores progress', () async {
    for (var i = 0; i < 25; i++) {
      app.historyItems.add(history('jm', '$i', 1000 + i));
    }
    sources.add(RichSource('jm'));
    final page = await call('history_list', {'page': 2});
    expect(page['total'], 25);
    expect(page['items'], hasLength(5));
    expect(page['items'][0], containsPair('source_key', 'jm'));
    expect(page['items'][0], containsPair('chapter', 2));
    expect(page['items'][0], isNot(contains('cover')));
    final searched = await call('history_list', {'keyword': '历史2'});
    // 历史2 and 历史20–历史24.
    expect(searched['total'], 6);

    final status = await call('comic_status', {
      'comics': ['jm:3', 'jm:missing'],
    });
    expect(status['results'][0]['history']['page'], 5);
    expect(status['results'][1]['history'], isNull);

    final removed = await call('history_remove', {
      'comics': ['jm:3', 'jm:4', 'jm:none'],
    });
    expect(removed['summary']['ok'], 2);
    expect(removed['summary']['missing'], 1);
    expect(app.historyItems, hasLength(23));
    final undo = tools.undo(removed['undo_id'] as String, context);
    expect(undo, {'restored': 2, 'skipped': 0, 'failed': 0});
    final restored = app.findHistory('3', ComicType.fromKey('jm'))!;
    expect(restored.ep, 2);
    expect(restored.readEpisode, {'1', '2'});
  });

  test('latest downloads the last chapters in the returned order', () async {
    detailSource('jm', chapters: 4);
    app.localItems.add(
      LocalComic(
        id: '5',
        title: '已下',
        subtitle: '',
        tags: const [],
        directory: 'd',
        chapters: ComicChapters({for (var i = 1; i <= 4; i++) 'c$i': '$i'}),
        cover: '',
        comicType: ComicType.fromKey('jm'),
        downloadedChapters: const ['c2'],
        createdAt: DateTime(2026),
      ),
    );
    final started = await call('download_start', {
      'comics': [
        {'source_key': 'jm', 'comic_id': '5', 'latest': 3},
        {'source_key': 'jm', 'comic_id': '6', 'latest': 10},
      ],
    });
    expect(started['summary']['ok'], 2);
    expect(app.downloaded.map((d) => '${d.$1} ${d.$2}'), [
      'jm:5 [c3, c4]',
      'jm:6 [c1, c2, c3, c4]',
    ]);
    final mixed = await tools.execute('download_start', {
      'comics': [
        {
          'source_key': 'jm',
          'comic_id': '7',
          'latest': 1,
          'chapters': ['c1'],
        },
      ],
    }, context);
    expect(mixed['error']['code'], 'INVALID_ARGUMENT');
  });

  test('downloads queue missing chapters and control existing tasks', () async {
    detailSource('jm', chapters: 4);
    app.localItems.add(
      LocalComic(
        id: '5',
        title: '已下',
        subtitle: '',
        tags: const [],
        directory: 'd',
        chapters: ComicChapters({for (var i = 1; i <= 4; i++) 'c$i': '$i'}),
        cover: '',
        comicType: ComicType.fromKey('jm'),
        downloadedChapters: const ['c1', 'c2'],
        createdAt: DateTime(2026),
      ),
    );
    app.queue.add(
      const AgentDownloadTask(
        sourceKey: 'jm',
        comicId: '9',
        title: '下载中',
        progress: .4,
        paused: false,
        failed: false,
        message: '',
      ),
    );
    final started = await call('download_start', {
      'comics': [
        {'source_key': 'jm', 'comic_id': '1'},
        {
          'source_key': 'jm',
          'comic_id': '5',
          'chapters': ['c1', 'c3'],
        },
        {
          'source_key': 'jm',
          'comic_id': '5',
          'chapters': ['c2'],
        },
        {'source_key': 'jm', 'comic_id': '9'},
        {
          'source_key': 'jm',
          'comic_id': '2',
          'chapters': ['c99'],
        },
      ],
    });
    expect(started['summary'], {
      'total': 5,
      'ok': 2,
      'skipped': 2,
      'failed': 1,
    });
    expect(app.downloaded.map((d) => '${d.$1} ${d.$2}'), [
      'jm:1 null',
      'jm:5 [c3]',
    ]);
    expect(started['results'][3]['reason'], 'ALREADY_QUEUED');
    expect(started['results'][4]['reason'], 'INVALID_CHAPTER');

    final queue = await call('download_list', {});
    expect(queue['items'][0], containsPair('status', 'downloading'));
    expect(queue['items'][0], containsPair('progress', 40));
    final control = await call('download_control', {
      'action': 'pause',
      'comics': ['jm:9', 'jm:1'],
    });
    expect(control['summary'], {
      'total': 2,
      'ok': 1,
      'skipped': 1,
      'failed': 0,
    });
    expect(app.controlled, ['pause:9']);

    final local = await call('local_list', {'keyword': '已下'});
    expect(local['items'][0], containsPair('downloaded_chapters', 2));
    final deleted = await call('local_delete', {
      'comics': ['jm:5', 'jm:9'],
    });
    expect(deleted['summary']['ok'], 1);
    expect(deleted['results'][1]['reason'], 'NOT_PRESENT');
    expect(app.localItems, isEmpty);
  });

  test('follow updates refresh, page and choose the folder', () async {
    final missing = await tools.execute('updates_list', {}, context);
    expect(missing['error']['code'], 'NO_FOLLOW_FOLDER');
    favorites.createFolder('追更');
    app.followed = '追更';
    sources.add(RichSource('jm'));
    final item = FavoriteItem(
      id: '1',
      name: '新章节',
      coverPath: '',
      author: '作者',
      type: ComicType.fromKey('jm'),
      tags: const [],
    );
    favorites.addComic('追更', item);
    app.updateItems.add(AgentComicUpdate(item, '2026-09-01|ch|zh'));
    final listed = await call('updates_list', {'refresh': true});
    expect(listed['refresh'], {
      'checked': 2,
      'updated': 1,
      'errors': 1,
      'error_samples': ['：源超时'],
    });
    expect(listed['items'][0]['update_time'], '2026-09-01');
    // Reading state belongs to the user.
    expect(
      AgentTools.schemas.map((s) => s['function']['name']),
      isNot(contains('updates_mark_read')),
    );

    favorites.createFolder('新追更');
    final same = await call('updates_set_folder', {'folder': '追更'});
    expect(same['reason'], 'ALREADY_FOLLOWED');
    final changed = await call('updates_set_folder', {'folder': '新追更'});
    expect(changed, containsPair('status', 'set'));
    expect(changed['previous'], '追更');
    expect(app.followed, '新追更');
    final missingFolder = await tools.execute('updates_set_folder', {
      'folder': '不存在',
    }, context);
    expect(missingFolder['error']['code'], 'FOLDER_NOT_FOUND');
    final disabled = await call('updates_set_folder', {});
    expect(disabled['status'], 'disabled');
    expect(app.followed, isNull);
  });

  test('downloaded chapters are listed and deleted in batches', () async {
    LocalComic local(String id, List<String> downloaded) => LocalComic(
      id: id,
      title: '本地$id',
      subtitle: '',
      tags: const [],
      directory: 'd$id',
      chapters: ComicChapters({for (var i = 1; i <= 4; i++) 'c$i': '第$i话'}),
      cover: '',
      comicType: ComicType.fromKey('jm'),
      downloadedChapters: downloaded,
      createdAt: DateTime(2026),
    );
    app.localItems.addAll([
      local('1', ['c1', 'c2', 'c3']),
      local('2', ['c1']),
      local('3', ['c4']),
    ]);
    final chapters = await call('local_chapters', {
      'source_key': 'jm',
      'comic_id': '1',
    });
    expect(chapters['total'], 3);
    expect(chapters['items'][1], {'id': 'c2', 'title': '第2话'});
    final missing = await tools.execute('local_chapters', {
      'source_key': 'jm',
      'comic_id': '9',
    }, context);
    expect(missing['error']['code'], 'NOT_PRESENT');

    final deleted = await call('local_delete', {
      'comics': [
        // By id and by title; an unknown chapter is reported.
        {
          'source_key': 'jm',
          'comic_id': '1',
          'chapters': ['c1', '第3话', '第9话'],
        },
        // Removing the last chapter removes the comic.
        {
          'source_key': 'jm',
          'comic_id': '2',
          'chapters': ['c1'],
        },
        {
          'source_key': 'jm',
          'comic_id': '3',
          'chapters': ['c1'],
        },
      ],
    });
    expect(deleted['summary'], {
      'total': 3,
      'ok': 2,
      'skipped': 1,
      'failed': 0,
    });
    expect(deleted['results'][0], containsPair('status', 'chapters_deleted'));
    expect(deleted['results'][0]['missing_chapters'], ['第9话']);
    expect(deleted['results'][0]['remaining_chapters'], 1);
    expect(deleted['results'][1]['status'], 'deleted');
    expect(deleted['results'][2]['reason'], 'CHAPTERS_NOT_PRESENT');
    expect(app.deletedChapters, ['1:c1,c3', '2:c1']);
    expect(app.localItems.map((c) => c.id), ['1', '3']);
    expect(app.localItems.first.downloadedChapters, ['c2']);
    final invalid = await tools.execute('local_delete', {
      'comics': [
        {'source_key': 'jm', 'comic_id': '1', 'chapters': []},
      ],
    }, context);
    expect(invalid['error']['code'], 'INVALID_ARGUMENT');
  });

  test('deleted folders can be restored with their comics', () async {
    favorites.createFolder('旧');
    favorites.createFolder('追');
    for (final (folder, id) in [('旧', '1'), ('旧', '2'), ('追', '3')]) {
      favorites.addComic(
        folder,
        FavoriteItem(
          id: id,
          name: '漫画$id',
          coverPath: '',
          author: '',
          type: ComicType.fromKey('jm'),
          tags: const [],
        ),
      );
    }
    app.followed = '追';
    app.settings['quickFavorite'] = '旧';
    final deleted = await call('fav_delete_folder', {
      'names': ['旧', '追', '旧', '无'],
    });
    expect(deleted['summary'], {
      'total': 4,
      'ok': 2,
      'skipped': 2,
      'failed': 0,
    });
    expect(deleted['results'][0]['comics'], 2);
    expect(deleted['results'][1]['follow_updates_disabled'], true);
    expect(favorites.existsFolder('旧'), false);
    expect(app.followed, isNull);
    expect(app.settings['quickFavorite'], isNull);

    final restored = tools.undo(deleted['undo_id'] as String, context);
    expect(restored, {'restored': 3, 'skipped': 0, 'failed': 0});
    expect(favorites.existsFolder('旧'), true);
    expect(favorites.getFolderComics('旧').map((c) => c.id).toSet(), {'1', '2'});
    expect(favorites.getFolderComics('追').single.id, '3');
  });

  test(
    'logs are newest first, merged, filtered and read after a mark',
    () async {
      app.logItems.addAll([
        LogItem(LogLevel.info, 'App', '启动'),
        for (var i = 0; i < 3; i++) LogItem(LogLevel.warning, 'JsEngine', '慢'),
        LogItem(LogLevel.error, 'Network', 'copy 源 404'),
      ]);
      final first = await call('app_logs', {});
      expect(first['total'], 2);
      expect(first['items'][0]['title'], 'Network');
      expect(first['items'][1]['repeats'], 3);
      expect(first['latest_id'], app.logItems.last.id);
      expect((await call('app_logs', {'level': 'all'}))['total'], 3);
      expect((await call('app_logs', {'keyword': 'COPY'}))['total'], 1);

      app.logItems.add(LogItem(LogLevel.error, 'Network', '新错误'));
      final after = await call('app_logs', {'after_id': first['latest_id']});
      expect(after['items'].single['content'], '新错误');
    },
  );

  test('source code is read in ranges and searched across sources', () async {
    sources.addAll([RichSource('a'), RichSource('b')]);
    app.code['a'] = List.generate(300, (i) => 'line $i').join('\r\n');
    app.code['b'] = 'class B extends ComicSource {\n  baseUrl = "x";\n}';
    final read = await call('source_code_read', {
      'reads': [
        {'source_key': 'a', 'start_line': 250},
        {'source_key': 'b'},
        {'source_key': 'none'},
      ],
    });
    final results = read['results'] as List;
    expect(results[0]['end_line'], 300);
    expect(results[0]['content'], startsWith('250| line 249'));
    expect(results[0].containsKey('next_start_line'), false);
    expect(results[1]['file_name'], 'b.js');
    expect(results[2]['error']['code'], 'SOURCE_NOT_FOUND');

    final grep = await call('source_code_grep', {
      'pattern': r'line 1\d\d$',
      'regex': true,
      'context_lines': 0,
    });
    expect(grep['total'], 100);
    expect(grep['matches_by_source'], {'a': 100});
    final literal = await call('source_code_grep', {'pattern': 'BASEURL'});
    expect(literal['items'].single['line'], 2);
    expect(literal['items'].single['content'], contains('1| class B'));
  });

  test(
    'edits are all-or-nothing, parsed and backed up automatically',
    () async {
      sources.add(RichSource('a'));
      app.code['a'] = 'const host = "old";\nfetch(host);\nfetch(host);';

      Future<AgentJson> edit(List<AgentJson> edits) => tools.execute(
        'source_code_edit',
        {'source_key': 'a', 'edits': edits},
        context,
      );

      final missing = await edit([
        {'old_text': '"old"', 'new_text': '"new"'},
        {'old_text': 'absent', 'new_text': 'x'},
      ]);
      expect(missing['error']['code'], 'EDIT_NOT_FOUND');
      final ambiguous = await edit([
        {'old_text': 'fetch(host)', 'new_text': 'get(host)'},
      ]);
      expect(ambiguous['error']['code'], 'EDIT_AMBIGUOUS');
      final broken = await edit([
        {'old_text': '"old"', 'new_text': 'BROKEN'},
      ]);
      expect(broken['error']['code'], 'PARSE_FAILED');
      expect(app.code['a'], contains('"old"'));
      expect(await app.backups.list(), isEmpty);

      final saved = await call('source_code_edit', {
        'source_key': 'a',
        'edits': [
          {'old_text': '"old"', 'new_text': '"new"'},
          {
            'old_text': 'fetch(host)',
            'new_text': 'get(host)',
            'replace_all': true,
          },
        ],
      });
      expect(saved['edits'], [
        {'replacements': 1, 'line': 1},
        {'replacements': 2, 'line': 2},
      ]);
      expect(app.code['a'], 'const host = "new";\nget(host);\nget(host);');
      final backups = await app.backups.list();
      expect(backups.single.id, saved['backup_id']);
      expect(backups.single.automatic, true);
    },
  );

  test('backups are created, restored and deleted in one batch', () async {
    sources.addAll([RichSource('a'), RichSource('b')]);
    app.code['a'] = 'v1';
    app.code['b'] = 'b1';
    final created = await call('source_backup_update', {
      'create': [
        {'source_key': 'a', 'note': '修改前'},
        {'source_key': 'missing'},
      ],
    });
    expect(created['summary'], {
      'total': 2,
      'ok': 1,
      'skipped': 0,
      'failed': 1,
    });
    final id = created['results'][0]['backup_id'] as String;
    app.code['a'] = 'v2';

    final changed = await call('source_backup_update', {
      'restore': [id, id, 'nope'],
      'delete': ['nope'],
    });
    final rows = changed['results'] as List;
    expect(rows[0]['status'], 'restored');
    expect(rows[1]['reason'], 'SOURCE_ALREADY_RESTORED');
    expect(rows[2]['reason'], 'NOT_FOUND');
    expect(rows[3]['status'], 'skipped');
    expect(app.code['a'], 'v1');

    final listed = await call('source_backups', {'source_key': 'a'});
    expect(listed['total'], 2);
    expect(listed['items'][0]['backup_id'], rows[0]['previous_backup_id']);
    expect(listed['items'][1]['note'], '修改前');

    final deleted = await call('source_backup_update', {
      'delete': [id, rows[0]['previous_backup_id']],
    });
    expect(deleted['summary']['ok'], 2);
    expect(await app.backups.list(), isEmpty);
  });

  test('automatic and manual backups have separate limits', () async {
    for (var i = 0; i < 5; i++) {
      await app.backups.create('a', 'v$i', automatic: true, keep: 3);
    }
    await app.backups.create('a', 'manual');
    await app.backups.create('b', 'other', automatic: true, keep: 3);
    final all = await app.backups.list();
    expect(all.where((b) => b.sourceKey == 'a' && b.automatic).length, 3);
    // Pruning automatic copies never removes manual ones.
    expect(all.where((b) => b.sourceKey == 'a' && !b.automatic).length, 1);
    expect(all.where((b) => b.sourceKey == 'b').length, 1);

    sources.add(RichSource('a'));
    app.code['a'] = 'code';
    await store.saveSettings(
      const AgentSettings(manualBackupLimit: 2),
      store.secrets,
    );
    final created = await call('source_backup_update', {
      'create': [
        {'source_key': 'a'},
        {'source_key': 'a'},
      ],
    });
    expect(created['results'][0]['status'], 'created');
    expect(created['results'][1]['reason'], 'BACKUP_LIMIT');
    final after = await app.backups.list(sourceKey: 'a');
    expect(after.where((b) => b.automatic).length, 3);
    expect(after.where((b) => !b.automatic).length, 2);
  });

  test('source libraries are listed, added and removed in batches', () async {
    app.libraries.add(
      const AgentSourceLibrary(
        id: 'old',
        name: '旧仓库',
        url: 'https://a.example/index.json',
        enabled: true,
      ),
    );
    final listed = await call('source_library_list', {});
    expect(listed['items'].single, containsPair('name', '旧仓库'));
    final updated = await call('source_library_update', {
      'add': [
        {'url': 'https://b.example/index.json', 'name': '新仓库'},
        {'url': 'https://a.example/index.json/'},
        {'url': 'ftp://c.example/index.json'},
      ],
      'remove': ['old', 'missing'],
    });
    expect(updated['summary'], {
      'total': 5,
      'ok': 2,
      'skipped': 2,
      'failed': 1,
    });
    expect(updated['results'][1]['reason'], 'ALREADY_EXISTS');
    expect(updated['results'][2]['reason'], 'INVALID_URL');
    expect(app.libraries.map((l) => l.name), ['新仓库']);
    final empty = await tools.execute('source_library_update', {}, context);
    expect(empty['error']['code'], 'INVALID_ARGUMENT');
  });

  test('network favorites need login and reuse favorite ids', () async {
    final changes = <String>[];
    final source = RichSource(
      'net',
      isLogged: false,
      favoriteData: FavoriteData(
        key: 'net',
        title: '网络',
        multiFolder: true,
        loadComic: (page, [folder]) async => Res([
          Comic.fromJson({
            'title': '收藏',
            'cover': '',
            'id': 'a',
            'favoriteId': 'f-a',
          }, 'net'),
        ], subData: 1),
        loadNext: null,
        loadFolders: ([comic]) async =>
            Res({'1': '默认', '2': '稍后'}, subData: comic == null ? null : ['2']),
        addOrDelFavorite: (id, folder, adding, favId) async {
          changes.add('$id/$folder/$adding/$favId');
          return id == 'bad' ? const Res.error('拒绝') : const Res(true);
        },
      ),
    );
    sources.add(source);
    final denied = await tools.execute('net_fav_folders', {
      'source_key': 'net',
    }, context);
    expect(denied['error']['code'], 'NOT_LOGGED_IN');
    source.isLogged = true;
    final folders = await call('net_fav_folders', {
      'source_key': 'net',
      'comic_id': 'a',
    });
    expect(folders['folders'], [
      {'id': '1', 'name': '默认'},
      {'id': '2', 'name': '稍后'},
    ]);
    expect(folders['comic_folders'], ['2']);
    final required = await tools.execute('net_fav_list', {
      'source_key': 'net',
    }, context);
    expect(required['error']['code'], 'FOLDER_REQUIRED');
    final listed = await call('net_fav_list', {
      'source_key': 'net',
      'folder_id': '2',
    });
    expect(listed['max_page'], 1);
    // Saved conversations may still retry with the earlier name.
    final removed = await call('net_fav_remove', {
      'source_key': 'net',
      'folder': '2',
      'comic_ids': ['a', 'bad'],
    });
    expect(removed['summary'], {
      'total': 2,
      'ok': 1,
      'skipped': 0,
      'failed': 1,
    });
    expect(changes, ['a/2/false/f-a', 'bad/2/false/null']);
  });

  test(
    'source catalog installs only catalog entries and updates in batch',
    () async {
      sources.add(RichSource('old', version: '1.0.0'));
      app.catalog.addAll([
        const AgentCatalogSource(
          key: 'new',
          name: '新源',
          version: '2.0.0',
          description: '',
          url: 'https://example.invalid/new.js',
          libraryId: 'lib',
          libraryName: '仓库',
        ),
        const AgentCatalogSource(
          key: 'old',
          name: '旧源',
          version: '1.1.0',
          description: '',
          url: 'https://example.invalid/old.js',
          libraryId: 'lib',
          libraryName: '仓库',
        ),
      ]);
      final catalog = await call('source_catalog', {});
      expect(catalog['items'][1], containsPair('installed_version', '1.0.0'));
      final installed = await call('source_install', {
        'keys': ['new', 'old', 'unknown', 'new'],
      });
      expect(installed['summary'], {
        'total': 4,
        'ok': 1,
        'skipped': 2,
        'failed': 1,
      });
      expect(app.installed, ['new']);
      expect(sources.map((s) => s.key), ['old', 'new']);

      app.updatesAvailable['old'] = '1.1.0';
      final updated = await call('source_update', {});
      expect(updated['results'], [
        {
          'key': 'old',
          'name': '源old',
          'status': 'updated',
          'from': '1.0.0',
          'to': '1.1.0',
        },
      ]);
      final selected = await call('source_update', {
        'source_keys': ['new', 'gone'],
      });
      expect(selected['results'].map((r) => r['reason']), [
        'UP_TO_DATE',
        'SOURCE_NOT_FOUND',
      ]);
    },
  );

  test('pages open for the user without exposing page content', () async {
    detailSource('jm');
    await call('open_comic', {'source_key': 'jm', 'comic_id': '1'});
    final reader = await call('open_comic', {
      'source_key': 'jm',
      'comic_id': '1',
      'read': true,
      'chapter': 3,
    });
    expect(reader['title'], '详情1');
    final beyond = await tools.execute('open_comic', {
      'source_key': 'jm',
      'comic_id': '1',
      'read': true,
      'chapter': 99,
    }, context);
    expect(beyond['error']['code'], 'INVALID_CHAPTER');
    await call('open_page', {'page': 'history'});
    await call('open_page', {'page': 'search', 'keyword': '海贼'});
    expect(app.opened, [
      'details:jm:1',
      'reader:1:3:null',
      'history',
      'search:海贼:null',
    ]);
  });

  test('blocked words are updated in batches', () async {
    app.settings['blockedWords'] = ['旧词'];
    final updated = await call('blocked_words_update', {
      'add': ['新词', '旧词'],
      'remove': ['旧词', '无'],
    });
    expect(updated['summary'], {
      'total': 4,
      'ok': 2,
      'skipped': 2,
      'failed': 0,
    });
    expect(app.settings['blockedWords'], ['新词']);
    final comments = await call('blocked_words_update', {
      'scope': 'comment',
      'add': ['剧透'],
    });
    expect(comments['count'], 1);
    final listed = await call('blocked_words_list', {'scope': 'comment'});
    expect(listed['items'], [
      {'word': '剧透'},
    ]);
    expect(app.saves, 2);
  });

  test(
    'author blocks can be managed separately from general keywords',
    () async {
      app.settings['blockedWords'] = ['sun'];
      await call('blocked_words_update', {
        'scope': 'author',
        'add': ['sun', 'sun'],
      });
      expect(app.settings['blockedAuthors'], ['sun']);
      final listed = await call('blocked_words_list', {'scope': 'author'});
      expect(listed['items'], [
        {'word': 'sun'},
      ]);
      await call('blocked_words_update', {
        'scope': 'author',
        'remove': ['sun'],
      });
      expect(app.settings['blockedAuthors'], isEmpty);
      expect(app.settings['blockedWords'], ['sun']);
    },
  );

  test('reading statistics summarise days and comics', () async {
    sources.add(RichSource('jm'));
    app.statistics.addAll([
      for (final (day, id, seconds) in [
        ('2026-09-01', '1', 600),
        ('2026-09-02', '1', 300),
        ('2026-09-02', '2', 1200),
      ])
        ReadingStatistic(
          day: day,
          comicId: id,
          comicType: ComicType.fromKey('jm'),
          title: '统计$id',
          author: '',
          cover: '',
          durationSeconds: seconds,
          lastReadAt: DateTime(2026),
        ),
    ]);
    final stats = await call('reading_stats', {});
    expect(stats['total_seconds'], 2100);
    expect(stats['daily'], [
      {'day': '2026-09-01', 'seconds': 600},
      {'day': '2026-09-02', 'seconds': 1500},
    ]);
    expect(stats['top_comics'][0], containsPair('comic_id', '2'));
  });

  test('captions describe results for every result shape', () {
    String caption(String name, Object? data, {String state = 'done'}) =>
        agentToolCaption({
          'name': name,
          'state': state,
          'result': {'ok': true, 'data': data},
        });
    expect(
      caption('later_list', {'total': 45, 'page': 2, 'total_pages': 3}),
      '第 2/3 页 · 共 45 条',
    );
    expect(
      caption('search_source', {
        'style': 'page',
        'page': 1,
        'max_page': 9,
        'count': 20,
      }),
      '第 1/9 页 · 20 项',
    );
    expect(
      caption('search_source', {
        'style': 'cursor',
        'count': 20,
        'has_more': true,
        'from_cache': true,
      }),
      '20 项 · 还有更多 · 缓存',
    );
    expect(
      caption('search_all', {
        'summary': {'ok': 3, 'skipped': 0, 'failed': 1},
      }),
      '成功 3个源 · 失败 1',
    );
    expect(
      caption('fav_add', {
        'summary': {'ok': 2, 'skipped': 1, 'failed': 0},
      }),
      '成功 2 · 跳过 1',
    );
    expect(caption('open_page', {'opened': 'history'}), '已打开');
    expect(caption('showcase_comics', {'count': 3}), '已展示 3 本');
    expect(caption('fav_add', null, state: 'running'), '执行中');
  });
}
