import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  String folder, {
  bool Function()? shouldCancel,
  bool markNewUpdates = true,
}) async {
  int retries = 3;
  while (true) {
    try {
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return ComicUpdateResult(false, "Comic source not found");
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author:
            newInfo.subTitle ?? newInfo.tags['author']?.firstOrNull ?? c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updateTime = newInfo.findUpdateTime();
      // MangaDex used to expose the manga metadata timestamp. The bundled
      // source now exposes a chapter marker instead; migrate that value
      // without reporting a phantom update for existing favorites.
      var isMangaDexMarkerMigration =
          c.type.sourceKey == "manga_dex" &&
          c.updateTime != null &&
          DateTime.tryParse(c.updateTime!) != null &&
          updateTime?.contains("|") == true;
      final updated = LocalFavoritesManager().updateUpdateTime(
        folder,
        c.id,
        c.type,
        updateTime,
        // Only the first check establishes a silent baseline. Revisiting a
        // tracked folder must still report chapters added while it was away.
        markNewUpdate:
            (markNewUpdates || c.lastCheckTime != null) &&
            !isMangaDexMarkerMigration,
        chapterIds: newInfo.chapters?.ids.toList(),
      );
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);
      Log.error("Check Updates", e, s);
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        return ComicUpdateResult(false, e.toString());
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
}

Future<void> updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime, {
  required bool Function() shouldCancel,
  bool markNewUpdates = true,
}) async {
  try {
    var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
    int total = comics.length;
    int current = 0;
    int errors = 0;
    int updated = 0;

    stream.add(UpdateProgress(total, current, errors, updated));

    var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];
    var checkIntervalValue =
        appdata.settings['followUpdatesCheckIntervalHours'];
    var checkIntervalHours = checkIntervalValue is num
        ? checkIntervalValue.toInt()
        : 24;
    if (checkIntervalHours < 1) {
      checkIntervalHours = 1;
    }
    var checkInterval = Duration(hours: checkIntervalHours);

    for (var comic in comics) {
      if (!ignoreCheckTime) {
        var lastCheckTime = comic.lastCheckTime;
        if (lastCheckTime != null &&
            DateTime.now().difference(lastCheckTime) < checkInterval) {
          current++;
          stream.add(UpdateProgress(total, current, errors, updated));
          continue;
        }
      }
      comicsToUpdate.add(comic);
    }

    total = comicsToUpdate.length;
    current = 0;
    stream.add(UpdateProgress(total, current, errors, updated));

    var channel = Channel<FavoriteItemWithUpdateInfo>(10);

    // Producer
    () async {
      var c = 0;
      for (var comic in comicsToUpdate) {
        if (shouldCancel()) break;
        await channel.push(comic);
        c++;
        // Throttle
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    // Consumers
    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var comic = await channel.pop();
          if (comic == null) {
            break;
          }
          final result = await updateComic(
            comic,
            folder,
            shouldCancel: shouldCancel,
            markNewUpdates: markNewUpdates,
          );
          current++;
          if (result.updated) {
            updated++;
          }
          if (result.errorMessage != null) {
            errors++;
          }
          stream.add(
            UpdateProgress(
              total,
              current,
              errors,
              updated,
              comic,
              result.errorMessage,
            ),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    if (updated > 0) {
      LocalFavoritesManager().notifyChanges();
    }
  } catch (e, s) {
    if (!shouldCancel()) stream.addError(e, s);
  } finally {
    await stream.close();
  }
}

final _activeFolderChecks = <String, void Function()>{};

Stream<UpdateProgress> updateFolder(
  String folder,
  bool ignoreCheckTime, {
  bool Function()? shouldCancel,
  bool markNewUpdates = true,
}) {
  if (shouldCancel?.call() == true) return const Stream<UpdateProgress>.empty();
  _activeFolderChecks[folder]?.call();
  var canceled = false;
  void cancel() {
    canceled = true;
  }

  _activeFolderChecks[folder] = cancel;
  final stream = StreamController<UpdateProgress>(onCancel: cancel);
  unawaited(
    updateFolderBase(
      folder,
      stream,
      ignoreCheckTime,
      shouldCancel: () => canceled || shouldCancel?.call() == true,
      markNewUpdates: markNewUpdates,
    ).whenComplete(() {
      if (identical(_activeFolderChecks[folder], cancel)) {
        _activeFolderChecks.remove(folder);
      }
    }),
  );
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'type': c.type.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
