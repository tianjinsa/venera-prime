import 'dart:async';
import 'dart:ui' show TargetImageSize;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/image_codec.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source.dart';

enum SourceCheckStage { catalog, details, pages, image }

extension SourceCheckStageLabel on SourceCheckStage {
  String get label => switch (this) {
    SourceCheckStage.catalog => 'Comic list'.tl,
    SourceCheckStage.details => 'Comic details'.tl,
    SourceCheckStage.pages => 'Chapter pages'.tl,
    SourceCheckStage.image => 'Comic image'.tl,
  };
}

class SourceCheckResult {
  const SourceCheckResult({
    required this.stage,
    this.error,
    this.comic,
    this.episode,
    this.imageKey,
  });

  final SourceCheckStage stage;
  final String? error;
  final Comic? comic;
  final String? episode;
  final String? imageKey;
  bool get readable => stage == SourceCheckStage.image && error == null;
}

typedef SourceCheckImageLoader =
    Future<void> Function(
      String imageKey,
      String sourceKey,
      String comicId,
      String episode,
    );

/// Exercises the same source callbacks and image processing as the reader.
/// A catalog or a cover alone cannot establish that a comic is readable.
class SourceAvailabilityChecker {
  SourceAvailabilityChecker({
    SourceCheckImageLoader? loadImage,
    this.timeout = const Duration(seconds: 15),
  }) : _loadImage = loadImage ?? _checkImage;

  final SourceCheckImageLoader _loadImage;
  final Duration timeout;

  static Future<void> _checkImage(
    String key,
    String source,
    String cid,
    String eid,
  ) async {
    Uint8List? bytes;
    await for (final event in ImageDownloader.loadComicImageUnwrapped(
      key,
      source,
      cid,
      eid,
      useCache: false,
    )) {
      if (event.imageBytes != null) {
        bytes = event.imageBytes;
        break;
      }
    }
    if (bytes == null) throw StateError('Empty image response');
    await validateImageBytes(bytes);
  }

