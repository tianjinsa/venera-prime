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
    'description':
        '提供 source_key 和 comic_id，支持文本或图片识别出的ID。工具自行读取本地资料或请求源详情，无需先搜索、解析或检查存在性；逐项返回失败原因',
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
    _schema('list_sources', '查看已安装源及其能力；源不明确时使用', {}),
    _schema(
      'list_search_options',
      '查询单源的搜索选项与默认值',
      {'source_key': _string},
      ['source_key'],
    ),
    _schema(
      'search_source',
      '直接搜索单个源，无需先查询源或选项；省略 options 使用默认值。分页源用 page，游标源传 cursor；continuation 读取本页缓存余量',
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
      '按源和原始 comic_id 直接获取详情及状态，无需先搜索或解析',
      {
        'source_key': _string,
        'comic_id': _string,
        'include_status': {'type': 'boolean'},
      },
      ['source_key', 'comic_id'],
    ),
    _schema(
      'comic_resolve',
      '将名称、源 id 或站内 URL 解析成候选，可使用图片识别出的内容；不明确的源应询问用户',
      {'query': _string, 'source_key': _string, 'limit': _integer},
      ['query'],
    ),
    _schema(
      'comic_get',
      '按 source_key 和 comic_id 直接获取详情，无需先搜索或解析；不包含漫画内页或逐页缩略图',
      {'source_key': _string, 'comic_id': _string},
      ['source_key', 'comic_id'],
    ),
    _schema(
      'showcase_comics',
      '把漫画放入独立展示栏，最多30本；自动取得必要元数据，无需先搜索或查询详情，逐项返回无法展示的原因',
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
      '直接批量加入指定的本地收藏夹；内部自动查重并取得必要元数据，无需先查详情或fav_check；返回成功、已存在、不存在的数量和列表，并自动在收藏展示分组中显示',
      {'folder': _string, 'comics': _comics},
      ['folder', 'comics'],
    ),
    _schema(
      'fav_remove',
      '直接批量取消本地收藏，无需先查询；内部判断是否存在，返回不存在数量和列表。省略folder则从所有收藏夹移除；可撤销',
      {'folder': _string, 'comics': _comics},
      ['comics'],
    ),
    _schema(
      'fav_move',
      '直接批量移动本地收藏，无需先列出或检查漫画；目标已有则跳过并保留源，未在原收藏夹的条目逐项返回',
      {'from_folder': _string, 'to_folder': _string, 'comics': _comics},
      ['from_folder', 'to_folder', 'comics'],
    ),
    _schema(
      'fav_create_folder',
      '直接创建本地收藏夹，无需先检查名称；同名已存在则返回已有收藏夹，不重复创建',
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
    _schema(
      'later_add',
      '直接批量加入稍后再看；自动查重并取得必要元数据，无需先查详情或later_check；返回成功、已存在、不存在的数量和列表，并自动在稍后再看展示分组中显示',
      {'comics': _comics},
      ['comics'],
    ),
    _schema(
      'later_remove',
      '直接批量从稍后再看移除，无需先查询；自动判断是否存在，返回不存在数量和列表；可撤销',
      {'comics': _comics},
      ['comics'],
    ),
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
      final needsStatus =
          name == 'comic_open_by_id' && args['include_status'] != false;
      if (name.startsWith('fav_') || needsStatus) {
        await context.run.wait(favorites.init());
      }
      if (name.startsWith('later_') || needsStatus) {
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
          return {
            'name': folder,
            'status': 'skipped',
            'reason': 'ALREADY_EXISTS',
          };
        }
        c.run.check();
        return {'name': favorites.createFolder(folder), 'status': 'created'};
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
    throw AgentException('SOURCE_NOT_FOUND', '漫画源 $key 未安装或不可用');
  }

  Future<ComicDetails> _details(
    ComicSource source,
    String id,
    AgentToolContext c,
  ) async {
    c.run.check();
    final loader = source.loadComicInfo;
    if (loader == null) {
      throw const AgentException('NO_DETAIL_SUPPORT', '该源不提供漫画详情');
    }
    try {
      final result = await c.run.wait(loader(id), timeout: sourceTimeout);
      if (result.error || result.dataOrNull == null) {
        throw AgentException(
          'NOT_FOUND',
          '源未返回漫画详情：${result.errorMessage ?? '详情为空'}',
        );
      }
      return result.data;
    } on AgentException {
      rethrow;
    } catch (error) {
      throw AgentException('SOURCE_REQUEST_FAILED', '请求漫画详情失败：$error');
    }
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

  static AgentJson _briefJson(AgentComic comic) => {
    ...comic.ref,
    'title': comic.title,
    'subtitle': comic.subtitle,
    'description': comic.description,
    'tags': comic.tags,
  };
  AgentJson _detailJson(ComicDetails d, AgentComic comic) => {
    ..._briefJson(comic),
    'description': d.description ?? '',
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
      'groups': d.chapters?.groups.toList() ?? [],
      'items':
          d.chapters?.allChapters.entries
              .map((e) => {'id': e.key, 'name': e.value})
              .toList() ??
          [],
    },
    'recommend': (d.recommend ?? <Comic>[])
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
    final sourceKey = _text(a, 'source_key');
    final keyword = _text(a, 'keyword');
    final rawOptions = a['options'];
    if (rawOptions != null &&
        (rawOptions is! List || rawOptions.any((v) => v is! String))) {
      throw const AgentException('INVALID_ARGUMENT', 'options 需要字符串数组');
    }
    final continuation = a['continuation'];
    if (continuation != null) {
      final rest = _remainders[continuation];
      final key = rest == null
          ? null
          : jsonEncode([
              c.conversationId,
              sourceKey,
              keyword,
              rawOptions ?? (jsonDecode(rest.queryKey) as List)[3],
            ]);
      if (rest == null || rest.queryKey != key) {
        throw const AgentException('INVALID_CURSOR', '本页续读标记已失效，请重新搜索');
      }
      _remainders.remove(continuation);
      return _searchSlice(rest, size: pageSize);
    }
    final source = await _source(sourceKey, c);
    final search = source.searchPageData;
    if (search == null ||
        (search.loadPage == null && search.loadNext == null)) {
      throw const AgentException('NO_SEARCH_SUPPORT', '该源不支持搜索');
    }
    final definitions = search.searchOptions ?? [];
    final options = rawOptions == null
        ? definitions.map((d) => d.defaultValue).toList()
        : List<String>.from(rawOptions as List);
    if (options.length != definitions.length) {
      throw AgentException(
        'SEARCH_OPTION_MISMATCH',
        'options 需要 ${definitions.length} 项；省略 options 则自动使用默认值',
      );
    }
    final key = jsonEncode([c.conversationId, source.key, keyword, options]);
    final page = _number(a, 'page', 1, 10000);
    final cursor = a['cursor'];
    if (cursor != null && cursor is! String) {
      throw const AgentException('INVALID_CURSOR', 'cursor 必须是字符串');
    }
    final isCursor = search.loadPage == null;
    if (isCursor && page != 1 || !isCursor && cursor != null) {
      throw const AgentException('INVALID_ARGUMENT', '该源的页码/游标参数不匹配');
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
        '搜索失败：${result.errorMessage ?? ''}',
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
    final List<ComicSource> available;
    if (a.containsKey('source_key')) {
      available = [await _source(_text(a, 'source_key'), c)];
    } else {
      await c.run.wait(initializeSources());
      available = sources();
    }
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

  Future<AgentJson> _showcase(AgentJson a, AgentToolContext c) async {
    final mode = a['mode'] ?? 'append';
    if (!['append', 'replace'].contains(mode)) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'mode 只能为 append 或 replace',
      );
    }
    final title = a.containsKey('title') ? _text(a, 'title') : '为你找到的漫画';
    final note = a.containsKey('note') ? _text(a, 'note') : '';
    final refs = _refs(
      a,
      maximum: 30,
    ).map((ref) => _canonicalRef(ref, c)).toList();
    final prepared = <int, AgentComic>{};
    final failures = <int, AgentJson>{};
    final requested = <(String, String)>{};
    for (var offset = 0; offset < refs.length; offset += 4) {
      final jobs = <Future<void>>[];
      for (var i = offset; i < math.min(offset + 4, refs.length); i++) {
        final ref = refs[i];
        if (!requested.add(ref)) {
          failures[i] = {..._identity(ref), 'reason': 'DUPLICATE_IN_BATCH'};
          continue;
        }
        final index = i;
        jobs.add(() async {
          try {
            prepared[index] = await _metadata(ref, c);
          } on AgentException catch (e) {
            failures[index] = {
              ..._identity(ref),
              'reason': e.code,
              'message': e.message,
            };
          } catch (_) {
            failures[index] = {
              ..._identity(ref),
              'reason': 'TOOL_FAILED',
              'message': '无法读取漫画资料，请检查源状态后重试',
            };
          }
        }());
      }
      if (jobs.isNotEmpty) await Future.wait(jobs);
      c.run.check();
    }
    final comics = <AgentComic>[];
    final skipped = <AgentJson>[];
    final identities = <String>{};
    for (var i = 0; i < refs.length; i++) {
      final failure = failures[i];
      if (failure != null) {
        skipped.add(failure);
        continue;
      }
      final comic = prepared[i]!;
      if (!identities.add(comic.identity)) {
        skipped.add({...comic.ref, 'reason': 'DUPLICATE_IN_BATCH'});
      } else {
        comics.add(comic);
      }
    }
    c.run.check();
    final id = comics.isEmpty
        ? null
        : store.addShowcase(
            c.conversationId,
            comics,
            title: title,
            note: note,
            replace: mode == 'replace',
          );
    return {
      if (id != null) 'set_id': id,
      'title': title,
      'count': comics.length,
      'summary': {
        'total': refs.length,
        'ok': comics.length,
        'skipped': skipped
            .where((item) => item['reason'] == 'DUPLICATE_IN_BATCH')
            .length,
        'failed': skipped
            .where((item) => item['reason'] != 'DUPLICATE_IN_BATCH')
            .length,
      },
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

  AgentComic? _localMetadata((String, String) ref, AgentToolContext c) {
    final cached = store.seen(c.conversationId, ref.$1, ref.$2);
    if (cached != null) return cached;
    final type = _type(ref.$1);
    // Optional metadata must not initialize or require an unrelated library.
    if (favorites.isInitialized) {
      final folders = favorites.find(ref.$2, type);
      if (folders.isNotEmpty) {
        final comic = fromComic(
          favorites.getComic(folders.first, ref.$2, type),
        );
        store.remember(c.conversationId, comic);
        return comic;
      }
    }
    if (later.isInitialized) {
      for (final comic in later.getAll()) {
        if (comic.id == ref.$2 && comic.type == type) {
          final value = fromComic(comic);
          store.remember(c.conversationId, value);
          return value;
        }
      }
    }
    return null;
  }

  Future<AgentComic> _metadata((String, String) ref, AgentToolContext c) async {
    var local = _localMetadata(ref, c);
    if (local != null) return local;
    if (!favorites.isInitialized) {
      await c.run.wait(favorites.init());
      local = _localMetadata(ref, c);
      if (local != null) return local;
    }
    if (!later.isInitialized) {
      await c.run.wait(later.init());
      local = _localMetadata(ref, c);
      if (local != null) return local;
    }
    final source = await _source(ref.$1, c);
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
          final type = _type(ref.$1);
          final exists = name == 'fav_add'
              ? favorites.comicExists(folder!, ref.$2, type)
              : later.contains(ref.$2, type);
          if (exists) {
            final comic = _localMetadata(ref, c);
            if (comic != null) prepared[i] = comic;
            results[i] = {
              ..._identity(ref),
              if (comic != null) 'title': comic.title,
              'status': 'skipped',
              'reason': 'ALREADY_EXISTS',
              if (folder != null) 'folder': folder,
            };
            continue;
          }
          final index = i;
          jobs.add(() async {
            try {
              prepared[index] = await _metadata(ref, c);
            } on AgentException catch (e) {
              results[index] = {
                ..._identity(ref),
                'status': 'failed',
                'reason': e.code,
                'message': e.message,
              };
            } catch (_) {
              results[index] = {
                ..._identity(ref),
                'status': 'failed',
                'reason': 'TOOL_FAILED',
                'message': '无法读取漫画资料，请检查源状态后重试',
              };
            }
          }());
        }
      }
      if (jobs.isNotEmpty) await Future.wait(jobs);
      c.run.check();
    }
    final undo = <AgentJson>[];
    final undoId = agentId();
    final written = <String>{};
    final batchNotifications = name.startsWith('fav_')
        ? favorites.batchNotifications
        : later.batchNotifications;
    batchNotifications(() {
      for (var i = 0; i < refs.length; i++) {
        if (results[i] != null) continue;
        c.run.check();
        final resolved = prepared[i];
        final ref = resolved == null
            ? refs[i]
            : (resolved.sourceKey, resolved.comicId);
        final row = <String, dynamic>{
          ..._identity(ref),
          if (resolved != null) 'title': resolved.title,
        };
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
                store.removeOperationComic(
                  c.conversationId,
                  'favorites',
                  ref.$1,
                  ref.$2,
                  folder: folder,
                );
                break;
              }
              var removed = 0;
              for (final target in targets) {
                final item = favorites.getComic(target, ref.$2, type);
                row['title'] = item.name;
                favorites.deleteComicWithId(target, ref.$2, type);
                removed++;
                undo.add({
                  'kind': 'favorite',
                  'folder': target,
                  'time': item.time,
                  'comic': fromComic(item).toJson(),
                });
                store.saveUndo(undoId, c.conversationId, undo);
                store.removeOperationComic(
                  c.conversationId,
                  'favorites',
                  ref.$1,
                  ref.$2,
                  folder: target,
                );
              }
              row.addAll({
                'status': 'removed',
                'removed_folders': removed,
                'folders': targets,
              });
            case 'later_remove':
              final items = later
                  .getAll()
                  .where((item) => item.id == ref.$2 && item.type == type)
                  .toList();
              if (items.isEmpty) {
                row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
                store.removeOperationComic(
                  c.conversationId,
                  'later',
                  ref.$1,
                  ref.$2,
                );
                break;
              }
              if (later.remove(ref.$2, type)) {
                row['title'] = items.first.title;
                undo.add({
                  'kind': 'later',
                  'comic': fromComic(items.first).toJson(),
                });
                store.saveUndo(undoId, c.conversationId, undo);
                row['status'] = 'removed';
                store.removeOperationComic(
                  c.conversationId,
                  'later',
                  ref.$1,
                  ref.$2,
                );
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
              row['title'] = item.name;
              if (favorites.addComic(to, item)) {
                favorites.deleteComicWithId(from, ref.$2, type);
                store.remember(c.conversationId, fromComic(item));
                store.removeOperationComic(
                  c.conversationId,
                  'favorites',
                  ref.$1,
                  ref.$2,
                  folder: from,
                );
                row.addAll({'status': 'moved', 'folder': to});
              } else {
                row.addAll({'status': 'skipped', 'reason': 'ALREADY_EXISTS'});
              }
            default:
              throw const AgentException('UNKNOWN_TOOL', '未知写入工具');
          }
        } on AgentException catch (e) {
          row.addAll({
            'status': 'failed',
            'reason': e.code,
            'message': e.message,
          });
        } catch (_) {
          row.addAll({
            'status': 'failed',
            'reason': 'WRITE_FAILED',
            'message': '写入本地列表失败，请稍后重试',
          });
        }
      }
    });
    final values = results.whereType<AgentJson>().toList();
    final missing = values
        .where((v) => ['NOT_FOUND', 'NOT_PRESENT'].contains(v['reason']))
        .toList();
    for (final row in missing) {
      final metadata = _localMetadata((
        row['source_key'] as String,
        row['comic_id'] as String,
      ), c);
      if (metadata != null) row['title'] = metadata.title;
      if (folder != null) row['folder'] = folder;
    }
    String? showcaseId;
    if (['fav_add', 'fav_move', 'later_add'].contains(name)) {
      final comics = <String, AgentComic>{};
      for (final row in values.where(
        (row) =>
            ['added', 'moved'].contains(row['status']) ||
            row['reason'] == 'ALREADY_EXISTS',
      )) {
        final comic = _localMetadata((
          row['source_key'] as String,
          row['comic_id'] as String,
        ), c);
        if (comic != null) comics[comic.identity] = comic;
      }
      if (comics.isNotEmpty) {
        showcaseId = store.recordOperationComics(
          c.conversationId,
          name == 'later_add' ? 'later' : 'favorites',
          comics.values.toList(),
          folder: folder ?? to ?? '',
        );
      }
    }
    return {
      'summary': {
        'total': refs.length,
        'ok': values
            .where((v) => ['added', 'removed', 'moved'].contains(v['status']))
            .length,
        'skipped': values.where((v) => v['status'] == 'skipped').length,
        'failed': values.where((v) => v['status'] == 'failed').length,
        'missing': missing.length,
        'already_exists': values
            .where((v) => v['reason'] == 'ALREADY_EXISTS')
            .length,
      },
      'results': values,
      'missing': missing,
      if (missing.isNotEmpty)
        'message':
            '有 ${missing.length} 本不在目标列表中，或源未返回它们的信息，详见 missing 列表及各项原因；其余条目已独立处理。',
      if (showcaseId != null) 'set_id': showcaseId,
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
              store.remember(c.conversationId, comic);
              store.recordOperationComics(
                c.conversationId,
                entry['kind'] == 'favorite' ? 'favorites' : 'later',
                [comic],
                folder: entry['folder'] as String? ?? '',
              );
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
