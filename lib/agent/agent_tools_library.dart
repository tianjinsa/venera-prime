part of 'agent_tools.dart';

/// Local library, downloads, follow updates, network favorites and pages.
extension _AgentLibraryTools on AgentTools {
  Future<Object?> _dispatchMore(
    String name,
    AgentJson a,
    AgentToolContext c,
  ) async => switch (name) {
    'source_info' => _sourceInfo(a, c),
    'source_categories' => _sourceCategories(a, c),
    'source_catalog' => _sourceCatalog(a, c),
    'source_install' => _sourceInstall(a, c),
    'source_update' => _sourceUpdate(a, c),
    'search_all' => _searchAll(a, c),
    'comic_chapters' => _comicChapters(a, c),
    'comic_status' => _comicStatus(a, c),
    'comic_comments' => _comments(a, c),
    'explore_load' => _exploreLoad(a, c),
    'category_comics' => _categoryComics(a, c),
    'ranking_comics' => _rankingComics(a, c),
    'history_list' => _historyList(a, c),
    'history_remove' => _historyRemove(a, c),
    'local_list' => _localList(a, c),
    'local_delete' => _localDelete(a, c),
    'download_start' => _downloadStart(a, c),
    'download_list' => _downloadList(a, c),
    'download_control' => _downloadControl(a, c),
    'updates_list' => _updatesList(a, c),
    'updates_mark_read' => _updatesMarkRead(a, c),
    'net_fav_folders' => _networkFolders(a, c),
    'net_fav_list' => _networkList(a, c),
    'net_fav_add' || 'net_fav_remove' => _networkWrite(name, a, c),
    'open_comic' => _openComic(a, c),
    'open_page' => _openPage(a, c),
    'blocked_words_list' => _blockedWords(a),
    'blocked_words_update' => _updateBlockedWords(a, c),
    'reading_stats' => _readingStats(a, c),
    _ => throw const AgentException('UNKNOWN_TOOL', '工具不在应用允许的清单中'),
  };

  /// History and download state, when those libraries are open.
  AgentJson _libraryStatus((String, String) ref) {
    final type = AgentTools._type(ref.$1);
    final history = app.historyReady ? app.findHistory(ref.$2, type) : null;
    final local = app.localReady ? app.findLocal(ref.$2, type) : null;
    return {
      if (app.historyReady)
        'history': history == null ? null : _progress(history),
      if (app.localReady) ...{
        'downloaded': local == null
            ? null
            : {
                'chapters': local.downloadedChapters.length,
                'total_chapters': local.chapters?.length,
              },
        'downloading': app.isDownloading(ref.$2, type),
      },
    };
  }

  static AgentJson _progress(History history) => {
    'read_at': history.time.toIso8601String(),
    if (history.group != null) 'group': history.group,
    if (history.ep > 0) 'chapter': history.ep,
    if (history.page > 0) 'page': history.page,
    if (history.maxPage != null) 'max_page': history.maxPage,
    'read_chapters': history.readEpisode.length,
  };

  /// Remember items of the page, so other tools can use them directly.
  void _rememberItems(List<AgentJson> items, AgentToolContext c) {
    for (final item in items) {
      if (item['source_key'] == 'local') continue;
      store.remember(
        c.conversationId,
        AgentComic(
          sourceKey: item['source_key'] as String,
          comicId: item['comic_id'] as String,
          title: item['title'] as String,
          subtitle: item['subtitle'] as String? ?? '',
          cover: item['cover'] as String? ?? '',
        ),
      );
    }
  }

  static bool _matches(String? keyword, Iterable<String?> values) =>
      keyword == null ||
      values.any((v) => v != null && v.toLowerCase().contains(keyword));

  static String? _keyword(AgentJson a) => a.containsKey('keyword')
      ? AgentTools._text(a, 'keyword').toLowerCase()
      : null;

  AgentJson _createFolder(String raw, AgentToolContext c) {
    final folder = raw.trim();
    _validateFolderName(folder);
    if (favorites.existsFolder(folder)) {
      return {'name': folder, 'status': 'skipped', 'reason': 'ALREADY_EXISTS'};
    }
    c.run.check();
    return {'name': favorites.createFolder(folder), 'status': 'created'};
  }

