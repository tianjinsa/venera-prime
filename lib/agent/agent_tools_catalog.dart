part of 'agent_tools.dart';

const _detailTtl = Duration(minutes: 10);
const _pageTtl = Duration(minutes: 5);
const _networkTimeout = Duration(seconds: 60);

/// Sources, search, comic details and discovery.
extension _AgentCatalogTools on AgentTools {
  String _sourceKeyOf(ComicType type) {
    if (type == ComicType.local) return 'local';
    for (final source in sources()) {
      if (ComicType.fromKey(source.key) == type) return source.key;
    }
    return 'Unknown:${type.value}';
  }

  void _cacheDetails(ComicDetails details, {String? alias}) {
    final entry = (DateTime.now(), details);
    for (final id in {details.comicId, ?alias}) {
      final key = jsonEncode([details.sourceKey, id]);
      _details.remove(key);
      _details[key] = entry;
    }
    while (_details.length > 32) {
      _details.remove(_details.keys.first);
    }
  }

  /// Details for tools that only need chapters or titles again.
  Future<ComicDetails> _cachedDetails(
    ComicSource source,
    String id,
    AgentToolContext c,
  ) async {
    final canonical =
        store.seen(c.conversationId, source.key, id)?.comicId ?? id;
    for (final candidate in {id, canonical}) {
      final hit = _details[jsonEncode([source.key, candidate])];
      if (hit != null && DateTime.now().difference(hit.$1) < _detailTtl) {
        return hit.$2;
      }
    }
    final details = await _loadDetails(source, canonical, c);
    _cacheDetails(details, alias: id);
    _rememberDetails(details, c, alias: id);
    return details;
  }

  /// Only successful pages are cached. The key must contain every parameter
  /// of the request, so different options or cursors never share results.
  Future<(Res<T>, bool)> _cachedPage<T extends Object>(
    List<Object?> key,
    Future<Res<T>> Function() load,
    AgentToolContext c,
  ) async {
    final id = jsonEncode(key);
    final hit = _pages[id];
    if (hit != null && DateTime.now().difference(hit.$1) < _pageTtl) {
      return (hit.$2 as Res<T>, true);
    }
    c.run.check();
    final Res<T> result;
    try {
      result = await c.run.wait(load(), timeout: sourceTimeout);
    } on AgentException {
      rethrow;
    } catch (error) {
      throw AgentException('SOURCE_REQUEST_FAILED', '请求漫画源失败：$error');
    }
    if (!result.error) {
      _pages.remove(id);
      _pages[id] = (DateTime.now(), result);
      while (_pages.length > 64) {
        _pages.remove(_pages.keys.first);
      }
    }
    return (result, false);
  }

  /// One page of comics from a source, with the fields needed to continue.
  AgentJson _comicPage(
    Res<List<Comic>> result,
    AgentToolContext c, {
    required bool cursor,
    int page = 1,
    String? current,
    bool cached = false,
  }) {
    final items = result.data.map(AgentTools.fromComic).toList();
    for (final item in items) {
      store.remember(c.conversationId, item);
    }
    final maxPage = !cursor && result.subData is int
        ? result.subData as int
        : null;
    final next =
        cursor &&
            result.subData is String &&
            result.subData != current &&
            (result.subData as String).isNotEmpty
        ? result.subData as String
        : null;
    final hasMore = cursor
        ? next != null
        : maxPage != null
        ? page < maxPage
        : items.isNotEmpty;
    return {
      'style': cursor ? 'cursor' : 'page',
      'page': cursor ? null : page,
      'max_page': maxPage,
      'next_page': !cursor && hasMore ? page + 1 : null,
      'next_cursor': next,
      'has_more': hasMore,
      'exhausted': !hasMore,
      if (cached) 'from_cache': true,
      'count': items.length,
      'items': items.map(AgentTools._briefJson).toList(),
    };
  }

