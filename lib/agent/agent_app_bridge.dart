import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/pages/read_later_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/reading_statistics_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/io.dart';
import 'agent_source_backups.dart';

/// A download queue entry, detached from the task object for tool results.
class AgentDownloadTask {
  final String sourceKey;
  final String comicId;
  final String title;
  final double progress;
  final bool paused;
  final bool failed;
  final String message;
  const AgentDownloadTask({
    required this.sourceKey,
    required this.comicId,
    required this.title,
    required this.progress,
    required this.paused,
    required this.failed,
    required this.message,
  });
}

/// An installable source from one of the user's enabled source libraries.
class AgentCatalogSource {
  final String key;
  final String name;
  final String version;
  final String description;
  final String url;
  final String libraryId;
  final String libraryName;
  const AgentCatalogSource({
    required this.key,
    required this.name,
    required this.version,
    required this.description,
    required this.url,
    required this.libraryId,
    required this.libraryName,
  });
}

/// A catalog of comic sources configured by the user.
class AgentSourceLibrary {
  final String id;
  final String name;
  final String url;
  final bool enabled;
  const AgentSourceLibrary({
    required this.id,
    required this.name,
    required this.url,
    required this.enabled,
  });
}

/// A comic of the followed favorites folder with a new chapter.
class AgentComicUpdate {
  final FavoriteItem comic;
  final String? updateTime;
  const AgentComicUpdate(this.comic, this.updateTime);
}

/// Pages the agent may open for the user. They only display content; the
/// agent never receives page images.
enum AgentAppPage {
  history('history', '阅读历史'),
  downloads('downloads', '下载队列'),
  local('local', '本地漫画'),
  readLater('later', '稍后再看'),
  updates('updates', '追更'),
  sources('sources', '漫画源管理'),
  statistics('statistics', '阅读统计');

  final String id;
  final String label;
  const AgentAppPage(this.id, this.label);
}

/// Application services used by agent tools beyond local favorites and read
/// later. The default delegates to the app singletons; tests replace it.
class AgentAppBridge {
  const AgentAppBridge();

  bool get historyReady => HistoryManager().isInitialized;
  bool get localReady => LocalManager().isInitialized;

  Future<void> initHistory() => HistoryManager().init();
  List<History> histories() => HistoryManager().getAll();
  History? findHistory(String id, ComicType type) =>
      HistoryManager().find(id, type);
  void removeHistories(List<ComicID> ids) =>
      HistoryManager().batchDeleteHistories(ids);
  void addHistory(History value) => HistoryManager().addHistory(value);

  Future<void> initLocal() => LocalManager().init();
  List<LocalComic> localComics() =>
      LocalManager().getComics(LocalSortType.timeDesc);
  LocalComic? findLocal(String id, ComicType type) =>
      LocalManager().find(id, type);

  /// Local files are removed only when the app manages their directory.
  void deleteLocal(LocalComic comic) => LocalManager().deleteComic(comic);

  /// Removing every downloaded chapter removes the local comic as well.
  void deleteLocalChapters(LocalComic comic, List<String> chapters) =>
      LocalManager().deleteComicChapters(comic, chapters);

  List<AgentDownloadTask> downloads() => [
    for (final task in LocalManager().downloadingTasks)
      AgentDownloadTask(
        sourceKey: task.comicType.comicSource?.key ?? 'Unknown',
        comicId: task.id,
        title: task.title,
        progress: task.progress,
        paused: task.isPaused,
        failed: task.isError,
        message: task.message,
      ),
  ];
  bool isDownloading(String id, ComicType type) =>
      LocalManager().isDownloading(id, type);
  void download(
    ComicSource source,
    ComicDetails details,
    List<String>? chapters,
  ) => LocalManager().addTask(
    ImagesDownloadTask(
      source: source,
      comicId: details.comicId,
      comic: details,
      chapters: chapters,
      comicTitle: details.title,
    ),
  );

  /// Returns false when the task is not in the queue or not in that state.
  bool controlDownload(String id, ComicType type, String action) {
    final manager = LocalManager();
    DownloadTask? task;
    for (final item in manager.downloadingTasks) {
      if (item.id == id && item.comicType == type) task = item;
    }
    if (task == null) return false;
    switch (action) {
      case 'pause':
        if (task.isPaused) return false;
        task.pause();
      case 'resume':
        if (!task.isPaused && !task.isError) return false;
        manager.moveToFirst(task);
        task.resume();
      case 'retry':
        if (!task.isError) return false;
        manager.retryTask(task);
      case 'prioritize':
        manager.moveToFirst(task);
      case 'cancel':
        task.cancel();
      default:
        return false;
    }
    return true;
  }

