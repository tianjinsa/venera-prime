part of 'favorites_page.dart';

Future<bool> importFavoriteFolder() async {
  try {
    final file = await selectFile(ext: ['json']);
    if (file == null) return false;
    LocalFavoritesManager().fromJson(utf8.decode(await file.readAsBytes()));
    return true;
  } catch (error, stack) {
    Log.error('Import favorites', error, stack);
    App.rootContext.showMessage(message: 'Failed to import'.tl);
    return false;
  }
}

Future<void> exportFavoriteFolder([String? folder]) async {
  folder ??= await showDialog<String>(
    context: App.rootContext,
    builder: (context) => SimpleDialog(
      title: Text('Select a folder'.tl),
      children: [
        for (final name in LocalFavoritesManager().folderNames)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(name),
            child: Text(name),
          ),
      ],
    ),
  );
  if (folder == null) return;
  try {
    final json = LocalFavoritesManager().folderToJson(folder);
    await saveFile(
      data: utf8.encode(json),
      filename: '${folder.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.json',
    );
  } catch (error, stack) {
    Log.error('Export favorites', error, stack);
    App.rootContext.showMessage(message: 'Failed to export'.tl);
  }
}

/// Open a dialog to create a new favorite folder.
Future<void> newFolder() async {
  return showDialog(
      context: App.rootContext,
      builder: (context) {
        var controller = TextEditingController();
        String? error;

        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "New Folder".tl,
            content: Column(
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "Folder Name".tl,
                    errorText: error,
                  ),
                  onChanged: (s) {
                    if (error != null) {
                      setState(() {
                        error = null;
                      });
                    }
                  },
                ),
              ],
            ).paddingHorizontal(16),
            actions: [
              TextButton(
                child: Text("Import from file".tl),
                onPressed: () async {
                  if (await importFavoriteFolder() && context.mounted) {
                    context.pop();
                  }
                },
              ).paddingRight(4),
              FilledButton(
                onPressed: () {
                  var e = validateFolderName(controller.text);
                  if (e != null) {
                    setState(() {
                      error = e;
                    });
                  } else {
                    LocalFavoritesManager().createFolder(controller.text);
                    context.pop();
                  }
                },
                child: Text("Create".tl),
              ),
            ],
          );
        });
      });
}

String? validateFolderName(String newFolderName) {
  var folders = LocalFavoritesManager().folderNames;
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.contains(newFolderName)) {
    return "Folder already exists".tl;
  }
  return null;
}

void addFavorite(List<Comic> comics) {
  var folders = LocalFavoritesManager().folderNames;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      String? selectedFolder = appdata.settings['quickFavorite'];

      return StatefulBuilder(builder: (context, setState) {
        return ContentDialog(
          title: "Select a folder".tl,
          content: ListTile(
            title: Text("Folder".tl),
            trailing: Select(
              current: selectedFolder,
              values: folders,
              minWidth: 112,
              onTap: (v) {
                setState(() {
                  selectedFolder = folders[v];
                });
              },
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                if (selectedFolder != null) {
                  for (var comic in comics) {
                    LocalFavoritesManager().addComic(
                      selectedFolder!,
                      FavoriteItem(
                        id: comic.id,
                        name: comic.title,
                        coverPath: comic.cover,
                        author: comic.subtitle ?? '',
                        type: ComicType((comic.sourceKey == 'local'
                            ? 0
                            : comic.sourceKey.hashCode)),
                        tags: comic.tags ?? [],
                      ),
                    );
                  }
                  context.pop();
                }
              },
              child: Text("Confirm".tl),
            ),
          ],
        );
      });
    },
  );
}

String favoriteInfoTaskKey(String? folder) =>
    'favorite-info:${folder == null ? 'all' : jsonEncode(folder)}';