  static Future<void> validateImageBytes(Uint8List bytes) async {
    if (bytes.isEmpty) throw StateError('Empty image response');
    final codec = await decodeImageBytes(
      bytes,
      getTargetSize: (w, h) {
        return const TargetImageSize(width: 512);
      },
    );
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<List<Comic>> _catalog(ComicSource source) async {
    Object? lastError;
    for (final page in source.explorePages.take(3)) {
      try {
        final comics = await _catalogPage(page).timeout(timeout);
        if (comics.isNotEmpty) return comics;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    throw StateError('No sample comics found. Enter a comic ID to check.');
  }

  Future<List<Comic>> _catalogPage(ExplorePageData page) async {
    if (page.loadPage != null) return (await page.loadPage!(1)).data;
    if (page.loadNext != null) return (await page.loadNext!(null)).data;
    if (page.loadMultiPart != null) {
      return (await page.loadMultiPart!()).data
          .expand((part) => part.comics)
          .toList();
    }
    if (page.loadMixed != null) {
      return (await page.loadMixed!(1)).data.expand<Comic>((part) {
        if (part is ExplorePagePart) return part.comics;
        if (part is List<Comic>) return part;
        return const <Comic>[];
      }).toList();
    }
    return const [];
  }

  // A timeout stops waiting, but source callbacks and image downloads do not
  // expose cancellation here. Do not advertise this check as cancellable.
  Future<SourceCheckResult> check(
    ComicSource source, {
    String? comicId,
    ValueChanged<SourceCheckStage>? onStage,
  }) async {
    var stage = SourceCheckStage.catalog;
    Comic? sample;
    String? episode;
    String? imageKey;
    try {
      onStage?.call(stage);
      final id = comicId?.trim();
      final samples = id != null && id.isNotEmpty
          ? [Comic(id, '', id, null, null, '', source.key, null, null)]
          : await _catalog(source);
      if (source.loadComicInfo == null || source.loadComicPages == null) {
        throw StateError('This source does not support online reading');
      }
      SourceCheckResult? failure;
      // A removed or restricted first title must not condemn the whole source.
      for (final comic in samples.take(3)) {
        sample = comic;
        episode = null;
        imageKey = null;
        try {
          stage = SourceCheckStage.details;
          onStage?.call(stage);
          final Res<ComicDetails> details = await source
              .loadComicInfo!(comic.id)
              .timeout(timeout);
          final info = details.data;
          sample = Comic(
            info.title,
            info.cover,
            comic.id,
            info.subTitle,
            null,
            '',
            source.key,
            info.maxPage,
            null,
          );
          stage = SourceCheckStage.pages;
          onStage?.call(stage);
          episode = info.chapters?.ids.firstOrNull;
          if (info.chapters != null && episode == null) {
            throw StateError('No readable chapters found');
          }
          final pages = await source.loadComicPages!(comic.id, episode).timeout(
            timeout,
          );
          imageKey = pages.data.firstOrNull;
          if (imageKey == null) throw StateError('No comic pages found');
          stage = SourceCheckStage.image;
          onStage?.call(stage);
          await _loadImage(
            imageKey,
            source.key,
            comic.id,
            episode ?? '0',
          ).timeout(timeout);
          return SourceCheckResult(
            stage: stage,
            comic: sample,
            episode: episode,
            imageKey: imageKey,
          );
        } catch (e) {
          final result = SourceCheckResult(
            stage: stage,
            error: e.toString(),
            comic: sample,
            episode: episode,
            imageKey: imageKey,
          );
          if (failure == null || stage.index >= failure.stage.index) {
            failure = result;
          }
        }
      }
      return failure!;
    } catch (e) {
      return SourceCheckResult(
        stage: stage,
        error: e.toString(),
        comic: sample,
        episode: episode,
        imageKey: imageKey,
      );
    }
  }
}

class SourceCheckManager extends ChangeNotifier {
  SourceCheckManager({
    BackgroundTasks? tasks,
    SourceAvailabilityChecker? checker,
  }) : _tasks = tasks ?? BackgroundTasks.instance,
       _checker = checker ?? SourceAvailabilityChecker();

  static final instance = SourceCheckManager();
  final BackgroundTasks _tasks;
  final SourceAvailabilityChecker _checker;
  final _results = <String, SourceCheckResult>{};
  final _checkedSources = <String, ComicSource>{};
  final _activeSources = <String, ComicSource>{};
  final _stages = <String, SourceCheckStage>{};
  final _generations = <String, int>{};

  static String taskKey(String sourceKey) => 'source-readability:$sourceKey';

  SourceCheckStage? stageFor(String key) => _stages[key];

  SourceCheckResult? resultFor(ComicSource source) =>
      identical(_checkedSources[source.key], source)
      ? _results[source.key]
      : null;

  void clear(String key) {
    _results.remove(key);
    _checkedSources.remove(key);
    // Invalidate the result without forgetting the in-flight network work.
    // Removing the running entry would allow another check with the same key.
    _generations[key] = (_generations[key] ?? 0) + 1;
    notifyListeners();
  }

  final _running = <String, Future<SourceCheckResult>>{};

  bool isChecking(String key) => _running.containsKey(key);

  Future<SourceCheckResult> check(ComicSource source, {String? comicId}) {
    final running = _running[source.key];
    if (running != null) {
      if (identical(_activeSources[source.key], source)) return running;
      final generation = _generations[source.key] ?? 0;
      // An updated source needs its own check, after the old one finishes.
      return running.then((result) {
        if ((_generations[source.key] ?? 0) != generation) return result;
        return check(source, comicId: comicId);
      });
    }
    _activeSources[source.key] = source;
    return _running[source.key] = _run(
      source,
      comicId,
      _generations[source.key] ?? 0,
    );
  }

  Future<SourceCheckResult> _run(
    ComicSource source,
    String? comicId,
    int generation,
  ) async {
    // Yield so the active future is registered before listeners rebuild.
    await Future<void>.delayed(Duration.zero);
    notifyListeners();
    final result = await _tasks.run<SourceCheckResult>(
      taskKey(source.key),
      '${"Check readability".tl} · ${source.name}',
      (task) async {
        SourceCheckResult result;
        try {
          result = await _checker.check(
            source,
            comicId: comicId,
            onStage: (stage) {
              _stages[source.key] = stage;
              task.update(message: stage.label);
              notifyListeners();
            },
          );
        } catch (error) {
          result = SourceCheckResult(
            stage: _stages[source.key] ?? SourceCheckStage.catalog,
            error: error.toString(),
          );
        }
        final message = result.readable
            ? 'Readable'.tl
            : 'Check failed at @stage'.tlParams({'stage': result.stage.label});
        task.update(message: message);
        if (!result.readable) task.addError('$message\n${result.error ?? ""}');
        return result;
      },
    );
    if (identical(_activeSources[source.key], source)) {
      if ((_generations[source.key] ?? 0) == generation) {
        _checkedSources[source.key] = source;
        _results[source.key] = result;
      }
      _running.remove(source.key);
      _activeSources.remove(source.key);
      _stages.remove(source.key);
      notifyListeners();
    }
    return result;
  }
}
