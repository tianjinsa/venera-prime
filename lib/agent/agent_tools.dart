import 'dart:convert';
import 'dart:math' as math;

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'agent_models.dart';
import 'agent_store.dart';

class AgentToolContext {
  final String conversationId;
  final AgentRun run;
  const AgentToolContext(this.conversationId, this.run);
}

class _SearchRemainder {
  final String queryKey;
  final List<AgentComic> items;
  final AgentJson metadata;
  _SearchRemainder(this.queryKey, this.items, this.metadata);
}

class AgentTools {
  final AgentStore store;
  final LocalFavoritesManager favorites;
  final ReadLaterManager later;
  final Future<void> Function() initializeSources;
  final List<ComicSource> Function() sources;
  final Duration sourceTimeout;
  final _cursors = <String, Set<String>>{};
  final _remainders = <String, _SearchRemainder>{};

  AgentTools(
    this.store, {
    LocalFavoritesManager? favorites,
    ReadLaterManager? later,
    Future<void> Function()? initializeSources,
    List<ComicSource> Function()? sources,
    this.sourceTimeout = const Duration(seconds: 30),
  }) : favorites = favorites ?? LocalFavoritesManager(),
       later = later ?? ReadLaterManager(),
       initializeSources =
           initializeSources ?? (() => ComicSourceManager().init()),
       sources = sources ?? ComicSource.all;

