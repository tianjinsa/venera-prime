import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'agent_app_bridge.dart';
import 'agent_models.dart';
import 'agent_store.dart';

part 'agent_tool_schemas.dart';
part 'agent_tools_catalog.dart';
part 'agent_tools_library.dart';

class AgentToolContext {
  final String conversationId;
  final AgentRun run;
  const AgentToolContext(this.conversationId, this.run);
}

class AgentTools {
  final AgentStore store;
  final LocalFavoritesManager favorites;
  final ReadLaterManager later;
  final Future<void> Function() initializeSources;
  final List<ComicSource> Function() sources;
  final Duration sourceTimeout;
  final AgentAppBridge app;

  /// Details already read in this session. Chapter pages, downloads and the
  /// reader reuse them instead of requesting the whole comic again.
  final _details = <String, (DateTime, ComicDetails)>{};

  /// Successful list pages of sources, keyed by every request parameter.
  /// Repeating a page or returning to it while paging needs no new request.
  final _pages = <String, (DateTime, Res<Object>)>{};

  /// Network favorite ids some sources need to remove an entry again.
  final _networkFavoriteIds = <String, String>{};

  AgentTools(
    this.store, {
    LocalFavoritesManager? favorites,
    ReadLaterManager? later,
    Future<void> Function()? initializeSources,
    List<ComicSource> Function()? sources,
    this.sourceTimeout = const Duration(seconds: 30),
    AgentAppBridge? app,
  }) : app = app ?? const AgentAppBridge(),
       favorites = favorites ?? LocalFavoritesManager(),
       later = later ?? ReadLaterManager(),
       initializeSources =
           initializeSources ?? (() => ComicSourceManager().init()),
       sources = sources ?? ComicSource.all;

  static List<AgentJson> get schemas => _agentToolSchemas;

  static const writeTools = {
    'fav_add',
    'fav_remove',
    'fav_move',
    'fav_create_folder',
    'fav_rename_folder',
    'later_add',
    'later_remove',
    'history_remove',
    'local_delete',
    'download_start',
    'download_control',
    'updates_mark_read',
    'net_fav_add',
    'net_fav_remove',
    'source_install',
    'source_update',
    'blocked_words_update',
  };
  static const destructiveTools = {
    'fav_remove',
    'fav_move',
    'later_remove',
    'history_remove',
    'local_delete',
    'download_control',
    'net_fav_remove',
  };

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
      bool matches(AgentJson spec) {
        final function = spec['function'] as Map;
        if (function['name'] != name) return false;
        final params = function['parameters'] as Map;
        final properties = params['properties'] as Map;
        return args.keys.every(properties.containsKey) &&
            (params['required'] as List).every(args.containsKey);
      }

      final known = [
        ..._agentToolSchemas,
        ..._legacySchemas,
      ].where((s) => s['function']['name'] == name);
      if (known.isEmpty) {
        throw const AgentException('UNKNOWN_TOOL', '工具不在应用允许的清单中');
      }
      if (!known.any(matches)) {
        throw const AgentException('INVALID_ARGUMENT', '工具参数缺失或包含未知字段');
      }
      // Validate all array references before entering any write path.
      if (args.containsKey('comics') && name != 'download_start') {
        _refs(args, maximum: name == 'showcase_comics' ? 30 : 50);
      }
      final needsStatus =
          ['comic_open_by_id', 'comic_get'].contains(name) &&
              args['include_status'] != false ||
          name == 'comic_status';
      if (name.startsWith('fav_') ||
          name.startsWith('updates_') ||
          needsStatus) {
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
        return _searchOptions(source);
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
        final details = await _loadDetails(source, cached?.comicId ?? id, c);
        _cacheDetails(details, alias: id);
        final brief = _rememberDetails(details, c, alias: id);
        return {
          ..._detailJson(details, brief),
          if (a['include_status'] != false)
            ..._status((brief.sourceKey, brief.comicId)),
        };
      case 'showcase_comics':
        return _showcase(a, c);
      case 'fav_list_folders':
        final keyword = a.containsKey('keyword')
            ? _text(a, 'keyword').toLowerCase()
            : null;
        final followed = app.followedFolder();
        return _paged(
          [
            for (final folder in favorites.folderNames)
              if (keyword == null || folder.toLowerCase().contains(keyword))
                {
                  'name': folder,
                  'count': favorites.count(folder),
                  if (folder == followed) 'follow_updates': true,
                },
          ],
          a,
          size: 50,
          maximum: 200,
        );
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
        if (a.containsKey('name')) return _createFolder(_text(a, 'name'), c);
        return _createFolders(a, c);
      case 'fav_rename_folder':
        return _renameFolders(a, c);
      case 'fav_add' ||
          'fav_remove' ||
          'fav_move' ||
          'later_add' ||
          'later_remove':
        return _write(name, a, c);
      default:
        return _dispatchMore(name, a, c);
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
    'explore_pages': source.explorePages.length,
    'categories': source.categoryData != null,
    'ranking': source.categoryComicsData?.rankingData != null,
    'network_favorites': source.favoriteData != null,
    'comments': source.commentsLoader != null,
  };