  String? followedFolder() {
    final folder = appdata.settings['followUpdatesFolder'];
    return folder is String && folder.isNotEmpty ? folder : null;
  }

  List<AgentComicUpdate> updates(String folder) => [
    for (final item in LocalFavoritesManager().getUpdates(folder))
      AgentComicUpdate(item, item.updateTime),
  ];

  /// Checks every comic of the folder, including recently checked ones.
  Stream<UpdateProgress> checkUpdates(String folder) =>
      updateFolder(folder, true);

  /// Follows updates of [folder], or stops following when it is null. As on
  /// the follow updates page, update marks start empty.
  Future<void> setFollowedFolder(String? folder) async {
    if (folder != null) {
      LocalFavoritesManager().prepareTableForFollowUpdates(folder);
    }
    appdata.settings['followUpdatesFolder'] = folder;
    await appdata.saveData();
    updateFollowUpdatesUI();
  }

  List<AgentSourceLibrary> sourceLibraries() {
    ComicSourceLibraryManager.migrateLegacy();
    return [
      for (final library in ComicSourceLibraryManager.all())
        AgentSourceLibrary(
          id: library.id,
          name: library.name,
          url: library.url,
          enabled: library.enabled,
        ),
    ];
  }

  /// Adding an existing address renames that library instead.
  void addSourceLibrary(String name, String url) =>
      ComicSourceLibraryManager.add(name, url);

  /// Installed sources are kept.
  void removeSourceLibrary(String id) => ComicSourceLibraryManager.remove(id);

  Object? setting(String key) => appdata.settings[key];
  void setSetting(String key, Object? value) => appdata.settings[key] = value;
  Future<void> saveSettings() => appdata.saveData();