  (int, String?) _pageOrCursor(AgentJson a, {required bool cursor}) {
    final page = AgentTools._number(a, 'page', 1, 10000);
    final value = a['cursor'];
    if (value != null && value is! String) {
      throw const AgentException('INVALID_CURSOR', 'cursor 必须是字符串');
    }
    if (cursor && page != 1 || !cursor && value != null) {
      throw const AgentException('INVALID_ARGUMENT', '该列表的页码/游标参数不匹配');
    }
    return (page, value as String?);
  }

  List<AgentJson> _searchOptions(ComicSource source) => [
    for (final option in source.searchPageData?.searchOptions ?? [])
      {
        'label': option.label,
        'type': option.type,
        'options': option.options,
        'default': option.defaultValue,
      },
  ];

  List<BaseCategoryPart> _categoryParts(ComicSource source) =>
      source.categoryData?.categories ?? const [];

  /// Dynamic parts run source scripts and random parts sample; read all.
  List<CategoryItem>? _categoryItems(BaseCategoryPart part) {
    try {
      return part is RandomCategoryPart ? part.all : part.categories;
    } catch (_) {
      return null;
    }
  }

  static AgentJson _target(PageJumpTarget target) {
    final attributes = target.attributes ?? const {};
    return switch (target.page) {
      'category' => {
        'kind': 'category',
        'category': attributes['category'],
        if (attributes['param'] != null) 'param': attributes['param'],
      },
      'search' => {
        'kind': 'search',
        'keyword': attributes['text'] ?? attributes['keyword'],
        if (attributes['options'] != null) 'options': attributes['options'],
      },
      _ => {'kind': target.page},
    };
  }

  static AgentJson _categoryOption(CategoryComicsOptions option) => {
    'label': option.label,
    'options': option.options,
    'default': option.options.keys.firstOrNull ?? '',
  };

  Future<AgentJson> _sourceInfo(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final comics = source.categoryComicsData;
    final favorite = source.favoriteData;
    return {
      ..._capability(source),
      'search_options': _searchOptions(source),
      'explore_pages': [
        for (final page in source.explorePages)
          {'title': page.title, 'type': page.type.name},
      ],
      'category_groups': [
        for (final part in _categoryParts(source))
          {'title': part.title, 'count': _categoryItems(part)?.length},
      ],
      'category_options': [
        for (final option in comics?.options ?? <CategoryComicsOptions>[])
          {
            ..._categoryOption(option),
            if (option.notShowWhen.isNotEmpty)
              'not_show_when': option.notShowWhen,
            if (option.showWhen != null) 'show_when': option.showWhen,
          },
      ],
      if (comics?.optionsLoader != null) 'category_options_dynamic': true,
      'ranking_options': comics?.rankingData?.options ?? const {},
      if (favorite != null)
        'network_favorites': {
          'multi_folder': favorite.multiFolder,
          'logged_in': source.isLogged,
        },
      'comments': source.commentsLoader != null,
      'chapter_comments': source.chapterCommentsLoader != null,
    };
  }

  Future<AgentJson> _sourceCategories(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final group = a.containsKey('group') ? AgentTools._text(a, 'group') : null;
    final parts = _categoryParts(
      source,
    ).where((part) => group == null || part.title == group).toList();
    if (parts.isEmpty) {
      throw AgentException(
        group == null ? 'NO_CATEGORY_SUPPORT' : 'NOT_FOUND',
        group == null ? '该源不提供分类' : '没有名为 $group 的分类分组',
      );
    }
    final unavailable = <String>[];
    final items = <AgentJson>[];
    for (final part in parts) {
      final values = _categoryItems(part);
      if (values == null) {
        unavailable.add(part.title);
        continue;
      }
      for (final item in values) {
        items.add({
          'group': part.title,
          'label': item.label,
          ..._target(item.target),
        });
      }
    }
    return {
      'source_key': source.key,
      ...AgentTools._paged(items, a, size: 50, maximum: 200),
      if (unavailable.isNotEmpty) 'unavailable_groups': unavailable,
    };
  }