  Future<ComicSource> _source(String key, AgentToolContext c) async {
    await c.run.wait(initializeSources());
    for (final source in sources()) {
      if (source.key == key) return source;
    }
    throw AgentException('SOURCE_NOT_FOUND', '漫画源 $key 未安装或不可用');
  }

  Future<ComicDetails> _loadDetails(
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
    // Long series can have thousands of chapters; the rest are paged.
    'chapters': _chapterPage(d.chapters, null, 1, 30),
    'recommend': (d.recommend ?? <Comic>[])
        .map((item) => _briefJson(fromComic(item)))
        .toList(),
  };

  /// Chapter indexes are 1-based as in the reader; grouped comics number
  /// chapters within their group.
  static AgentJson _chapterPage(
    ComicChapters? chapters,
    String? group,
    int page,
    int size,
  ) {
    if (chapters == null) {
      return {'count': 0, 'items': <AgentJson>[], 'total_pages': 0};
    }
    final items = <AgentJson>[];
    if (chapters.isGrouped) {
      final groups = chapters.groups.toList();
      if (group != null && !groups.contains(group)) {
        throw AgentException('NOT_FOUND', '没有名为 $group 的章节分组');
      }
      for (var g = 0; g < groups.length; g++) {
        if (group != null && groups[g] != group) continue;
        var index = 0;
        for (final entry in chapters.getGroup(groups[g]).entries) {
          items.add({
            'group': groups[g],
            'group_index': g + 1,
            'index': ++index,
            'id': entry.key,
            'title': entry.value,
          });
        }
      }
    } else {
      if (group != null) {
        throw const AgentException('INVALID_ARGUMENT', '该漫画的章节没有分组');
      }
      var index = 0;
      for (final entry in chapters.allChapters.entries) {
        items.add({'index': ++index, 'id': entry.key, 'title': entry.value});
      }
    }
    return {
      'count': chapters.length,
      if (chapters.isGrouped)
        'groups': [
          for (final name in chapters.groups)
            {'title': name, 'count': chapters.getGroup(name).length},
        ],
      if (group != null) 'group': group,
      'items': items.skip((page - 1) * size).take(size).toList(),
      'page': page,
      'page_size': size,
      'total_pages': (items.length / size).ceil(),
      'has_more': page * size < items.length,
    };
  }

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
    ..._libraryStatus(ref),
  };

  (String, String) _canonicalRef((String, String) ref, AgentToolContext c) {
    final comic = store.seen(c.conversationId, ref.$1, ref.$2);
    return comic == null ? ref : (comic.sourceKey, comic.comicId);
  }

  Future<AgentJson> _search(
    AgentJson a,
    AgentToolContext c, {
    ComicSource? resolvedSource,
  }) async {
    final sourceKey = _text(a, 'source_key');
    final keyword = _text(a, 'keyword');
    final rawOptions = a['options'];
    if (rawOptions != null &&
        (rawOptions is! List || rawOptions.any((v) => v is! String))) {
      throw const AgentException('INVALID_ARGUMENT', 'options 需要字符串数组');
    }
    final source = resolvedSource ?? await _source(sourceKey, c);
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
    final page = _number(a, 'page', 1, 10000);
    final cursor = a['cursor'];
    if (cursor != null && cursor is! String) {
      throw const AgentException('INVALID_CURSOR', 'cursor 必须是字符串');
    }
    final isCursor = search.loadPage == null;
    if (isCursor && page != 1 || !isCursor && cursor != null) {
      throw const AgentException('INVALID_ARGUMENT', '该源的页码/游标参数不匹配');
    }
    final (result, cached) = await _cachedPage<List<Comic>>(
      ['search', source.key, keyword, options, if (isCursor) cursor else page],
      () => isCursor
          ? search.loadNext!(keyword, cursor as String?, options)
          : search.loadPage!(keyword, page, options),
      c,
    );
    if (result.error) {
      throw AgentException(
        'SEARCH_FAILED',
        '搜索失败：${result.errorMessage ?? ''}',
      );
    }
    return {
      'source_key': source.key,
      'keyword': keyword,
      'options': options,
      ..._comicPage(
        result,
        c,
        cursor: isCursor,
        page: page,
        current: cursor as String?,
        cached: cached,
      ),
    };
  }

  Future<AgentJson> _resolve(AgentJson a, AgentToolContext c) async {
    final query = _text(a, 'query');
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
      final details = await _loadDetails(source, id, c);
      final comic = _rememberDetails(details, c, alias: id);
      return {
        'resolved_by': linkSources.isNotEmpty ? 'url_extract' : 'id_match',
        'candidates': [_briefJson(comic)],
      };
    }
    final result = await _search(
      {'source_key': available.single.key, 'keyword': query},
      c,
      resolvedSource: available.single,
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
    final folders = a.containsKey('folder')
        ? [_folder(a, 'folder')]
        : favorites.folderNames;
    final keyword = a.containsKey('keyword') ? _text(a, 'keyword') : null;
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

  /// A page of an in-memory list with the counts needed to continue.
  static AgentJson _paged(
    List<AgentJson> items,
    AgentJson a, {
    int size = 20,
    int maximum = 50,
  }) {
    final page = _number(a, 'page', 1, 1000000);
    final pageSize = _number(a, 'page_size', size, maximum);
    return {
      'items': items.skip((page - 1) * pageSize).take(pageSize).toList(),
      'total': items.length,
      'page': page,
      'page_size': pageSize,
      'total_pages': (items.length / pageSize).ceil(),
      'has_more': page * pageSize < items.length,
    };
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
      'page_size': size,
      'total_pages': (items.length / size).ceil(),
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
      final comic = later.getComic(ref.$2, type);
      if (comic != null) {
        final value = fromComic(comic);
        store.remember(c.conversationId, value);
        return value;
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
      await _loadDetails(source, ref.$2, c),
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
            var comic = store.seen(c.conversationId, ref.$1, ref.$2);
            if (comic == null) {
              comic = fromComic(
                name == 'fav_add'
                    ? favorites.getComic(folder!, ref.$2, type)
                    : later.getComic(ref.$2, type)!,
              );
              store.remember(c.conversationId, comic);
            }
            prepared[i] = comic;
            results[i] = {
              ..._identity(ref),
              'title': comic.title,
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
              final targets = folder == null
                  ? favorites.find(ref.$2, type)
                  : favorites.comicExists(folder, ref.$2, type)
                  ? [folder]
                  : <String>[];
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
              final item = later.getComic(ref.$2, type);
              if (item == null) {
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
                row['title'] = item.title;
                undo.add({'kind': 'later', 'comic': fromComic(item).toJson()});
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
            if (entry['kind'] == 'history') {
              if (!app.historyReady) throw StateError('History is closed');
              final history = _AgentLibraryTools._historyFromMap(
                agentObject(entry['history']),
              );
              if (app.findHistory(history.id, history.type) != null) {
                skipped++;
              } else {
                app.addHistory(history);
                restored++;
              }
              continue;
            }
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