  AgentJson _createFolders(AgentJson a, AgentToolContext c) {
    final names = _AgentCatalogTools._keys(a, 'names', 50);
    final results = <AgentJson>[];
    final seen = <String>{};
    for (final raw in names) {
      final name = raw.trim();
      if (!seen.add(name)) {
        results.add({
          'name': name,
          'status': 'skipped',
          'reason': 'DUPLICATE_IN_BATCH',
        });
        continue;
      }
      try {
        results.add(_createFolder(name, c));
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        results.add({
          'name': name,
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      }
    }
    return {
      'summary': _AgentCatalogTools._summary(results, {'created'}),
      'results': results,
    };
  }

  Future<AgentJson> _renameFolders(AgentJson a, AgentToolContext c) async {
    final renames = a['renames'];
    if (renames is! List ||
        renames.isEmpty ||
        renames.length > 50 ||
        renames.any((r) => r is! Map)) {
      throw const AgentException('INVALID_ARGUMENT', 'renames 需要1到50项');
    }
    final results = <AgentJson>[];
    var settingsChanged = false;
    for (final raw in renames) {
      c.run.check();
      final item = agentObject(raw);
      final row = <String, dynamic>{
        'folder': item['folder'],
        'new_name': item['new_name'],
      };
      results.add(row);
      try {
        final from = _folder(item, 'folder');
        final to = AgentTools._text(item, 'new_name').trim();
        _validateFolderName(to);
        if (from == to) {
          row.addAll({'status': 'skipped', 'reason': 'SAME_NAME'});
          continue;
        }
        if (favorites.existsFolder(to)) {
          row.addAll({'status': 'failed', 'reason': 'FOLDER_EXISTS'});
          continue;
        }
        favorites.rename(from, to);
        // Settings that name the folder follow the rename.
        for (final key in ['followUpdatesFolder', 'quickFavorite']) {
          if (app.setting(key) == from) {
            app.setSetting(key, to);
            settingsChanged = true;
          }
        }
        row.addAll({'status': 'renamed', 'new_name': to});
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        row.addAll({
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      }
    }
    if (settingsChanged) await app.saveSettings();
    return {
      'summary': _AgentCatalogTools._summary(results, {'renamed'}),
      'results': results,
    };
  }

  Future<AgentJson> _historyList(AgentJson a, AgentToolContext c) async {
    await c.run.wait(app.initHistory());
    await c.run.wait(initializeSources().catchError((Object _) {}));
    final keyword = _keyword(a);
    final page = AgentTools._paged(
      [
        for (final history in app.histories())
          if (_matches(keyword, [history.title, history.subtitle]))
            {
              'source_key': _sourceKeyOf(history.type),
              'comic_id': history.id,
              'title': history.title,
              'subtitle': history.subtitle,
              'cover': history.cover,
              ..._progress(history),
            },
      ],
      a,
    );
    final items = (page['items'] as List).cast<AgentJson>();
    _rememberItems(items, c);
    for (final item in items) {
      item.remove('cover');
    }
    return page;
  }

  static AgentJson _historyMap(History history) => {
    'id': history.id,
    'title': history.title,
    'subtitle': history.subtitle,
    'cover': history.cover,
    'time': history.time.millisecondsSinceEpoch,
    'type': history.type.value,
    'ep': history.ep,
    'page': history.page,
    'readEpisode': history.readEpisode.toList(),
    'max_page': history.maxPage,
    'group': history.group,
  };

  static History _historyFromMap(AgentJson map) =>
      History.fromMap(map)..group = map['group'] as int?;

  Future<AgentJson> _historyRemove(AgentJson a, AgentToolContext c) async {
    await c.run.wait(app.initHistory());
    final refs = AgentTools._refs(a).map((r) => _canonicalRef(r, c)).toList();
    final results = <AgentJson>[];
    final removed = <ComicID>[];
    final undo = <AgentJson>[];
    final seen = <String>{};
    for (final ref in refs) {
      final row = AgentTools._identity(ref);
      results.add(row);
      if (!seen.add(jsonEncode([ref.$1, ref.$2]))) {
        row.addAll({'status': 'skipped', 'reason': 'DUPLICATE_IN_BATCH'});
        continue;
      }
      final type = AgentTools._type(ref.$1);
      final history = app.findHistory(ref.$2, type);
      if (history == null) {
        row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
        continue;
      }
      row.addAll({'title': history.title, 'status': 'removed'});
      removed.add(ComicID(type, ref.$2));
      undo.add({'kind': 'history', 'history': _historyMap(history)});
    }
    c.run.check();
    final undoId = agentId();
    if (removed.isNotEmpty) {
      app.removeHistories(removed);
      store.saveUndo(undoId, c.conversationId, undo);
    }
    return {
      'summary': {
        ..._AgentCatalogTools._summary(results, {'removed'}),
        'missing': results.where((r) => r['reason'] == 'NOT_PRESENT').length,
      },
      'results': results,
      if (removed.isNotEmpty) 'undo_id': undoId,
    };
  }

  Future<AgentJson> _localList(AgentJson a, AgentToolContext c) async {
    await c.run.wait(app.initLocal());
    await c.run.wait(initializeSources().catchError((Object _) {}));
    final keyword = _keyword(a);
    final page = AgentTools._paged(
      [
        for (final comic in app.localComics())
          if (_matches(keyword, [comic.title, comic.subtitle, ...comic.tags]))
            {
              'source_key': _sourceKeyOf(comic.comicType),
              'comic_id': comic.id,
              'title': comic.title,
              'subtitle': comic.subtitle,
              'downloaded_chapters': comic.downloadedChapters.length,
              'total_chapters': comic.chapters?.length,
              'added_at': comic.createdAt.toIso8601String(),
            },
      ],
      a,
    );
    _rememberItems((page['items'] as List).cast<AgentJson>(), c);
    return page;
  }

  Future<AgentJson> _localDelete(AgentJson a, AgentToolContext c) async {
    await c.run.wait(app.initLocal());
    final refs = AgentTools._refs(a).map((r) => _canonicalRef(r, c)).toList();
    final results = <AgentJson>[];
    final seen = <String>{};
    for (final ref in refs) {
      c.run.check();
      final row = AgentTools._identity(ref);
      results.add(row);
      if (!seen.add(jsonEncode([ref.$1, ref.$2]))) {
        row.addAll({'status': 'skipped', 'reason': 'DUPLICATE_IN_BATCH'});
        continue;
      }
      final type = AgentTools._type(ref.$1);
      final comic = app.findLocal(ref.$2, type);
      if (comic == null) {
        row.addAll({'status': 'skipped', 'reason': 'NOT_PRESENT'});
        continue;
      }
      row['title'] = comic.title;
      if (app.isDownloading(ref.$2, type)) {
        row.addAll({
          'status': 'skipped',
          'reason': 'DOWNLOADING',
          'message': '正在下载，请先取消下载任务',
        });
        continue;
      }
      try {
        app.deleteLocal(comic);
        row['status'] = 'deleted';
      } catch (_) {
        row.addAll({'status': 'failed', 'reason': 'WRITE_FAILED'});
      }
    }
    return {
      'summary': _AgentCatalogTools._summary(results, {'deleted'}),
      'results': results,
    };
  }

  Future<AgentJson> _downloadStart(AgentJson a, AgentToolContext c) async {
    final raw = a['comics'];
    if (raw is! List || raw.isEmpty || raw.length > 20) {
      throw const AgentException('BATCH_TOO_LARGE', 'comics 需要1到20项');
    }
    final requests = <(String, String, List<String>?)>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const AgentException('INVALID_ARGUMENT', 'comics 每项需要对象');
      }
      final value = agentObject(item);
      final chapters = value['chapters'];
      if (chapters != null &&
          (chapters is! List ||
              chapters.isEmpty ||
              chapters.any((id) => id is! String))) {
        throw const AgentException('INVALID_ARGUMENT', 'chapters 需要章节 ID 数组');
      }
      requests.add((
        AgentTools._text(value, 'source_key'),
        AgentTools._text(value, 'comic_id'),
        chapters == null ? null : List<String>.from(chapters as List),
      ));
    }
    await c.run.wait(app.initLocal());
    final results = <AgentJson>[];
    final seen = <String>{};
    for (final (sourceKey, id, chapters) in requests) {
      c.run.check();
      final row = <String, dynamic>{'source_key': sourceKey, 'comic_id': id};
      results.add(row);
      try {
        final source = await _source(sourceKey, c);
        final details = await _cachedDetails(source, id, c);
        row.addAll({'comic_id': details.comicId, 'title': details.title});
        final type = AgentTools._type(source.key);
        if (!seen.add(jsonEncode([source.key, details.comicId]))) {
          row.addAll({'status': 'skipped', 'reason': 'DUPLICATE_IN_BATCH'});
          continue;
        }
        if (app.isDownloading(details.comicId, type)) {
          row.addAll({'status': 'skipped', 'reason': 'ALREADY_QUEUED'});
          continue;
        }
        if (source.loadComicPages == null) {
          throw const AgentException('NO_DOWNLOAD_SUPPORT', '该源不支持下载');
        }
        final local = app.findLocal(details.comicId, type);
        final all = details.chapters?.ids.toList();
        List<String>? pending;
        if (all == null) {
          if (local != null) {
            row.addAll({'status': 'skipped', 'reason': 'ALREADY_DOWNLOADED'});
            continue;
          }
        } else {
          final unknown = chapters?.where((ch) => !all.contains(ch)).toList();
          if (unknown != null && unknown.isNotEmpty) {
            throw AgentException(
              'INVALID_CHAPTER',
              '章节 ID 不存在：${unknown.take(10).join('、')}',
            );
          }
          final done = local?.downloadedChapters.toSet() ?? const <String>{};
          pending = (chapters ?? all).where((ch) => !done.contains(ch)).toList();
          if (pending.isEmpty) {
            row.addAll({'status': 'skipped', 'reason': 'ALREADY_DOWNLOADED'});
            continue;
          }
          // A first download of every chapter uses the app's own default.
          if (chapters == null && done.isEmpty) pending = null;
        }
        app.download(source, details, pending);
        row.addAll({
          'status': 'queued',
          'chapters': pending?.length ?? all?.length ?? 1,
        });
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        row.addAll({
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      }
    }
    return {
      'summary': _AgentCatalogTools._summary(results, {'queued'}),
      'results': results,
    };
  }

  Future<AgentJson> _downloadList(AgentJson a, AgentToolContext c) async {
    await c.run.wait(app.initLocal());
    final tasks = app.downloads();
    return AgentTools._paged([
      for (var i = 0; i < tasks.length; i++)
        {
          'position': i + 1,
          'source_key': tasks[i].sourceKey,
          'comic_id': tasks[i].comicId,
          'title': tasks[i].title,
          'progress': (tasks[i].progress * 100).round(),
          'status': tasks[i].failed
              ? 'failed'
              : tasks[i].paused
              ? 'paused'
              : i == 0
              ? 'downloading'
              : 'queued',
          if (tasks[i].message.isNotEmpty) 'message': tasks[i].message,
        },
    ], a);
  }

  Future<AgentJson> _downloadControl(AgentJson a, AgentToolContext c) async {
    final action = AgentTools._text(a, 'action');
    const actions = ['pause', 'resume', 'retry', 'prioritize', 'cancel'];
    if (!actions.contains(action)) {
      throw AgentException('INVALID_ARGUMENT', 'action 可用值：${actions.join('、')}');
    }
    await c.run.wait(app.initLocal());
    final results = <AgentJson>[];
    for (final ref in AgentTools._refs(a).map((r) => _canonicalRef(r, c))) {
      c.run.check();
      final applied = app.controlDownload(
        ref.$2,
        AgentTools._type(ref.$1),
        action,
      );
      results.add({
        ...AgentTools._identity(ref),
        if (applied)
          'status': 'done'
        else ...{'status': 'skipped', 'reason': 'NOT_APPLICABLE'},
      });
    }
    return {
      'action': action,
      'summary': _AgentCatalogTools._summary(results, {'done'}),
      'results': results,
    };
  }

  String _followedFolder() {
    final folder = app.followedFolder();
    if (folder == null || !favorites.existsFolder(folder)) {
      throw const AgentException(
        'NO_FOLLOW_FOLDER',
        '尚未设置追更收藏夹，请在应用的追更页面选择收藏夹',
      );
    }
    return folder;
  }

  Future<AgentJson> _updatesList(AgentJson a, AgentToolContext c) async {
    final folder = _followedFolder();
    final refresh = a['refresh'] ?? false;
    if (refresh is! bool) {
      throw const AgentException('INVALID_ARGUMENT', 'refresh 需要布尔值');
    }
    AgentJson? checked;
    if (refresh) {
      var last = UpdateProgress(0, 0, 0, 0);
      final failures = <String>[];
      final events = StreamIterator(app.checkUpdates(folder));
      try {
        // Each comic is checked separately; only a stalled check times out.
        while (await c.run.wait(
          events.moveNext(),
          timeout: const Duration(minutes: 2),
        )) {
          last = events.current;
          final message = last.errorMessage;
          if (message != null && failures.length < 10) {
            failures.add('${last.comic?.name ?? ''}：$message');
          }
        }
      } finally {
        await events.cancel();
      }
      checked = {
        'checked': last.current,
        'updated': last.updated,
        'errors': last.errors,
        if (failures.isNotEmpty) 'error_samples': failures,
      };
    }
    await c.run.wait(initializeSources().catchError((Object _) {}));
    final page = AgentTools._paged([
      for (final update in app.updates(folder))
        {
          'source_key': _sourceKeyOf(update.comic.type),
          'comic_id': update.comic.id,
          'title': update.comic.name,
          'subtitle': update.comic.author,
          'cover': update.comic.coverPath,
          'update_time': update.updateTime?.split('|').first,
        },
    ], a);
    final items = (page['items'] as List).cast<AgentJson>();
    _rememberItems(items, c);
    for (final item in items) {
      item.remove('cover');
    }
    return {'folder': folder, 'refresh': ?checked, ...page};
  }

  Future<AgentJson> _updatesMarkRead(AgentJson a, AgentToolContext c) async {
    final folder = _followedFolder();
    final results = <AgentJson>[];
    for (final ref in AgentTools._refs(a).map((r) => _canonicalRef(r, c))) {
      final type = AgentTools._type(ref.$1);
      final present = favorites.comicExists(folder, ref.$2, type);
      if (present) app.markUpdateRead(ref.$2, type);
      results.add({
        ...AgentTools._identity(ref),
        if (present)
          'status': 'marked'
        else ...{'status': 'skipped', 'reason': 'NOT_PRESENT'},
      });
    }
    return {
      'folder': folder,
      'summary': _AgentCatalogTools._summary(results, {'marked'}),
      'results': results,
    };
  }

  Future<(ComicSource, FavoriteData)> _networkFavorites(
    AgentJson a,
    AgentToolContext c,
  ) async {
    final source = await _source(AgentTools._text(a, 'source_key'), c);
    final data =
        source.favoriteData ??
        (throw const AgentException('NO_NETWORK_FAVORITES', '该源不提供网络收藏'));
    if (!source.isLogged) {
      throw const AgentException('NOT_LOGGED_IN', '该源尚未登录，请先在应用中登录');
    }
    return (source, data);
  }

  Future<AgentJson> _networkFolders(AgentJson a, AgentToolContext c) async {
    final (source, data) = await _networkFavorites(a, c);
    final comic = a.containsKey('comic_id')
        ? AgentTools._text(a, 'comic_id')
        : null;
    if (!data.multiFolder || data.loadFolders == null) {
      return {'source_key': source.key, 'multi_folder': false, 'folders': []};
    }
    final Res<Map<String, String>> result;
    try {
      result = await c.run.wait(
        data.loadFolders!(comic),
        timeout: sourceTimeout,
      );
    } on AgentException {
      rethrow;
    } catch (error) {
      throw AgentException('SOURCE_REQUEST_FAILED', '读取网络收藏夹失败：$error');
    }
    if (result.error) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取网络收藏夹失败：${result.errorMessage ?? ''}',
      );
    }
    return {
      'source_key': source.key,
      'multi_folder': true,
      'all_favorites_id': data.allFavoritesId,
      'folders': [
        for (final entry in result.data.entries)
          {'id': entry.key, 'name': entry.value},
      ],
      if (comic != null && result.subData is List)
        'comic_folders': List<String>.from(
          (result.subData as List).map((v) => v.toString()),
        ),
    };
  }

  Future<AgentJson> _networkList(AgentJson a, AgentToolContext c) async {
    final (source, data) = await _networkFavorites(a, c);
    final folder = a.containsKey('folder')
        ? AgentTools._text(a, 'folder')
        : data.multiFolder
        ? data.allFavoritesId
        : null;
    if (data.multiFolder && folder == null) {
      throw const AgentException(
        'FOLDER_REQUIRED',
        '该源有多个收藏夹，请先用 net_fav_folders 选择 folder',
      );
    }
    final cursor = data.loadComic == null;
    if (cursor && data.loadNext == null) {
      throw const AgentException('NO_NETWORK_FAVORITES', '该源不提供网络收藏列表');
    }
    final (page, next) = _pageOrCursor(a, cursor: cursor);
    // Account data is read fresh: it changes whenever favorites are edited.
    final Res<List<Comic>> result;
    try {
      result = await c.run.wait(
        cursor ? data.loadNext!(next, folder) : data.loadComic!(page, folder),
        timeout: sourceTimeout,
      );
    } on AgentException {
      rethrow;
    } catch (error) {
      throw AgentException('SOURCE_REQUEST_FAILED', '读取网络收藏失败：$error');
    }
    if (result.error) {
      throw AgentException(
        'SOURCE_REQUEST_FAILED',
        '读取网络收藏失败：${result.errorMessage ?? ''}',
      );
    }
    for (final comic in result.data) {
      if (comic.favoriteId case final String id) {
        _networkFavoriteIds[jsonEncode([source.key, comic.id])] = id;
      }
    }
    return {
      'source_key': source.key,
      'folder': ?folder,
      ..._comicPage(result, c, cursor: cursor, page: page, current: next),
    };
  }

  Future<AgentJson> _networkWrite(
    String name,
    AgentJson a,
    AgentToolContext c,
  ) async {
    final adding = name == 'net_fav_add';
    final ids = _AgentCatalogTools._keys(a, 'comic_ids', 20);
    final (source, data) = await _networkFavorites(a, c);
    final change =
        data.addOrDelFavorite ??
        (throw const AgentException('NO_NETWORK_FAVORITES', '该源不支持修改网络收藏'));
    final folder = a.containsKey('folder')
        ? AgentTools._text(a, 'folder')
        : null;
    if (adding && data.multiFolder && folder == null) {
      throw const AgentException(
        'FOLDER_REQUIRED',
        '该源有多个收藏夹，请先用 net_fav_folders 选择 folder',
      );
    }
    final results = <AgentJson>[];
    for (final id in ids.toSet()) {
      c.run.check();
      final row = <String, dynamic>{'source_key': source.key, 'comic_id': id};
      if (store.seen(c.conversationId, source.key, id)?.title
          case final String title) {
        row['title'] = title;
      }
      results.add(row);
      final favoriteId = _networkFavoriteIds[jsonEncode([source.key, id])];
      try {
        final result = await c.run.wait(
          change(id, folder ?? '', adding, favoriteId),
          timeout: sourceTimeout,
        );
        if (result.error || result.data == false) {
          row.addAll({
            'status': 'failed',
            'reason': 'SOURCE_REQUEST_FAILED',
            'message': result.errorMessage ?? '源未确认修改',
          });
        } else {
          row['status'] = adding ? 'added' : 'removed';
        }
      } on AgentException catch (e) {
        if (e.code == 'CANCELLED') rethrow;
        row.addAll({
          'status': 'failed',
          'reason': e.code,
          'message': e.message,
        });
      } catch (error) {
        row.addAll({
          'status': 'failed',
          'reason': 'SOURCE_REQUEST_FAILED',
          'message': '$error',
        });
      }
    }
    return {
      'folder': ?folder,
      'summary': _AgentCatalogTools._summary(results, {'added', 'removed'}),
      'results': results,
    };
  }

  static int? _optionalIndex(AgentJson a, String key) =>
      a.containsKey(key) ? AgentTools._number(a, key, 1, 1000000) : null;

  Future<AgentJson> _openComic(AgentJson a, AgentToolContext c) async {
    final sourceKey = AgentTools._text(a, 'source_key');
    final id = AgentTools._text(a, 'comic_id');
    final read = a['read'] ?? false;
    if (read is! bool) {
      throw const AgentException('INVALID_ARGUMENT', 'read 需要布尔值');
    }
    final chapter = _optionalIndex(a, 'chapter');
    final group = _optionalIndex(a, 'group');
    final page = _optionalIndex(a, 'page');
    if (sourceKey == 'local') {
      await c.run.wait(app.initLocal());
      final comic =
          app.findLocal(id, ComicType.local) ??
          (throw const AgentException('NOT_FOUND', '没有这本本地漫画'));
      app.openLocalReader(comic);
      return {'opened': 'reader', 'title': comic.title};
    }
    final source = await _source(sourceKey, c);
    final canonical = store.seen(c.conversationId, source.key, id);
    final comicId = canonical?.comicId ?? id;
    if (!read) {
      app.openComic(
        source.key,
        comicId,
        title: canonical?.title,
        cover: canonical?.cover,
      );
      return {
        'opened': 'details',
        'source_key': source.key,
        'comic_id': comicId,
        'title': ?canonical?.title,
      };
    }
    if (chapter == null && page == null && app.localReady) {
      // A downloaded comic continues from history without the network.
      final local = app.findLocal(comicId, AgentTools._type(source.key));
      if (local != null) {
        app.openLocalReader(local);
        return {'opened': 'reader', 'title': local.title, 'offline': true};
      }
    }
    final details = await _cachedDetails(source, comicId, c);
    final chapters = details.chapters;
    if (chapter != null && chapters != null) {
      final count = chapters.isGrouped
          ? group == null || group > chapters.groupCount
                ? 0
                : chapters.getGroupByIndex(group - 1).length
          : chapters.length;
      if (chapter > count) {
        throw AgentException(
          'INVALID_CHAPTER',
          chapters.isGrouped ? '分组漫画需要有效的 group 和组内 chapter' : '章节超出范围，共 $count 章',
        );
      }
    }
    app.openReader(details, chapter: chapter, page: page, group: group);
    return {
      'opened': 'reader',
      'source_key': details.sourceKey,
      'comic_id': details.comicId,
      'title': details.title,
      'chapter': ?chapter,
      'group': ?group,
      'page': ?page,
    };
  }

  Future<AgentJson> _openPage(AgentJson a, AgentToolContext c) async {
    final page = AgentTools._text(a, 'page');
    final fixed = AgentAppPage.values.where((p) => p.id == page).firstOrNull;
    if (fixed != null) {
      app.openPage(fixed);
      return {'opened': page, 'label': fixed.label};
    }
    switch (page) {
      case 'search':
        final keyword = AgentTools._text(a, 'keyword');
        String? sourceKey;
        if (a.containsKey('source_key')) {
          final source = await _source(AgentTools._text(a, 'source_key'), c);
          if (source.searchPageData == null) {
            throw const AgentException('NO_SEARCH_SUPPORT', '该源不支持搜索');
          }
          sourceKey = source.key;
        }
        app.openSearch(keyword, sourceKey: sourceKey);
        return {'opened': page, 'keyword': keyword, 'source_key': ?sourceKey};
      case 'category' || 'ranking':
        final source = await _source(AgentTools._text(a, 'source_key'), c);
        final key =
            source.categoryData?.key ??
            (throw const AgentException('NO_CATEGORY_SUPPORT', '该源不提供分类'));
        if (page == 'ranking') {
          if (source.categoryComicsData?.rankingData == null) {
            throw const AgentException('NO_RANKING_SUPPORT', '该源不提供排行榜');
          }
          app.openRanking(key);
          return {'opened': page, 'source_key': source.key};
        }
        final category = AgentTools._text(a, 'category');
        final param = a.containsKey('param')
            ? AgentTools._text(a, 'param')
            : null;
        app.openCategory(key, category, param: param);
        return {
          'opened': page,
          'source_key': source.key,
          'category': category,
          'param': ?param,
        };
      default:
        throw const AgentException('INVALID_ARGUMENT', '不支持打开这个页面');
    }
  }

  static String _blockedKey(AgentJson a) {
    final scope = a['scope'] ?? 'comic';
    if (scope != 'comic' && scope != 'comment') {
      throw const AgentException('INVALID_ARGUMENT', 'scope 只能为 comic 或 comment');
    }
    return scope == 'comic' ? 'blockedWords' : 'blockedCommentWords';
  }

  List<String> _blockedList(String key) => [
    for (final word in app.setting(key) as List? ?? const [])
      if (word is String) word,
  ];

  AgentJson _blockedWords(AgentJson a) {
    final key = _blockedKey(a);
    return {
      'scope': a['scope'] ?? 'comic',
      ...AgentTools._paged(
        [
          for (final word in _blockedList(key)) {'word': word},
        ],
        a,
        size: 500,
        maximum: 500,
      ),
    };
  }

  Future<AgentJson> _updateBlockedWords(
    AgentJson a,
    AgentToolContext c,
  ) async {
    final key = _blockedKey(a);
    List<String> words(String name) {
      final value = a[name] ?? const [];
      if (value is! List ||
          value.any((w) => w is! String || w.trim().isEmpty || w.length > 200)) {
        throw AgentException('INVALID_ARGUMENT', '$name 需要非空关键词数组');
      }
      return [for (final w in value) (w as String).trim()];
    }

    final add = words('add');
    final remove = words('remove');
    if (add.isEmpty && remove.isEmpty) {
      throw const AgentException('INVALID_ARGUMENT', '请提供 add 或 remove');
    }
    final current = _blockedList(key);
    final results = <AgentJson>[];
    for (final word in add) {
      if (current.contains(word)) {
        results.add({'word': word, 'status': 'skipped', 'reason': 'ALREADY_EXISTS'});
      } else {
        current.add(word);
        results.add({'word': word, 'status': 'added'});
      }
    }
    for (final word in remove) {
      if (current.remove(word)) {
        results.add({'word': word, 'status': 'removed'});
      } else {
        results.add({'word': word, 'status': 'skipped', 'reason': 'NOT_PRESENT'});
      }
    }
    c.run.check();
    app.setSetting(key, current);
    await app.saveSettings();
    return {
      'scope': a['scope'] ?? 'comic',
      'summary': _AgentCatalogTools._summary(results, {'added', 'removed'}),
      'results': results,
      'count': current.length,
    };
  }

  Future<AgentJson> _readingStats(AgentJson a, AgentToolContext c) async {
    final days = AgentTools._number(a, 'days', 7, 365);
    await c.run.wait(app.initStatistics());
    await c.run.wait(initializeSources().catchError((Object _) {}));
    final records = app.readingStatistics(days);
    final daily = SplayTreeMap<String, int>();
    final comics = <String, AgentJson>{};
    for (final record in records) {
      daily.update(
        record.day,
        (v) => v + record.durationSeconds,
        ifAbsent: () => record.durationSeconds,
      );
      final key = '${record.comicType.value}:${record.comicId}';
      final comic = comics.putIfAbsent(
        key,
        () => {
          'source_key': _sourceKeyOf(record.comicType),
          'comic_id': record.comicId,
          'title': record.title,
          'seconds': 0,
        },
      );
      comic['seconds'] = (comic['seconds'] as int) + record.durationSeconds;
    }
    final top = comics.values.toList()
      ..sort((a, b) => (b['seconds'] as int).compareTo(a['seconds'] as int));
    return {
      'days': days,
      'total_seconds': daily.values.fold<int>(0, (a, b) => a + b),
      'all_time_seconds': app.readingSeconds(),
      'daily': [
        for (final entry in daily.entries)
          {'day': entry.key, 'seconds': entry.value},
      ],
      'top_comics': top.take(10).toList(),
    };
  }
}