  static const writeTools = {
    'fav_add',
    'fav_remove',
    'fav_move',
    'fav_create_folder',
    'later_add',
    'later_remove',
  };
  static const destructiveTools = {'fav_remove', 'fav_move', 'later_remove'};
  static const _string = {'type': 'string'};
  static const _integer = {'type': 'integer', 'minimum': 1};
  static final _comics = {
    'type': 'array',
    'minItems': 1,
    'maxItems': 50,
    'items': {
      'anyOf': [
        {'type': 'string', 'description': 'source_key:comic_id'},
        {
          'type': 'object',
          'properties': {'source_key': _string, 'comic_id': _string},
          'required': ['source_key', 'comic_id'],
        },
      ],
    },
    'description': '使用此前工具返回的真实漫画引用，元数据以本机会话记录为准',
  };
  static AgentJson _schema(
    String name,
    String description,
    AgentJson properties, [
    List<String> required = const [],
  ]) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
        'additionalProperties': false,
      },
    },
  };
  static final schemas = <AgentJson>[
    _schema('list_sources', '查看已安装源及其能力；先确认源再操作', {}),
    _schema(
      'list_search_options',
      '查询单源的搜索选项与默认值',
      {'source_key': _string},
      ['source_key'],
    ),
    _schema(
      'search_source',
      '在一个源搜索。分页源用 page，游标源原样回传 next_cursor；continuation 读取本页剩余条目',
      {
        'source_key': _string,
        'keyword': _string,
        'page': _integer,
        'cursor': _string,
        'continuation': _string,
        'options': {'type': 'array', 'items': _string},
      },
      ['source_key', 'keyword'],
    ),
    _schema(
      'comic_open_by_id',
      '用户给出的原始 id 直达；需匹配源 id_matcher',
      {
        'source_key': _string,
        'comic_id': _string,
        'include_status': {'type': 'boolean'},
      },
      ['source_key', 'comic_id'],
    ),
    _schema(
      'comic_resolve',
      '将用户给出的名称、源 id 或站内 URL 解析成真实候选；不明确的源应询问用户',
      {'query': _string, 'source_key': _string, 'limit': _integer},
      ['query'],
    ),
    _schema(
      'comic_get',
      '获取已见漫画的详情，不包含漫画内页或逐页缩略图',
      {'source_key': _string, 'comic_id': _string},
      ['source_key', 'comic_id'],
    ),
    _schema(
      'showcase_comics',
      '把真实漫画放入用户的独立展示栏，最多30本；涉及具体漫画时必须调用',
      {
        'comics': {..._comics, 'maxItems': 30},
        'title': _string,
        'note': _string,
        'mode': {
          'type': 'string',
          'enum': ['append', 'replace'],
        },
      },
      ['comics'],
    ),
    _schema('fav_list_folders', '列出本地收藏夹及数量', {}),
    _schema(
      'fav_list',
      '分页查看本地收藏夹',
      {'folder': _string, 'page': _integer, 'page_size': _integer},
      ['folder'],
    ),
    _schema(
      'fav_search',
      '按标题、作者和标签搜索本地收藏；省略 folder 搜全部文件夹',
      {
        'keyword': _string,
        'folder': _string,
        'page': _integer,
        'page_size': _integer,
      },
      ['keyword'],
    ),
    _schema(
      'fav_check',
      '批量查在哪些本地收藏夹；未收藏 folder=-1',
      {'comics': _comics},
      ['comics'],
    ),
    _schema(
      'fav_add',
      '批量加入指定的现有本地收藏夹；已存在则跳过',
      {'folder': _string, 'comics': _comics},
      ['folder', 'comics'],
    ),
    _schema(
      'fav_remove',
      '批量取消本地收藏，省略 folder 时从所有收藏夹移除；可撤销',
      {'folder': _string, 'comics': _comics},
      ['comics'],
    ),
    _schema(
      'fav_move',
      '批量移动本地收藏；目标已有则跳过并保留源',
      {'from_folder': _string, 'to_folder': _string, 'comics': _comics},
      ['from_folder', 'to_folder', 'comics'],
    ),
    _schema(
      'fav_create_folder',
      '创建本地收藏夹；不允许删除文件夹',
      {'name': _string},
      ['name'],
    ),
    _schema('later_list', '分页查看稍后再看', {
      'keyword': _string,
      'page': _integer,
      'page_size': _integer,
    }),
    _schema(
      'later_check',
      '批量判定是否在稍后再看，marker=-1/1',
      {'comics': _comics},
      ['comics'],
    ),
    _schema('later_add', '批量加入稍后再看；已存在则跳过', {'comics': _comics}, ['comics']),
    _schema('later_remove', '批量从稍后再看移除，可撤销', {'comics': _comics}, ['comics']),
  ];

  static String _text(AgentJson args, String key, {String? fallback}) {
    final value = args[key] ?? fallback;
    if (value is! String || value.trim().isEmpty || value.length > 4096) {
      throw AgentException('INVALID_ARGUMENT', '$key 需要非空文本，最长4096字');
    }
    return value;
  }

  static int _number(AgentJson args, String key, int fallback, int maximum) {
    final value = args[key] ?? fallback;
    if (value is! int || value < 1 || value > maximum) {
      throw AgentException('INVALID_ARGUMENT', '$key 应为1到$maximum的整数');
    }
    return value;
  }

  static (String, String) _ref(Object? item) {
    String? source;
    String? id;
    if (item is String) {
      final colon = item.indexOf(':');
      if (colon > 0) {
        source = item.substring(0, colon);
        id = item.substring(colon + 1);
      }
    } else if (item is Map) {
      if (item['source_key'] is String) source = item['source_key'];
      if (item['comic_id'] is String) id = item['comic_id'];
    }
    if (source == null ||
        id == null ||
        source.trim().isEmpty ||
        id.trim().isEmpty ||
        source.length > 128 ||
        id.length > 4096) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        '漫画引用需要 source_key 和 comic_id',
      );
    }
    return (source, id);
  }

  static List<(String, String)> _refs(AgentJson args, {int maximum = 50}) {
    final list = args['comics'];
    if (list is! List || list.isEmpty) {
      throw const AgentException('INVALID_ARGUMENT', 'comics 需要非空数组');
    }
    if (list.length > maximum) {
      throw AgentException('BATCH_TOO_LARGE', '一次最多处理$maximum本，请分批');
    }
    return list.map(_ref).toList();
  }

  static AgentJson _identity((String, String) ref) => {
    'source_key': ref.$1,
    'comic_id': ref.$2,
  };
  static ComicType _type(String source) {
    if (source.startsWith('Unknown:')) {
      final value = int.tryParse(source.substring(8));
      if (value != null) return ComicType(value);
    }
    return ComicType.fromKey(source);
  }

  static AgentComic fromComic(Comic comic) => AgentComic(
    sourceKey: comic.sourceKey,
    comicId: comic.id,
    title: comic.title,
    subtitle: comic.subtitle ?? '',
    cover: comic.cover,
    tags: comic.tags ?? [],
    description: comic.description,
  );
  static Comic toComic(AgentComic comic) => Comic(
    comic.title,
    comic.cover,
    comic.comicId,
    comic.subtitle,
    comic.tags,
    comic.description,
    comic.sourceKey,
    null,
    null,
  );
  static FavoriteItem _favorite(AgentComic comic, {String? time}) =>
      FavoriteItem(
        id: comic.comicId,
        name: comic.title,
        coverPath: comic.cover,
        author: comic.subtitle,
        type: _type(comic.sourceKey),
        tags: comic.tags,
        favoriteTime: time == null ? null : DateTime.tryParse(time),
      );

  Future<AgentJson> execute(
    String name,
    AgentJson args,
    AgentToolContext context,
  ) async {
    try {
      context.run.check();
      final specs = schemas.where((s) => s['function']['name'] == name);
      if (specs.isEmpty) {
        throw const AgentException('UNKNOWN_TOOL', '工具不在应用允许的清单中');
      }
      final params = specs.first['function']['parameters'] as Map;
      final properties = params['properties'] as Map;
      if (args.keys.any((k) => !properties.containsKey(k)) ||
          (params['required'] as List).any((k) => !args.containsKey(k))) {
        throw const AgentException('INVALID_ARGUMENT', '工具参数缺失或包含未知字段');
      }
      // Validate all array references before entering any write path.
      if (properties.containsKey('comics')) {
        _refs(args, maximum: name == 'showcase_comics' ? 30 : 50);
      }
      if (name.startsWith('fav_') ||
          name.startsWith('later_') ||
          name == 'comic_open_by_id') {
        await context.run.wait(favorites.init());
        await context.run.wait(later.init());
      }
      final data = await _dispatch(name, args, context);
      context.run.check();
      return {'ok': true, 'data': data};
    } on AgentException catch (e) {
      return e.toJson();
    } on FormatException {
      return const AgentException('INVALID_ARGUMENT', '参数格式无效').toJson();
    } catch (_) {
      return const AgentException('TOOL_FAILED', '操作未完成，请检查源状态或参数后重试').toJson();
    }
  }

  Future<Object?> _dispatch(
    String name,
    AgentJson a,
    AgentToolContext c,
  ) async {
    switch (name) {
      case 'list_sources':
        await c.run.wait(initializeSources());
        return sources().map(_capability).toList();
      case 'list_search_options':
        final source = await _source(_text(a, 'source_key'), c);
        return (source.searchPageData?.searchOptions ?? [])
            .map(
              (option) => {
                'label': option.label,
                'type': option.type,
                'options': option.options,
                'default': option.defaultValue,
              },
            )
            .toList();
      case 'search_source':
        return _search(a, c);
      case 'comic_resolve':
        return _resolve(a, c);
      case 'comic_open_by_id':
      case 'comic_get':
        final source = await _source(_text(a, 'source_key'), c);
        final id = _text(a, 'comic_id');
        final cached = store.seen(c.conversationId, source.key, id);
        if (cached == null && !_directUserId(source, id, c)) {
          throw const AgentException(
            'ID_NOT_DIRECT',
            '请先搜索取得真实漫画引用，或提供源支持的原始id',
          );
        }
        if (a.containsKey('include_status') && a['include_status'] is! bool) {
          throw const AgentException(
            'INVALID_ARGUMENT',
            'include_status 需要布尔值',
          );
        }
        final details = await _details(source, cached?.comicId ?? id, c);
        final brief = _rememberDetails(details, c, alias: id);
        return {
          ..._detailJson(details, brief),
          if (name == 'comic_open_by_id' && a['include_status'] != false)
            ..._status((brief.sourceKey, brief.comicId)),
        };
      case 'showcase_comics':
        return _showcase(a, c);
      case 'fav_list_folders':
        return favorites.folderNames
            .map((f) => {'name': f, 'count': favorites.count(f)})
            .toList();
      case 'fav_list':
      case 'fav_search':
        return _favoriteList(name, a, c);
      case 'later_list':
        final keyword = a.containsKey('keyword') ? _text(a, 'keyword') : '';
        return _localPage(
          later
              .getAll(keyword: keyword)
              .map((comic) => fromComic(comic).toJson())
              .toList(),
          a,
          c,
        );
      case 'fav_check':
      case 'later_check':
        return {
          'results': _refs(a)
              .map((ref) => _canonicalRef(ref, c))
              .map(
                (ref) => {
                  ..._identity(ref),
                  if (name == 'fav_check')
                    ..._favoriteStatus(ref)
                  else
                    ..._laterStatus(ref),
                },
              )
              .toList(),
        };
      case 'fav_create_folder':
        final folder = _text(a, 'name').trim();
        _validateFolderName(folder);
        if (favorites.existsFolder(folder)) {
          throw const AgentException('FOLDER_EXISTS', '收藏夹已经存在');
        }
        c.run.check();
        return {'name': favorites.createFolder(folder)};
      default:
        return _write(name, a, c);
    }
  }

  AgentJson _capability(ComicSource source) => {
    'key': source.key,
    'name': source.name,
    'version': source.version,
    'logged_in': source.isLogged,
    'search': source.searchPageData?.loadPage != null
        ? 'page'
        : source.searchPageData?.loadNext != null
        ? 'cursor'
        : null,
    'id_matcher': source.idMatcher?.pattern,
    'link_domains': source.linkHandler?.domains ?? [],
  };

  Future<ComicSource> _source(String key, AgentToolContext c) async {
    await c.run.wait(initializeSources());
    for (final source in sources()) {
      if (source.key == key) return source;
    }
    throw AgentException('SOURCE_NOT_FOUND', '漫画源 $key 未安装，请先查看源列表');
  }

  bool _userProvided(String input, AgentToolContext c) {
    final pattern = RegExp(
      '(?<![a-zA-Z0-9])${RegExp.escape(input)}(?![a-zA-Z0-9])',
    );
    return store
        .messages(c.conversationId)
        .any(
          (message) => message.role == 'user' && pattern.hasMatch(message.text),
        );
  }

  bool _directUserId(ComicSource source, String id, AgentToolContext c) =>
      source.idMatcher?.hasMatch(id) == true && _userProvided(id, c);

  Future<ComicDetails> _details(
    ComicSource source,
    String id,
    AgentToolContext c,
  ) async {
    c.run.check();
    final loader = source.loadComicInfo;
    if (loader == null) {
      throw const AgentException('NOT_FOUND', '该源不提供漫画详情');
    }
    final result = await c.run.wait(loader(id), timeout: sourceTimeout);
    if (result.error) {
      throw AgentException(
        'NOT_FOUND',
        '源未返回漫画详情：${_short(result.errorMessage ?? '', 400)}',
      );
    }
    return result.data;
  }

  AgentComic _rememberDetails(
    ComicDetails details,
    AgentToolContext c, {
    String? alias,
  }) {
    c.run.check();
    final comic = AgentComic(
      sourceKey: details.sourceKey,
      comicId: details.comicId,
      title: details.title,
      subtitle: details.subTitle ?? details.findAuthor() ?? '',
      cover: details.cover,
      description: details.description ?? '',
      tags: details.plainTags,
    );
    store.remember(c.conversationId, comic);
    if (alias != null && alias != comic.comicId) {
      store.remember(c.conversationId, comic, alias: alias);
    }
    for (final item in details.recommend ?? <Comic>[]) {
      store.remember(c.conversationId, fromComic(item));
    }
    return comic;
  }

  static String _short(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}…' : text;
  static AgentJson _briefJson(AgentComic comic) => {
    ...comic.ref,
    'title': _short(comic.title, 300),
    'subtitle': _short(comic.subtitle, 200),
    'description': _short(comic.description, 400),
    'tags': comic.tags.take(20).map((t) => _short(t, 100)).toList(),
  };
  AgentJson _detailJson(ComicDetails d, AgentComic comic) => {
    ..._briefJson(comic),
    'description': _short(d.description ?? '', 1600),
    'author': d.findAuthor(),
    'uploader': d.uploader,
    'upload_time': d.uploadTime,
    'update_time': d.updateTime,
    'likes_count': d.likesCount,
    'comment_count': d.commentCount,
    'stars': d.stars,
    'url': d.url,
    'max_page': d.maxPage,
    'chapters': {
      'count': d.chapters?.length ?? 0,
      'groups': d.chapters?.groups.take(20).toList() ?? [],
      'items':
          d.chapters?.allChapters.entries
              .take(30)
              .map((e) => {'id': e.key, 'name': e.value})
              .toList() ??
          [],
    },
    'recommend': (d.recommend ?? <Comic>[])
        .take(10)
        .map((item) => _briefJson(fromComic(item)))
        .toList(),
  };

  AgentJson _favoriteStatus((String, String) ref) {
    final folders = favorites.find(ref.$2, _type(ref.$1));
    return {
      'folders': folders,
      'in_favorites': folders.isNotEmpty,
      'folder': folders.isEmpty
          ? -1
          : folders.length == 1
          ? folders.first
          : null,
    };
  }

  AgentJson _laterStatus((String, String) ref) {
    final exists = later.contains(ref.$2, _type(ref.$1));
    return {'in_read_later': exists, 'marker': exists ? 1 : -1};
  }

  AgentJson _status((String, String) ref) => {
    ..._favoriteStatus(ref),
    ..._laterStatus(ref),
  };

  (String, String) _canonicalRef((String, String) ref, AgentToolContext c) {
    final comic = store.seen(c.conversationId, ref.$1, ref.$2);
    return comic == null ? ref : (comic.sourceKey, comic.comicId);
  }

  Future<AgentJson> _search(
    AgentJson a,
    AgentToolContext c, {
    int pageSize = 20,
  }) async {
    final source = await _source(_text(a, 'source_key'), c);
    final keyword = _text(a, 'keyword');
    final search = source.searchPageData;
    if (search == null ||
        (search.loadPage == null && search.loadNext == null)) {
      throw const AgentException('NO_SEARCH_SUPPORT', '该源不支持搜索');
    }
    final definitions = search.searchOptions ?? [];
    final rawOptions = a['options'];
    if (rawOptions != null &&
        (rawOptions is! List || rawOptions.any((v) => v is! String))) {
      throw const AgentException('INVALID_ARGUMENT', 'options 需要字符串数组');
    }
    final options = rawOptions == null
        ? definitions.map((d) => d.defaultValue).toList()
        : List<String>.from(rawOptions as List);
    if (options.length != definitions.length) {
      throw const AgentException(
        'SEARCH_OPTION_MISMATCH',
        '请按 list_search_options 返回的定义提供选项',
      );
    }
    final key = jsonEncode([c.conversationId, source.key, keyword, options]);
    final continuation = a['continuation'];
    if (continuation != null) {
      final rest = _remainders[continuation];
      if (rest == null || rest.queryKey != key) {
        throw const AgentException('INVALID_CURSOR', '本页续读标记已失效，请重新搜索');
      }
      _remainders.remove(continuation);
      return _searchSlice(rest, size: pageSize);
    }
    final page = _number(a, 'page', 1, 10000);
    final cursor = a['cursor'];
    if (cursor != null && cursor is! String) {
      throw const AgentException('INVALID_CURSOR', 'cursor 必须是原样返回的字符串');
    }
    final isCursor = search.loadPage == null;
    if (isCursor && page != 1 || !isCursor && cursor != null) {
      throw const AgentException('INVALID_ARGUMENT', '该源的页码/游标参数不匹配');
    }
    if (isCursor &&
        cursor != null &&
        !(_cursors[key]?.contains(cursor) ?? false)) {
      throw const AgentException('INVALID_CURSOR', '请使用同一查询返回的 next_cursor');
    }
    c.run.check();
    final result = await c.run.wait(
      isCursor
          ? search.loadNext!(keyword, cursor as String?, options)
          : search.loadPage!(keyword, page, options),
      timeout: sourceTimeout,
    );
    if (result.error) {
      throw AgentException(
        'SEARCH_FAILED',
        '搜索失败：${_short(result.errorMessage ?? '', 400)}',
      );
    }
    final items = result.data.map(fromComic).toList();
    for (final item in items) {
      store.remember(c.conversationId, item);
    }
    final maxPage = !isCursor && result.subData is int
        ? result.subData as int
        : null;
    final next =
        isCursor &&
            result.subData is String &&
            result.subData != cursor &&
            (result.subData as String).isNotEmpty
        ? result.subData as String
        : null;
    if (next != null) {
      if (_cursors.length >= 64) _cursors.remove(_cursors.keys.first);
      (_cursors[key] ??= {}).add(next);
    }
    return _searchSlice(
      _SearchRemainder(key, items, {
        'style': isCursor ? 'cursor' : 'page',
        'page': isCursor ? null : page,
        'max_page': maxPage,
        'has_more': isCursor
            ? next != null
            : maxPage != null
            ? page < maxPage
            : items.isNotEmpty,
        'next_cursor': next,
      }),
      size: pageSize,
    );
  }

  AgentJson _searchSlice(_SearchRemainder page, {int size = 20}) {
    final visible = page.items.take(size).toList();
    final rest = page.items.skip(size).toList();
    String? continuation;
    if (rest.isNotEmpty) {
      continuation = agentId();
      if (_remainders.length >= 32) _remainders.remove(_remainders.keys.first);
      _remainders[continuation] = _SearchRemainder(
        page.queryKey,
        rest,
        page.metadata,
      );
    }
    return {
      ...page.metadata,
      'items': visible.map(_briefJson).toList(),
      'continuation': continuation,
      if (continuation != null) 'next_cursor': null,
      'has_more': continuation != null || page.metadata['has_more'] == true,
      'exhausted': continuation == null && page.metadata['has_more'] != true,
    };
  }

  Future<AgentJson> _resolve(AgentJson a, AgentToolContext c) async {
    final query = _text(a, 'query');
    final limit = _number(a, 'limit', 5, 20);
    await c.run.wait(initializeSources());
    final available = a.containsKey('source_key')
        ? [await _source(_text(a, 'source_key'), c)]
        : sources();
    if (available.isEmpty) {
      throw const AgentException('SOURCE_NOT_FOUND', '尚未安装漫画源，请在应用中配置漫画源');
    }
    final uri = Uri.tryParse(query);
    final linkSources = uri != null && ['http', 'https'].contains(uri.scheme)
        ? available
              .where((s) => s.linkHandler?.domains.contains(uri.host) == true)
              .toList()
        : <ComicSource>[];
    if (uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        linkSources.isEmpty) {
      throw const AgentException(
        'NO_LINK_SUPPORT',
        '所选漫画源未声明这个链接域名，请提供漫画名称或使用对应漫画源',
      );
    }
    final idSources = available
        .where((s) => s.idMatcher?.hasMatch(query) == true)
        .toList();
    final direct = linkSources.isNotEmpty ? linkSources : idSources;
    if (direct.length > 1 || direct.isEmpty && available.length > 1) {
      return {
        'resolved_by': 'ambiguous',
        'candidates': <AgentJson>[],
        'matched_sources': (direct.isEmpty ? available : direct)
            .map(_capability)
            .toList(),
        'message': '请让用户指定漫画源后再解析',
      };
    }
    if (direct.isNotEmpty) {
      final source = direct.single;
      if (!_userProvided(query, c)) {
        throw const AgentException('HALLUCINATED_REF', '直达输入必须来自用户；请先搜索');
      }
      final id = linkSources.isNotEmpty
          ? source.linkHandler!.linkToId(query)
          : query;
      if (id == null || id.isEmpty) {
        throw const AgentException('NOT_FOUND', '漫画源未能解析这个链接');
      }
      final details = await _details(source, id, c);
      final comic = _rememberDetails(details, c, alias: id);
      return {
        'resolved_by': linkSources.isNotEmpty ? 'url_extract' : 'id_match',
        'candidates': [_briefJson(comic)],
      };
    }
    final result = await _search(
      {'source_key': available.single.key, 'keyword': query},
      c,
      pageSize: limit,
    );
    final candidates = result.remove('items') as List;
    return {...result, 'resolved_by': 'search', 'candidates': candidates};
  }

  AgentJson _showcase(AgentJson a, AgentToolContext c) {
    final mode = a['mode'] ?? 'append';
    if (!['append', 'replace'].contains(mode)) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'mode 只能为 append 或 replace',
      );
    }
    final title = a.containsKey('title') ? _text(a, 'title') : '为你找到的漫画';
    final note = a.containsKey('note') ? _text(a, 'note') : '';
    final comics = <AgentComic>[];
    final skipped = <AgentJson>[];
    final identities = <String>{};
    for (final ref in _refs(a, maximum: 30)) {
      final comic = store.seen(c.conversationId, ref.$1, ref.$2);
      if (comic == null) {
        skipped.add({..._identity(ref), 'reason': 'HALLUCINATED_REF'});
      } else if (!identities.add(comic.identity)) {
        skipped.add({..._identity(ref), 'reason': 'DUPLICATE_IN_BATCH'});
      } else {
        comics.add(comic);
      }
    }
    c.run.check();
    if (comics.isEmpty) {
      throw const AgentException('HALLUCINATED_REF', '没有可展示的真实漫画，请先搜索或解析');
    }
    final id = store.addShowcase(
      c.conversationId,
      comics,
      title: title,
      note: note,
      replace: mode == 'replace',
    );
    return {
      'set_id': id,
      'title': title,
      'count': comics.length,
      'shown': comics.map((comic) => comic.ref).toList(),
      'skipped': skipped,
    };
  }

  void _validateFolderName(String folder) {
    if (folder.trim().isEmpty ||
        folder.length > 64 ||
        folder.contains('"') ||
        folder.codeUnits.any((v) => v < 32 || v == 127) ||
        ['folder_order', 'folder_sync'].contains(folder)) {
      throw const AgentException('INVALID_ARGUMENT', '收藏夹名称无效');
    }
  }

  String _folder(AgentJson a, String key) {
    final folder = _text(a, key);
    _validateFolderName(folder);
    if (!favorites.existsFolder(folder)) {
      throw AgentException('FOLDER_NOT_FOUND', '收藏夹 $folder 不存在');
    }
    return folder;
  }

  AgentJson _favoriteList(String name, AgentJson a, AgentToolContext c) {
    final folders = name == 'fav_list' || a.containsKey('folder')
        ? [_folder(a, 'folder')]
        : favorites.folderNames;
    final keyword = name == 'fav_search' ? _text(a, 'keyword') : null;
    final items = <AgentJson>[];
    for (final folder in folders) {
      final values = keyword == null
          ? favorites.getFolderComics(folder)
          : favorites.searchInFolder(folder, keyword);
      for (final item in values) {
        final comic = fromComic(item);
        items.add({
          ...comic.toJson(),
          'folder': folder,
          'favorited_at': item.time,
        });
      }
    }
    return _localPage(items, a, c);
  }

  AgentJson _localPage(List<AgentJson> items, AgentJson a, AgentToolContext c) {
    final page = _number(a, 'page', 1, 1000000);
    final size = _number(a, 'page_size', 20, 50);
    final visible = items.skip((page - 1) * size).take(size).toList();
    for (final item in visible) {
      store.remember(c.conversationId, AgentComic.fromJson(item));
    }
    return {
      'items': visible
          .map(
            (item) => {
              ..._briefJson(AgentComic.fromJson(item)),
              if (item['folder'] != null) 'folder': item['folder'],
              if (item['favorited_at'] != null)
                'favorited_at': item['favorited_at'],
            },
          )
          .toList(),
      'total': items.length,
      'page': page,
      'has_more': page * size < items.length,
    };
  }

  Future<AgentComic> _metadata((String, String) ref, AgentToolContext c) async {
    final cached = store.seen(c.conversationId, ref.$1, ref.$2);
    if (cached != null) return cached;
    final type = _type(ref.$1);
    final folders = favorites.find(ref.$2, type);
    if (folders.isNotEmpty) {
      final comic = fromComic(favorites.getComic(folders.first, ref.$2, type));
      store.remember(c.conversationId, comic);
      return comic;
    }
    for (final comic in later.getAll()) {
      if (comic.id == ref.$2 && comic.type == type) {
        final value = fromComic(comic);
        store.remember(c.conversationId, value);
        return value;
      }
    }
    final source = await _source(ref.$1, c);
    if (!_directUserId(source, ref.$2, c)) {
      throw const AgentException('HALLUCINATED_REF', '漫画未经搜索或用户输入确认，请先解析');
    }
    return _rememberDetails(
      await _details(source, ref.$2, c),
      c,
      alias: ref.$2,
    );
  }

  Future<AgentJson> _write(String name, AgentJson a, AgentToolContext c) async {
    final refs = _refs(a).map((ref) => _canonicalRef(ref, c)).toList();
    String? folder;
    String? from;
    String? to;
    if (name == 'fav_add' || name == 'fav_remove' && a.containsKey('folder')) {
      folder = _folder(a, 'folder');
    }
    if (name == 'fav_move') {
      from = _folder(a, 'from_folder');
      to = _folder(a, 'to_folder');
    }
    final results = List<AgentJson?>.filled(refs.length, null);
    final prepared = <int, AgentComic>{};
    final unique = <String>{};
    // Only metadata is asynchronous. No writes until every await has finished.
    for (var offset = 0; offset < refs.length; offset += 4) {
      final jobs = <Future<void>>[];
      for (var i = offset; i < math.min(offset + 4, refs.length); i++) {
        final ref = refs[i];
        if (!unique.add(jsonEncode([ref.$1, ref.$2]))) {
          results[i] = {
            ..._identity(ref),
            'status': 'skipped',
            'reason': 'DUPLICATE_IN_BATCH',
          };
          continue;
        }
        if (name == 'fav_add' || name == 'later_add') {
          final index = i;
          jobs.add(() async {
            try {
              prepared[index] = await _metadata(ref, c);
            } on AgentException catch (e) {
              results[index] = {
                ..._identity(ref),
                'status': 'failed',
                'reason': e.code,
              };
            } catch (_) {
              results[index] = {
                ..._identity(ref),
                'status': 'failed',
                'reason': 'NOT_FOUND',
              };
            }
          }());
        }
      }
      await Future.wait(jobs);
      c.run.check();
    }
    final undo = <AgentJson>[];
    final undoId = agentId();
    final written = <String>{};
    favorites.batchNotifications(
      () => later.batchNotifications(() {
        for (var i = 0; i < refs.length; i++) {
          if (results[i] != null) continue;
          c.run.check();
          final resolved = prepared[i];
          final ref = resolved == null
              ? refs[i]
              : (resolved.sourceKey, resolved.comicId);
          final row = <String, dynamic>{..._identity(ref)};
          results[i] = row;
          if (!written.add(jsonEncode([ref.$1, ref.$2]))) {
            row.addAll({'status': 'skipped', 'reason': 'DUPLICATE_IN_BATCH'});
            continue;
          }
          try {
            final type = _type(ref.$1);
            switch (name) {
              case 'fav_add':
                _folder({'folder': folder}, 'folder');
                final added = favorites.addComic(folder!, _favorite(resolved!));
                row.addAll({
                  'status': added ? 'added' : 'skipped',
                  'folder': folder,
                  if (!added) 'reason': 'ALREADY_EXISTS',
                });
              case 'later_add':
                final added = later.add(toComic(resolved!));
                row.addAll({
                  'status': added ? 'added' : 'skipped',
                  if (!added) 'reason': 'ALREADY_EXISTS',
                });
              case 'fav_remove':
                final targets = favorites
                    .find(ref.$2, type)
                    .where((f) => folder == null || f == folder)
                    .toList();
                if (targets.isEmpty) {
                  row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
                  break;
                }
                var removed = 0;
                for (final target in targets) {
                  final item = favorites.getComic(target, ref.$2, type);
                  favorites.deleteComicWithId(target, ref.$2, type);
                  removed++;
                  undo.add({
                    'kind': 'favorite',
                    'folder': target,
                    'time': item.time,
                    'comic': fromComic(item).toJson(),
                  });
                  store.saveUndo(undoId, c.conversationId, undo);
                }
                row.addAll({'status': 'removed', 'removed_folders': removed});
              case 'later_remove':
                final items = later
                    .getAll()
                    .where((item) => item.id == ref.$2 && item.type == type)
                    .toList();
                if (items.isEmpty) {
                  row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
                  break;
                }
                if (later.remove(ref.$2, type)) {
                  undo.add({
                    'kind': 'later',
                    'comic': fromComic(items.first).toJson(),
                  });
                  store.saveUndo(undoId, c.conversationId, undo);
                  row['status'] = 'removed';
                } else {
                  row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
                }
              case 'fav_move':
                if (from == to || favorites.comicExists(to!, ref.$2, type)) {
                  row.addAll({'status': 'skipped', 'reason': 'ALREADY_EXISTS'});
                  break;
                }
                if (!favorites.comicExists(from!, ref.$2, type)) {
                  row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
                  break;
                }
                final item = favorites.getComic(from, ref.$2, type);
                if (favorites.addComic(to, item)) {
                  favorites.deleteComicWithId(from, ref.$2, type);
                  row.addAll({'status': 'moved', 'folder': to});
                } else {
                  row.addAll({'status': 'skipped', 'reason': 'ALREADY_EXISTS'});
                }
              default:
                throw const AgentException('UNKNOWN_TOOL', '未知写入工具');
            }
          } on AgentException catch (e) {
            row.addAll({'status': 'failed', 'reason': e.code});
          } catch (_) {
            row.addAll({'status': 'failed', 'reason': 'WRITE_FAILED'});
          }
        }
      }),
    );
    final values = results.whereType<AgentJson>().toList();
    return {
      'summary': {
        'total': refs.length,
        'ok': values
            .where((v) => ['added', 'removed', 'moved'].contains(v['status']))
            .length,
        'skipped': values.where((v) => v['status'] == 'skipped').length,
        'failed': values.where((v) => v['status'] == 'failed').length,
      },
      'results': values,
      if (undo.isNotEmpty) 'undo_id': undoId,
    };
  }

  AgentJson undo(String id, AgentToolContext c) {
    c.run.check();
    final entries = store.undoEntries(id, c.conversationId);
    var restored = 0;
    var skipped = 0;
    final remaining = <AgentJson>[];
    favorites.batchNotifications(
      () => later.batchNotifications(() {
        for (final entry in entries) {
          try {
            final comic = AgentComic.fromJson(agentObject(entry['comic']));
            final added = entry['kind'] == 'favorite'
                ? favorites.addComic(
                    _folder(entry, 'folder'),
                    _favorite(comic, time: entry['time'] as String?),
                  )
                : later.add(toComic(comic));
            if (added) {
              restored++;
            } else {
              skipped++;
            }
          } catch (_) {
            remaining.add(entry);
          }
        }
      }),
    );
    if (remaining.isEmpty) {
      store.deleteUndo(id);
    } else {
      store.saveUndo(id, c.conversationId, remaining);
    }
    return {
      'restored': restored,
      'skipped': skipped,
      'failed': remaining.length,
    };
  }
}