Future<List<FavoriteItem>> updateComicsInfo(String? folder) {
  final tasks = BackgroundTasks.instance;
  final key = favoriteInfoTaskKey(folder);
  final result = tasks.run<List<FavoriteItem>>(key, "Update Comics Info".tl, (
    task,
  ) async {
    final manager = LocalFavoritesManager();
    final folders = folder == null ? manager.folderNames.toList() : [folder];
    final memberships = <FavoriteItem, List<String>>{};
    for (final name in folders) {
      if (!manager.existsFolder(name)) continue;
      for (final comic in manager.getFolderComics(name)) {
        memberships.putIfAbsent(comic, () => []).add(name);
      }
    }
    final comics = memberships.keys.toList();
    var completed = 0;
      task.update(
        completed: 0,
        total: comics.length,
        message: folder ?? 'All'.tl,
      );

    Future<void> updateSingleComic(int index) async {
      final comic = comics[index];
      if (comic.type == ComicType.local) return;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (task.cancelRequested) return;
        try {
          final source = comic.type.comicSource;
          if (source?.loadComicInfo == null) {
            throw StateError('Comic source is unavailable');
          }
          final newInfo = (await source!.loadComicInfo!(comic.id)).data;
          if (task.cancelRequested) return;
          final newTags = <String>[];
          for (final entry in newInfo.tags.entries) {
            if (['author', 'artist', 'time'].contains(entry.key.toLowerCase())) {
              continue;
            }
            for (final tag in entry.value) {
              newTags.add('${entry.key}:$tag');
            }
          }
          final updated = FavoriteItem(
            id: comic.id,
            name: newInfo.title,
            coverPath: newInfo.cover,
            author:
                newInfo.subTitle ??
                newInfo.tags['author']?.firstOrNull ??
                comic.author,
            type: comic.type,
            tags: newTags,
          );
          comics[index] = updated;
          for (final name in memberships[comic]!) {
            // Background refresh must not recreate folders or memberships
            // that the user removes while the request is in flight.
            if (manager.existsFolder(name) &&
                manager.comicExists(name, comic.id, comic.type)) {
              manager.updateInfo(name, updated);
            }
          }
          return;
        } catch (error) {
          if (task.cancelRequested) return;
          if (attempt == 2) task.addError('${comic.name}: $error');
        }
      }
    }

    const maxConcurrency = 4;
    for (
      var index = 0;
      index < comics.length && !task.cancelRequested;
      index += maxConcurrency
    ) {
      final futures = <Future<void>>[];
      for (
        var i = index;
        i < comics.length && i < index + maxConcurrency;
        i++
      ) {
        futures.add(
          updateSingleComic(i).then((_) {
            if (!task.cancelRequested) task.update(completed: ++completed);
          }),
        );
      }
      await Future.wait(futures);
    }
    // A folder view may have changed while the task was minimized.
    if (folder != null) {
      return manager.existsFolder(folder)
          ? manager.getFolderComics(folder)
          : <FavoriteItem>[];
    }
    return comics;
  }, cancellable: true);
  showBackgroundTask(App.rootContext, tasks.latest(key)!);
  return result.catchError((Object error, StackTrace stack) {
    // The registry has retained the failure; no detached route owns this job.
    Log.error('Update Comics Info', error, stack);
    return <FavoriteItem>[];
  });
}

/// Refresh all folders in one cancellable operation, fetching duplicates once.
Future<void> updateAllComicsInfo() async {
  await updateComicsInfo(null);
}