  /// Entries of all enabled libraries. A library that fails is reported and
  /// does not hide the others.
  Future<(List<AgentCatalogSource>, List<String>)> sourceCatalog() async {
    ComicSourceLibraryManager.migrateLegacy();
    final sources = <AgentCatalogSource>[];
    final failures = <String>[];
    for (final library in ComicSourceLibraryManager.enabled()) {
      try {
        final response = await AppDio().get<String>(
          library.url,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'cache-time': 'no'},
          ),
        );
        final raw = jsonDecode(response.data ?? '');
        if (response.statusCode != 200 || raw is! List) {
          throw const FormatException('Invalid source catalog');
        }
        for (final entry in raw.whereType<Map>()) {
          final key = entry['key']?.toString() ?? '';
          final url = resolveSourceDownloadUrl(
            url: entry['url']?.toString(),
            fileName: entry['fileName']?.toString(),
            listUrl: library.url,
          );
          if (key.isEmpty || url == null) continue;
          sources.add(
            AgentCatalogSource(
              key: key,
              name: entry['name']?.toString() ?? key,
              version: entry['version']?.toString() ?? '',
              description: entry['description']?.toString() ?? '',
              url: url,
              libraryId: library.id,
              libraryName: library.name,
            ),
          );
        }
      } catch (_) {
        failures.add(library.name);
      }
    }
    return (sources, failures);
  }

  /// Installs a catalog entry the same way as the source library page.
  Future<ComicSource> installSource(AgentCatalogSource entry) async {
    final response = await AppDio().get<String>(
      entry.url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'cache-time': 'no'},
      ),
    );
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) {
      throw Exception('Source download failed with status $status');
    }
    final fileName = Uri.parse(entry.url).pathSegments.last;
    final source = await ComicSourceParser().createAndParse(
      response.data ?? '',
      fileName,
    );
    ComicSourceManager().add(
      source,
      originLibraryId: entry.libraryId,
      sourceFileName: fileName,
    );
    // Show the new source's pages, as the source library page does.
    void add(String key, Iterable<String?> values) {
      appdata.settings[key] = <String>{
        ...List<String>.from(appdata.settings[key] as List? ?? const []),
        ...values.whereType<String>(),
      }.toList();
    }

    add('explore_pages', source.explorePages.map((page) => page.title));
    add('categories', [source.categoryData?.key]);
    add('favorites', [source.favoriteData?.key]);
    if (source.searchPageData != null) add('searchSources', [source.key]);
    await appdata.saveData();
    App.forceRebuild();
    return source;
  }

  Future<int> checkSourceUpdates() => ComicSourcePage.checkComicSourceUpdate();
  Map<String, String> availableSourceUpdates() =>
      ComicSourceManager().availableUpdates;
  Future<bool> updateSource(ComicSource source) =>
      ComicSourcePage.update(source, false);
  Future<void> saveSourceData(ComicSource source) => source.saveData();

  /// Logs of this launch, oldest first.
  List<LogItem> logs() => List.of(Log.logs);

  Future<String> readSourceCode(ComicSource source) =>
      File(source.filePath).readAsString();

  /// Replaces the code of an installed source after it parses with the same
  /// key, then loads the new version in place of the old one, as updates do.
  Future<void> writeSourceCode(ComicSource source, String code) async {
    final parser = ComicSourceParser();
    final target = File(source.filePath);
    final temp = File('${target.path}.agent.tmp');
    final backup = File('${target.path}.agent.bak');
    try {
      final candidate = await parser.parse(
        code,
        source.filePath,
        allowExistingKey: true,
        registerSource: false,
      );
      if (candidate.key != source.key) {
        throw ComicSourceParseException(
          'Source key changed from ${source.key} to ${candidate.key}',
        );
      }
      await temp.writeAsString(code, flush: true);
      await atomicReplaceWithBackup(
        target: target,
        temporary: temp,
        backup: backup,
      );
      await backup.deleteIgnoreError();
      parser.registerParsedSource();
      ComicSourceManager().replace(candidate);
    } finally {
      parser.discardParsedSource();
      await temp.deleteIgnoreError();
    }
  }

  AgentSourceBackups get sourceBackups =>
      AgentSourceBackups(Directory('${App.dataPath}/agent/source_backups'));

  Future<void> initStatistics() => ReadingStatisticsManager().init();
  List<ReadingStatistic> readingStatistics(int days) =>
      ReadingStatisticsManager().recent(days: days);
  int readingSeconds() => ReadingStatisticsManager().totalDuration();

  /// Opens a page in the main content area, above the agent page.
  void open(Widget Function() builder) {
    final context =
        App.mainNavigatorKey?.currentContext ??
        App.rootNavigatorKey.currentContext;
    if (context == null) throw StateError('No navigator');
    unawaited(context.to(builder));
  }

  /// Full-screen pages, such as the reader, cover the navigation.
  void openFullScreen(Widget Function() builder) {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null) throw StateError('No navigator');
    unawaited(context.to(builder));
  }

  void openComic(String sourceKey, String id, {String? title, String? cover}) =>
      open(
        () =>
            ComicPage(id: id, sourceKey: sourceKey, title: title, cover: cover),
      );

  void openReader(ComicDetails details, {int? chapter, int? page, int? group}) {
    final history =
        findHistory(details.comicId, details.comicType) ??
        History.fromModel(model: details, ep: 0, page: 0);
    openFullScreen(
      () => Reader(
        type: details.comicType,
        cid: details.comicId,
        name: details.title,
        chapters: details.chapters,
        initialChapter: chapter ?? (history.ep > 0 ? history.ep : null),
        initialPage: page ?? (history.page > 0 ? history.page : null),
        initialChapterGroup: group ?? history.group,
        history: history,
        author: details.findAuthor() ?? '',
        tags: details.plainTags,
      ),
    );
  }

  void openLocalReader(LocalComic comic) => comic.read();

  void openSearch(String keyword, {String? sourceKey, List<String>? options}) =>
      open(
        () => sourceKey == null
            ? AggregatedSearchPage(keyword: keyword)
            : SearchResultPage(
                text: keyword,
                sourceKey: sourceKey,
                options: options,
              ),
      );

  void openCategory(
    String categoryKey,
    String category, {
    String? param,
    List<String>? options,
  }) => open(
    () => CategoryComicsPage(
      category: category,
      param: param,
      categoryKey: categoryKey,
      options: options,
    ),
  );

  void openRanking(String categoryKey) =>
      open(() => RankingPage(categoryKey: categoryKey));

  void openPage(AgentAppPage page) => open(
    () => switch (page) {
      AgentAppPage.history => const HistoryPage(),
      AgentAppPage.downloads => const DownloadingPage(),
      AgentAppPage.local => const LocalComicsPage(),
      AgentAppPage.readLater => const ReadLaterPage(),
      AgentAppPage.updates => const FollowUpdatesPage(),
      AgentAppPage.sources => const ComicSourcePage(),
      AgentAppPage.statistics => const ReadingStatisticsPage(),
    },
  );
}
