import 'dart:async' show Completer, Future;
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  HistoryImageProvider(this.history)
    : _key = "history${history.id}${history.type.value}${history.cover}";

  final History history;

  final String _key;

  static final _refreshing = <String, Future<String>>{};
  static final _recoveryAt = <String, DateTime>{};
  static final _refreshWaiters = Queue<Completer<void>>();
  static int _activeRefreshes = 0;

  @override
  int get maxLoadAttempts => 1;

  Future<Uint8List> _loadThumbnail(String url, chunkEvents, checkStop) async {
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
      checkStop,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  String? _findFavoriteCover() {
    try {
      var folders = LocalFavoritesManager().find(history.id, history.type);
      if (folders.isEmpty) {
        return null;
      }
      return LocalFavoritesManager()
          .getComic(folders.first, history.id, history.type)
          .coverPath;
    } catch (_) {
      return null;
    }
  }

  Future<String> _refreshCoverFromSource() {
    final key = '${history.type.value}:${history.id}';
    final pending = _refreshing[key];
    if (pending != null) return pending;
    final now = DateTime.now();
    final lastAttempt = _recoveryAt[key];
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(minutes: 1)) {
      return Future.value(history.cover);
    }
    _recoveryAt[key] = now;
    while (_recoveryAt.length > 256) {
      _recoveryAt.remove(_recoveryAt.keys.first);
    }
    final result = Future<String>.microtask(_fetchCoverFromSource).whenComplete(
      () {
        _refreshing.remove(key);
      },
    );
    _refreshing[key] = result;
    return result;
  }

  Future<String> _fetchCoverFromSource() async {
    if (_activeRefreshes >= 2) {
      final waiter = Completer<void>();
      _refreshWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeRefreshes++;
    }
    try {
      return await _requestCoverFromSource();
    } finally {
      if (_refreshWaiters.isNotEmpty) {
        _refreshWaiters.removeFirst().complete();
      } else {
        _activeRefreshes--;
      }
    }
  }

  Future<String> _requestCoverFromSource() async {
    var comicSource =
        history.type.comicSource ?? (throw "Comic source not found.");
    var comic = await comicSource.loadComicInfo!(history.id);
    if (comic.error) {
      throw comic.errorMessage ?? "Failed to load comic info";
    }
    final title = comic.data.title;
    final subtitle = comic.data.subTitle ?? '';
    final cover = comic.data.cover;
    if (history.title != title ||
        history.subtitle != subtitle ||
        history.cover != cover) {
      history.title = title;
      history.subtitle = subtitle;
      history.cover = cover;
      HistoryManager().addHistory(history);
    }
    return cover;
  }

  void _saveCover(String cover) {
    if (cover.isEmpty || cover == history.cover) {
      return;
    }
    history.cover = cover;
    HistoryManager().addHistory(history);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
    }

    Object? lastError;
    var tried = <String>{};

    Future<Uint8List?> tryLoad(String? cover, {bool saveCover = false}) async {
      cover = cover?.trim();
      if (cover == null || cover.isEmpty || tried.contains(cover)) {
        return null;
      }
      tried.add(cover);
      checkStop();
      try {
        var data = await _loadThumbnail(cover, chunkEvents, checkStop);
        if (saveCover) {
          _saveCover(cover);
        }
        return data;
      } catch (e) {
        checkStop();
        lastError = e;
        return null;
      }
    }

    if (url.contains('/')) {
      var data = await tryLoad(url);
      if (data != null) {
        // Browsing history must not turn every usable cover (including disk
        // cache hits) into a detail request and a history database update.
        // Recover invalid covers below; metadata can be refreshed explicitly.
        return data;
      }
    }

    var data = await tryLoad(_findFavoriteCover(), saveCover: true);
    if (data != null) {
      return data;
    }

    try {
      checkStop();
      data = await tryLoad(await _refreshCoverFromSource());
      if (data != null) {
        return data;
      }
    } catch (e) {
      checkStop();
      lastError = e;
    }

    data = await tryLoad(url);
    if (data != null) {
      return data;
    }

    throw lastError ?? "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => _key;
}