Future<void> sortFolders() async {
  var folders = LocalFavoritesManager().folderNames;

  await showPopUpWidget(
    App.rootContext,
    StatefulBuilder(builder: (context, setState) {
      return PopUpWidgetScaffold(
        title: "Sort".tl,
        tailing: [
          Tooltip(
            message: "Help".tl,
            child: IconButton(
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          )
        ],
        body: ReorderableListView.builder(
          onReorder: (oldIndex, newIndex) {
            if (oldIndex < newIndex) {
              newIndex--;
            }
            setState(() {
              var item = folders.removeAt(oldIndex);
              folders.insert(newIndex, item);
            });
          },
          itemCount: folders.length,
          itemBuilder: (context, index) {
            return ListTile(
              key: ValueKey(folders[index]),
              title: Text(folders[index]),
            );
          },
        ),
      );
    }),
  );

  LocalFavoritesManager().updateOrder(folders);
}

Future<void> importNetworkFolder(
  String source,
  int updatePageNum,
  String? folder,
  String? folderID,
) async {
  final comicSource = ComicSource.find(source);
  if (comicSource == null || updatePageNum <= 0) return;
  final resultName = folder == null || folder.isEmpty ? comicSource.name : folder;
  final manager = LocalFavoritesManager();
  if (manager.existsFolder(resultName) &&
      !manager.isLinkedToNetworkFolder(resultName, source, folderID ?? '')) {
    App.rootContext.showMessage(message: "Folder already exists".tl);
    return;
  }
  final key = 'network-favorites-import:${jsonEncode([source, folderID, resultName])}';
  final future = BackgroundTasks.instance.run<void>(
    key, '${"Importing".tl}: $resultName', (task) async {
      if (task.cancelRequested) return;
      if (!manager.existsFolder(resultName)) {
        manager.createFolder(resultName);
        manager.linkFolderToNetwork(resultName, source, folderID ?? '');
      }
      final data = comicSource.favoriteData;
      if (data == null || (data.loadComic == null && data.loadNext == null)) {
        throw StateError('Unsupported source');
      }
      final oldToNew = data.isOldToNewSort == true;
      final type = ComicType.fromKey(source);
      var received = 0;
      var pages = 0;
      var finished = false;
      var page = 1;
      String? cursor;
      final seen = <String>{};
      final seenCursors = <String>{};
      var comics = <FavoriteItem>[];
      Res<List<Comic>>? firstPage;

      Future<Res<List<Comic>>?> request(Future<Res<List<Comic>>> Function() load) async {
        for (var attempt = 0; attempt < 3; attempt++) {
          if (task.cancelRequested) return null;
          try {
            final result = await load();
            if (task.cancelRequested) return null;
            if (result.error) throw StateError(result.errorMessage ?? 'Network error');
            return result;
          } catch (_) {
            if (task.cancelRequested) return null;
            if (attempt == 2) rethrow;
          }
        }
        return null;
      }

      String progressMessage(int count) =>
          "Imported @a comics, loaded @b pages, received @c comics".tlParams({
            'a': count, 'b': pages, 'c': received,
          });
      task.update(message: progressMessage(0));
      try {
        if (oldToNew && data.loadComic != null) {
          firstPage = await request(() => data.loadComic!(1, folderID));
          if (firstPage != null) {
            final totalPages = firstPage.subData is int ? firstPage.subData as int : 1;
            page = max(1, totalPages - updatePageNum + 1);
          }
        }
        while (!finished && pages < updatePageNum && !task.cancelRequested) {
          Res<List<Comic>>? result;
          if (data.loadComic != null) {
            result = page == 1 && firstPage != null
                ? firstPage
                : await request(() => data.loadComic!(page, folderID));
            firstPage = null;
          } else {
            result = await request(() => data.loadNext!(cursor, folderID));
          }
          if (result == null || task.cancelRequested) break;
          // User changes made while minimized must not recreate/rebind a folder.
          if (!manager.existsFolder(resultName) ||
              !manager.isLinkedToNetworkFolder(resultName, source, folderID ?? '')) {
            throw StateError('Favorite folder was removed or its link changed');
          }
          received += result.data.length;
          for (final comic in result.data) {
            if (seen.add(comic.id) && !manager.comicExists(resultName, comic.id, type)) {
              comics.add(FavoriteItem(
                id: comic.id, name: comic.title, coverPath: comic.cover,
                type: type, author: comic.subtitle ?? '', tags: comic.tags ?? [],
              ));
            }
          }
          pages++;
          finished = result.data.isEmpty;
          if (data.loadComic != null) {
            if (result.subData is int && result.subData > 0) {
              final totalPages = result.subData as int;
              task.update(total: min(updatePageNum, pages + max(0, totalPages - page)));
              finished = finished || page >= totalPages;
            }
            page++;
          } else {
            final next = result.subData?.toString();
            finished = finished || next == null;
            if (!finished && !seenCursors.add(next)) {
              throw StateError('Source repeated a favorite page cursor');
            }
            cursor = next;
          }
          task.update(completed: pages, message: progressMessage(comics.length));
        }
      } catch (error, stack) {
        task.addError(error.toString());
        Log.error('Import network favorites', error, stack);
      }
      if (!manager.existsFolder(resultName) ||
          !manager.isLinkedToNetworkFolder(resultName, source, folderID ?? '')) {
        throw StateError('Favorite folder was removed or its link changed');
      }
      if (appdata.settings['newFavoriteAddTo'] == 'start' && !oldToNew) {
        comics = comics.reversed.toList();
      }
      // Preserve successfully fetched pages on cancellation or later failure,
      // as before. SQL insertion deduplicates against concurrent local edits.
      final inserted = manager.addComics(resultName, comics);
      task.update(completed: pages, message: progressMessage(inserted));
    }, cancellable: true,
  );
  showBackgroundTask(App.rootContext, BackgroundTasks.instance.latest(key)!);
  try {
    await future;
  } catch (error, stack) {
    Log.error('Import network favorites', error, stack);
  }
}