  Future<AgentJson> _searchAll(AgentJson a, AgentToolContext c) async {
    final keyword = AgentTools._text(a, 'keyword');
    final page = AgentTools._number(a, 'page', 1, 10000);
    final perSource = AgentTools._number(a, 'per_source', 20, 100);
    final rawCursors = a['cursors'] ?? const {};
    if (rawCursors is! Map || rawCursors.values.any((v) => v is! String)) {
      throw const AgentException('INVALID_ARGUMENT', 'cursors 需要源到游标字符串的映射');
    }
    final cursors = Map<String, String>.from(rawCursors);
    await c.run.wait(initializeSources());
    final installed = sources();
    final results = <AgentJson>[];
    final selected = <ComicSource>[];
    if (a.containsKey('source_keys')) {
      final keys = a['source_keys'];
      if (keys is! List || keys.isEmpty || keys.any((k) => k is! String)) {
        throw const AgentException('INVALID_ARGUMENT', 'source_keys 需要字符串数组');
      }
      for (final key in keys.cast<String>().toSet()) {
        final source = installed.where((s) => s.key == key).firstOrNull;
        if (source == null) {
          results.add({
            'source_key': key,
            'status': 'failed',
            'error': {'code': 'SOURCE_NOT_FOUND', 'message': '漫画源未安装'},
          });
        } else {
          selected.add(source);
        }
      }
    } else {
      final configured = app.setting('searchSources');
      if (configured is List) {
        for (final key in configured) {
          final source = installed.where((s) => s.key == key).firstOrNull;
          if (source?.searchPageData != null) selected.add(source!);
        }
      }
      if (selected.isEmpty) {
        selected.addAll(installed.where((s) => s.searchPageData != null));
      }
    }
    if (selected.isEmpty && results.isEmpty) {
      throw const AgentException('NO_SEARCH_SUPPORT', '没有可搜索的漫画源');
    }
    final entries = List<AgentJson?>.filled(selected.length, null);
    for (var offset = 0; offset < selected.length; offset += 4) {
      await Future.wait([
        for (var i = offset; i < math.min(offset + 4, selected.length); i++)
          () async {
            final source = selected[i];
            final search = source.searchPageData;
            final cursor = search?.loadPage == null;
            final base = {'source_key': source.key, 'name': source.name};
            if (cursor && page > 1 && cursors[source.key] == null) {
              entries[i] = {
                ...base,
                'status': 'skipped',
                'reason': 'CURSOR_REQUIRED',
                'message': '游标式源需在 cursors 中提供上次的 next_cursor',
              };
              return;
            }
            try {
              final result = await _search(
                {
                  'source_key': source.key,
                  'keyword': keyword,
                  if (!cursor) 'page': page,
                  if (cursor && cursors[source.key] != null)
                    'cursor': cursors[source.key],
                },
                c,
                resolvedSource: source,
              );
              final items = result.remove('items') as List;
              result.remove('keyword');
              entries[i] = {
                ...base,
                'status': 'ok',
                ...result,
                'count_on_page': items.length,
                'items': items.take(perSource).toList(),
                if (items.length > perSource) 'truncated': true,
              };
            } on AgentException catch (e) {
              if (e.code == 'CANCELLED') rethrow;
              entries[i] = {
                ...base,
                'status': 'failed',
                'error': {'code': e.code, 'message': e.message},
              };
            }
          }(),
      ]);
      c.run.check();
    }
    results.addAll(entries.whereType<AgentJson>());
    int count(String status) =>
        results.where((r) => r['status'] == status).length;
    return {
      'keyword': keyword,
      'page': page,
      'summary': {
        'total': results.length,
        'ok': count('ok'),
        'skipped': count('skipped'),
        'failed': count('failed'),
      },
      'results': results,
    };
  }

  Future<AgentJson> _comicChapters(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final details = await _cachedDetails(
      source,
      AgentTools._text(a, 'comic_id'),
      c,
    );
    return {
      'source_key': details.sourceKey,
      'comic_id': details.comicId,
      'title': details.title,
      ...AgentTools._chapterPage(
        details.chapters,
        a.containsKey('group') ? AgentTools._text(a, 'group') : null,
        AgentTools._number(a, 'page', 1, 100000),
        AgentTools._number(a, 'page_size', 30, 200),
      ),
    };
  }

  Future<AgentJson> _comicStatus(AgentJson a, AgentToolContext c) async {
    // The app opens these at start; status stays available if one fails.
    for (final init in [app.initHistory, app.initLocal]) {
      try {
        await c.run.wait(init());
      } on AgentException {
        rethrow;
      } catch (_) {}
    }
    await c.run.wait(initializeSources().catchError((Object _) {}));
    return {
      'results': [
        for (final ref in AgentTools._refs(a).map((r) => _canonicalRef(r, c)))
          {
            ...AgentTools._identity(ref),
            if (_localMetadata(ref, c)?.title case final String title)
              'title': title,
            ..._status(ref),
          },
      ],
    };
  }

  Future<AgentJson> _comments(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final id = AgentTools._text(a, 'comic_id');
    final chapter = a.containsKey('chapter_id')
        ? AgentTools._text(a, 'chapter_id')
        : null;
    final replyTo = a.containsKey('reply_to')
        ? AgentTools._text(a, 'reply_to')
        : null;
    final page = AgentTools._number(a, 'page', 1, 100000);
    Future<Res<List<Comment>>> Function() load;
    if (chapter != null) {
      final loader =
          source.chapterCommentsLoader ??
          (throw const AgentException('NO_COMMENT_SUPPORT', '该源不提供章节评论'));
      load = () => loader(id, chapter, page, replyTo);
    } else {
      final loader =
          source.commentsLoader ??
          (throw const AgentException('NO_COMMENT_SUPPORT', '该源不提供评论'));
      // Some sources address comments with the detail's secondary id.
      String? subId;
      try {
        subId = (await _cachedDetails(source, id, c)).subId;
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
      }
      load = () => loader(id, subId, page, replyTo);
    }
    final (result, cached) = await _cachedPage<List<Comment>>(
      ['comments', source.key, id, chapter, replyTo, page],
      load,
      c,
    );
    if (result.error) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取评论失败：${result.errorMessage ?? ''}',
      );
    }
    final maxPage = result.subData is int ? result.subData as int : null;
    final comments = result.data;
    return {
      'source_key': source.key,
      'comic_id': id,
      'chapter_id': ?chapter,
      'reply_to': ?replyTo,
      'page': page,
      'max_page': maxPage,
      'has_more': maxPage != null ? page < maxPage : comments.isNotEmpty,
      if (cached) 'from_cache': true,
      'count': comments.length,
      'comments': [
        for (final comment in comments)
          {
            'id': comment.id,
            'user': comment.userName,
            'content': comment.content,
            'time': comment.time,
            'reply_count': comment.replyCount,
            'score': comment.score,
          },
      ],
    };
  }

  Future<AgentJson> _exploreLoad(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final title = AgentTools._text(a, 'title');
    final pages = source.explorePages;
    var matches = pages.where((p) => p.title == title).toList();
    if (matches.isEmpty) {
      matches = pages
          .where((p) => p.title.toLowerCase().contains(title.toLowerCase()))
          .toList();
    }
    if (matches.length != 1) {
      throw AgentException(
        'NOT_FOUND',
        '发现页不存在或不唯一，可用：${pages.map((p) => p.title).join('、')}',
      );
    }
    final explore = matches.single;
    final base = {
      'source_key': source.key,
      'title': explore.title,
      'type': explore.type.name,
    };
    AgentJson part(ExplorePagePart part) {
      final comics = part.comics.map(AgentTools.fromComic).toList();
      for (final comic in comics) {
        store.remember(c.conversationId, comic);
      }
      return {
        'type': 'part',
        'title': part.title,
        'count': comics.length,
        'items': comics.map(AgentTools._briefJson).toList(),
        if (part.viewMore != null) 'view_more': _target(part.viewMore!),
      };
    }

    switch (explore.type) {
      case ExplorePageType.multiPageComicList:
        final cursor = explore.loadPage == null;
        if (cursor && explore.loadNext == null) break;
        final (page, next) = _pageOrCursor(a, cursor: cursor);
        final (result, cached) = await _cachedPage<List<Comic>>(
          ['explore', source.key, explore.title, cursor ? next : page],
          () => cursor ? explore.loadNext!(next) : explore.loadPage!(page),
          c,
        );
        if (result.error) break;
        return {
          ...base,
          ..._comicPage(
            result,
            c,
            cursor: cursor,
            page: page,
            current: next,
            cached: cached,
          ),
        };
      case ExplorePageType.singlePageWithMultiPart:
        if (explore.loadMultiPart == null) break;
        final (result, cached) = await _cachedPage<List<ExplorePagePart>>(
          ['explore', source.key, explore.title],
          explore.loadMultiPart!,
          c,
        );
        if (result.error) {
          throw AgentException(
            'SOURCE_REQUEST_FAILED',
            '读取发现页失败：${result.errorMessage ?? ''}',
          );
        }
        return {
          ...base,
          if (cached) 'from_cache': true,
          'parts': result.data.map(part).toList(),
        };
      case ExplorePageType.mixed:
        if (explore.loadMixed == null) break;
        final (page, _) = _pageOrCursor(a, cursor: false);
        final (result, cached) = await _cachedPage<List<Object>>(
          ['explore', source.key, explore.title, page],
          () => explore.loadMixed!(page),
          c,
        );
        if (result.error) {
          throw AgentException(
            'SOURCE_REQUEST_FAILED',
            '读取发现页失败：${result.errorMessage ?? ''}',
          );
        }
        final maxPage = result.subData is int ? result.subData as int : null;
        return {
          ...base,
          'page': page,
          'max_page': maxPage,
          'has_more': maxPage != null ? page < maxPage : result.data.isNotEmpty,
          if (cached) 'from_cache': true,
          'sections': [
            for (final element in result.data)
              if (element is ExplorePagePart)
                part(element)
              else if (element is List)
                part(
                  ExplorePagePart(
                    '',
                    element.whereType<Comic>().toList(),
                    null,
                  ),
                )..['type'] = 'comics',
          ],
        };
      case ExplorePageType.override:
        throw const AgentException('NO_EXPLORE_SUPPORT', '该发现页只能在应用中查看');
    }
    throw const AgentException('SOURCE_REQUEST_FAILED', '读取发现页失败，请稍后重试');
  }

  Future<AgentJson> _categoryComics(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final data =
        source.categoryComicsData ??
        (throw const AgentException('NO_CATEGORY_SUPPORT', '该源不提供分类漫画'));
    final category = AgentTools._text(a, 'category');
    final param = a.containsKey('param') ? AgentTools._text(a, 'param') : null;
    List<CategoryComicsOptions> definitions;
    if (data.optionsLoader != null) {
      final (result, _) = await _cachedPage<List<CategoryComicsOptions>>(
        ['category_options', source.key, category, param],
        () => data.optionsLoader!(category, param),
        c,
      );
      if (result.error) {
        throw AgentException(
          'SOURCE_REQUEST_FAILED',
          '读取分类筛选失败：${result.errorMessage ?? ''}',
        );
      }
      definitions = result.data;
    } else {
      // Same visibility rules as the category page.
      definitions = (data.options ?? [])
          .where(
            (o) =>
                !o.notShowWhen.contains(category) &&
                (o.showWhen == null || o.showWhen!.contains(category)),
          )
          .toList();
    }
    final raw = a['options'];
    if (raw != null && (raw is! List || raw.any((v) => v is! String))) {
      throw const AgentException('INVALID_ARGUMENT', 'options 需要字符串数组');
    }
    final options = raw == null
        ? [for (final d in definitions) d.options.keys.firstOrNull ?? '']
        : List<String>.from(raw as List);
    if (options.length != definitions.length) {
      throw AgentException(
        'OPTION_MISMATCH',
        'options 需要 ${definitions.length} 项；省略 options 则使用默认筛选',
      );
    }
    final (page, _) = _pageOrCursor(a, cursor: false);
    final (result, cached) = await _cachedPage<List<Comic>>(
      ['category', source.key, category, param, options, page],
      () => data.load(category, param, options, page),
      c,
    );
    if (result.error) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取分类失败：${result.errorMessage ?? ''}',
      );
    }
    return {
      'source_key': source.key,
      'category': category,
      'param': ?param,
      'options': options,
      'option_definitions': definitions.map(_categoryOption).toList(),
      ..._comicPage(result, c, cursor: false, page: page, cached: cached),
    };
  }

  Future<AgentJson> _rankingComics(AgentJson a, AgentToolContext c) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final data =
        source.categoryComicsData?.rankingData ??
        (throw const AgentException('NO_RANKING_SUPPORT', '该源不提供排行榜'));
    if (data.options.isEmpty) {
      throw const AgentException('NO_RANKING_SUPPORT', '该源没有排行选项');
    }
    var option = a.containsKey('option')
        ? AgentTools._text(a, 'option')
        : data.options.keys.first;
    if (!data.options.containsKey(option)) {
      // Accept the displayed label as well as the option key.
      final key = data.options.entries
          .where((e) => e.value == option)
          .firstOrNull
          ?.key;
      if (key == null) {
        throw AgentException(
          'INVALID_ARGUMENT',
          'option 可用值：${data.options.keys.join('、')}',
        );
      }
      option = key;
    }
    final cursor = data.load == null;
    if (cursor && data.loadWithNext == null) {
      throw const AgentException('NO_RANKING_SUPPORT', '该源不提供排行榜');
    }
    final (page, next) = _pageOrCursor(a, cursor: cursor);
    final selected = option;
    final (result, cached) = await _cachedPage<List<Comic>>(
      ['ranking', source.key, selected, cursor ? next : page],
      () => cursor
          ? data.loadWithNext!(selected, next)
          : data.load!(selected, page),
      c,
    );
    if (result.error) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取排行榜失败：${result.errorMessage ?? ''}',
      );
    }
    return {
      'source_key': source.key,
      'option': selected,
      'option_label': data.options[selected],
      ..._comicPage(
        result,
        c,
        cursor: cursor,
        page: page,
        current: next,
        cached: cached,
      ),
    };
  }

  Future<List<AgentCatalogSource>> _catalog(
    AgentToolContext c, {
    bool fresh = false,
    List<String>? failures,
  }) async {
    const key = '["source_catalog"]';
    final hit = _pages[key];
    if (!fresh && hit != null && DateTime.now().difference(hit.$1) < _pageTtl) {
      return (hit.$2 as Res<List<AgentCatalogSource>>).data;
    }
    final (entries, failed) = await c.run.wait(
      app.sourceCatalog(),
      timeout: _networkTimeout,
    );
    failures?.addAll(failed);
    if (entries.isEmpty && failed.isNotEmpty) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取漫画源仓库失败：${failed.join('、')}',
      );
    }
    _pages[key] = (DateTime.now(), Res<List<AgentCatalogSource>>(entries));
    return entries;
  }

  Future<AgentJson> _sourceCatalog(AgentJson a, AgentToolContext c) async {
    await c.run.wait(initializeSources());
    final installed = {for (final s in sources()) s.key: s.version};
    final failures = <String>[];
    final entries = await _catalog(c, fresh: true, failures: failures);
    final keyword = a.containsKey('keyword')
        ? AgentTools._text(a, 'keyword').toLowerCase()
        : null;
    return {
      ...AgentTools._paged(
        [
          for (final entry in entries)
            if (keyword == null ||
                entry.key.toLowerCase().contains(keyword) ||
                entry.name.toLowerCase().contains(keyword))
              {
                'key': entry.key,
                'name': entry.name,
                'version': entry.version,
                if (entry.description.isNotEmpty)
                  'description': entry.description,
                'library': entry.libraryName,
                'installed': installed.containsKey(entry.key),
                if (installed[entry.key] case final String version)
                  'installed_version': version,
              },
        ],
        a,
        size: 30,
        maximum: 100,
      ),
      if (failures.isNotEmpty) 'failed_libraries': failures,
    };
  }

  static List<String> _keys(AgentJson a, String name, int maximum) {
    final keys = a[name];
    if (keys is! List ||
        keys.isEmpty ||
        keys.length > maximum ||
        keys.any((k) => k is! String || k.trim().isEmpty)) {
      throw AgentException('INVALID_ARGUMENT', '$name 需要1到$maximum个非空字符串');
    }
    return keys.cast<String>();
  }

  static AgentJson _summary(List<AgentJson> results, Set<String> ok) => {
    'total': results.length,
    'ok': results.where((r) => ok.contains(r['status'])).length,
    'skipped': results.where((r) => r['status'] == 'skipped').length,
    'failed': results.where((r) => r['status'] == 'failed').length,
  };

  Future<AgentJson> _sourceInstall(AgentJson a, AgentToolContext c) async {
    final keys = _keys(a, 'keys', 20);
    await c.run.wait(initializeSources());
    final entries = await _catalog(c);
    final results = <AgentJson>[];
    final seen = <String>{};
    for (final key in keys) {
      c.run.check();
      if (!seen.add(key)) {
        results.add({
          'key': key,
          'status': 'skipped',
          'reason': 'DUPLICATE_IN_BATCH',
        });
        continue;
      }
      if (sources().any((s) => s.key == key)) {
        results.add({
          'key': key,
          'status': 'skipped',
          'reason': 'ALREADY_INSTALLED',
        });
        continue;
      }
      final entry = entries.where((e) => e.key == key).firstOrNull;
      if (entry == null) {
        results.add({
          'key': key,
          'status': 'failed',
          'reason': 'NOT_FOUND',
          'message': '已启用的漫画源仓库中没有这个源',
        });
        continue;
      }
      try {
        final source = await c.run.wait(
          app.installSource(entry),
          timeout: _networkTimeout,
        );
        results.add({
          'key': source.key,
          'name': source.name,
          'version': source.version,
          'status': 'installed',
        });
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        results.add({
          'key': key,
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      } catch (error) {
        results.add({
          'key': key,
          'status': 'failed',
          'reason': 'INSTALL_FAILED',
          'message': '安装失败：$error',
        });
      }
    }
    return {
      'summary': _summary(results, {'installed'}),
      'results': results,
    };
  }

  Future<AgentJson> _sourceUpdate(AgentJson a, AgentToolContext c) async {
    final keys = a.containsKey('source_keys')
        ? _keys(a, 'source_keys', 100)
        : null;
    await c.run.wait(initializeSources());
    final checked = await c.run.wait(
      app.checkSourceUpdates(),
      timeout: _networkTimeout,
    );
    if (checked < 0) {
      throw const AgentException('SOURCE_REQUEST_FAILED', '检查漫画源更新失败，请检查网络');
    }
    final available = app.availableSourceUpdates();
    final results = <AgentJson>[];
    for (final key in keys?.toSet() ?? available.keys) {
      c.run.check();
      final source = sources().where((s) => s.key == key).firstOrNull;
      if (source == null) {
        results.add({
          'key': key,
          'status': 'failed',
          'reason': 'SOURCE_NOT_FOUND',
        });
        continue;
      }
      final version = available[key];
      if (version == null) {
        results.add({
          'key': key,
          'name': source.name,
          'version': source.version,
          'status': 'skipped',
          'reason': 'UP_TO_DATE',
        });
        continue;
      }
      final from = source.version;
      try {
        final updated = await c.run.wait(
          app.updateSource(source),
          timeout: _networkTimeout,
        );
        results.add({
          'key': key,
          'name': source.name,
          if (updated) ...{
            'status': 'updated',
            'from': from,
            'to': version,
          } else ...{
            'status': 'failed',
            'reason': 'UPDATE_FAILED',
          },
        });
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        results.add({
          'key': key,
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      } catch (error) {
        results.add({
          'key': key,
          'status': 'failed',
          'reason': 'UPDATE_FAILED',
          'message': '更新失败：$error',
        });
      }
    }
    return {
      'summary': _summary(results, {'updated'}),
      'results': results,
    };
  }
}
