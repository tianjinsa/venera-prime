import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"],
      subtitle = row["subtitle"],
      cover = row["cover"],
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String)
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  String get searchText => [
    title,
    subtitle,
    id,
    sourceKey,
    type.comicSource?.name ?? '',
  ].join('\n').toLowerCase();

  bool matchesQuery(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return normalized.split(_historyQuerySeparator).every(searchText.contains);
  }

  String get lastReadTime {
    final local = time.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}';
  }

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res.isEmpty ? lastReadTime : '$res\n$lastReadTime';
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

final _historyQuerySeparator = RegExp(r'\s+');

/// A searchable snapshot; rebuild it when saved history changes.
class HistorySearchIndex {
  HistorySearchIndex(List<History> histories)
    : histories = List.unmodifiable(histories);

  final List<History> histories;
  // Opening or refreshing the page without a query needs no search metadata.
  late final List<String> _texts = [
    for (final history in histories) history.searchText,
  ];

  List<History> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return histories;
    final words = normalized.split(_historyQuerySeparator);
    return [
      for (var i = 0; i < histories.length; i++)
        if (words.every(_texts[i].contains)) histories[i],
    ];
  }
}

class HistoryCursor {
  const HistoryCursor(this.time, this.id, this.type);

  HistoryCursor.fromHistory(History history)
    : time = history.time.millisecondsSinceEpoch,
      id = history.id,
      type = history.type.value;

  final int time;
  final String id;
  final int type;
}

class HistoryPageResult {
  const HistoryPageResult(this.items, {this.nextCursor});

  final List<History> items;
  final HistoryCursor? nextCursor;
}

String _historySearchCondition(
  Database db,
  String query,
  Map<int, String> sources,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return '1';
  final words = normalized.split(_historyQuerySeparator);
  // SQLite's built-in lower() only handles ASCII. Keep the existing Dart
  // search semantics, including source names, on the database worker.
  db.createFunction(
    functionName: 'history_matches',
    argumentCount: const AllowedArgumentCount(4),
    deterministic: true,
    function: (arguments) {
      final type = arguments[3] as int;
      final source = type == 0 ? 'local' : sources[type] ?? 'Unknown:$type';
      final text = [
        arguments[0] ?? '',
        arguments[1] ?? '',
        arguments[2],
        source,
      ].join('\n').toLowerCase();
      return words.every(text.contains) ? 1 : 0;
    },
  );
  return 'history_matches(title, subtitle, id, type) = 1';
}

Future<HistoryPageResult> _readHistoryPage(
  String dbPath,
  String query,
  Map<int, String> sources,
  HistoryCursor? cursor,
  int limit,
) => Isolate.run(() {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout = 1000;');
    final condition = _historySearchCondition(db, query, sources);
    final rows = db.select(
      '''
      SELECT * FROM history
      WHERE $condition
        ${cursor == null ? '' : 'AND (time, id, type) < (?, ?, ?)'}
      ORDER BY time DESC, id DESC, type DESC
      LIMIT ?;
    ''',
      [
        if (cursor != null) ...[cursor.time, cursor.id, cursor.type],
        limit + 1,
      ],
    );
    final items = rows.take(limit).map(History.fromRow).toList();
    return HistoryPageResult(
      items,
      nextCursor: rows.length > limit
          ? HistoryCursor.fromHistory(items.last)
          : null,
    );
  } finally {
    db.dispose();
  }
});

Future<Set<ComicID>> _readHistoryIds(
  String dbPath,
  String query,
  Map<int, String> sources,
) => Isolate.run(() {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout = 1000;');
    final condition = _historySearchCondition(db, query, sources);
    return {
      for (final row in db.select(
        'SELECT id, type FROM history WHERE $condition;',
      ))
        ComicID(ComicType(row['type'] as int), row['id'] as String),
    };
  } finally {
    db.dispose();
  }
});

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;
  final _pendingReads = <Future<void>>{};
  bool _closingReads = false;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;
  Future<void>? _initializing;

  String _cacheKey(String id, HistoryType type) => "${type.value}:$id";

  Future<void> init() => _initializing ??= _initWithReset();

  Future<void> _initWithReset() async {
    try {
      await _initInternal();
    } catch (_) {
      _initializing = null;
      isInitialized = false;
      _cachedHistoryIds = null;
      cachedHistories.clear();
      try {
        _db.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _initInternal() async {
    if (isInitialized) return;
    final dbPath = "${App.dataPath}/history.db";
    var corrupt = false;
    try {
      _db = sqlite3.open(dbPath);
      _db.execute('PRAGMA busy_timeout = 1000;');
      final integrity = _db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first[0] != 'ok') {
        corrupt = true;
        throw StateError('history database integrity check failed');
      }
      _db.execute("""
        create table if not exists history  (
          id text not null,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      """);
    } catch (e, s) {
      // Lock, permission and native-library errors are not database corruption.
      if (!corrupt &&
          !(e is SqliteException &&
              (e.resultCode == 11 || e.resultCode == 26))) {
        rethrow;
      }
      Log.error(
        'History',
        'Database is corrupt; preserving it and creating a new one: $e',
        s,
      );
      try {
        _db.dispose();
      } catch (_) {}
      final backup = File(
        '$dbPath.corrupt.${DateTime.now().millisecondsSinceEpoch}',
      );
      File(dbPath).renameSync(backup.path);
      _db = sqlite3.open(dbPath);
      _db.execute('PRAGMA busy_timeout = 1000;');
      _db.execute("""
        create table history (
          id text not null, title text, subtitle text, cover text,
          time int, type int, ep int, page int, readEpisode text,
          max_page int, chapter_group int, primary key (id, type)
        );
      """);
    }

    var columns = _db.select("PRAGMA table_info(history);");
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      _db.execute("alter table history add column chapter_group int;");
    }
    final hasSingleIdPrimaryKey =
        columns.any(
          (element) => element['name'] == 'id' && element['pk'] == 1,
        ) &&
        !columns.any(
          (element) => element['name'] == 'type' && element['pk'] == 2,
        );
    if (hasSingleIdPrimaryKey) {
      _db.execute('BEGIN;');
      try {
        _db.execute('''
          CREATE TABLE history_migrated (
            id TEXT NOT NULL, title TEXT, subtitle TEXT, cover TEXT,
            time INT, type INT, ep INT, page INT, readEpisode TEXT,
            max_page INT, chapter_group INT, PRIMARY KEY (id, type)
          );
        ''');
        _db.execute('''
          INSERT OR REPLACE INTO history_migrated
          SELECT id, title, subtitle, cover, time, type, ep, page,
                 readEpisode, max_page, chapter_group FROM history;
        ''');
        _db.execute('DROP TABLE history;');
        _db.execute('ALTER TABLE history_migrated RENAME TO history;');
        _db.execute('COMMIT;');
      } catch (_) {
        _db.execute('ROLLBACK;');
        rethrow;
      }
    }

    // Background readers must not block saving progress or refreshing covers.
    // App backups use a SQLite snapshot so committed WAL data is included.
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS history_time_identity_idx
      ON history(time DESC, id DESC, type DESC);
    ''');
    ImageFavoriteManager().init();
    isInitialized = true;
    _closingReads = false;
    notifyListeners();
  }

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  /// Native sqlite handles must stay in their owning isolate.
  Future<void> addHistoryAsync(History newItem) async {
    addHistory(newItem);
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKey(newItem.id, newItem.type)] = true;
    }
    cachedHistories[_cacheKey(newItem.id, newItem.type)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryIds = {};
    var res = _db.select("""
        select id, type from history;
      """);
    for (var element in res) {
      _cachedHistoryIds![_cacheKey(
            element["id"] as String,
            ComicType(element["type"] as int),
          )] =
          true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    var cacheKey = _cacheKey(id, type);
    if (!_cachedHistoryIds!.containsKey(cacheKey)) {
      return null;
    }
    if (cachedHistories.containsKey(cacheKey)) {
      return cachedHistories[cacheKey];
    }

    var res = _db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC, id DESC, type DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  Map<int, String> _searchSources(String query) => query.trim().isEmpty
      ? const {}
      : {
          for (final source in ComicSource.all())
            source.key.hashCode: '${source.key}\n${source.name}',
        };

  /// Read a bounded page on its own connection without moving native handles
  /// across isolates. A composite cursor keeps equal timestamps deterministic.
  Future<HistoryPageResult> getPage({
    HistoryCursor? cursor,
    int limit = 60,
    String query = '',
  }) {
    RangeError.checkValueInInterval(limit, 1, 200, 'limit');
    return _trackRead(
      () => _readHistoryPage(
        '${App.dataPath}/history.db',
        query,
        _searchSources(query),
        cursor,
        limit,
      ),
    );
  }

  /// Whole-query selection needs identities, not every cover and chapter set.
  Future<Set<ComicID>> getMatchingIds({String query = ''}) => _trackRead(
    () => _readHistoryIds(
      '${App.dataPath}/history.db',
      query,
      _searchSources(query),
    ),
  );

  Future<T> _trackRead<T>(Future<T> Function() read) async {
    if (!isInitialized || _closingReads) {
      throw StateError('History database is closed');
    }
    final done = Completer<void>();
    _pendingReads.add(done.future);
    try {
      return await read();
    } finally {
      _pendingReads.remove(done.future);
      done.complete();
    }
  }

  /// Restore must wait for worker handles before replacing the database file.
  Future<void> closeAfterReads() async {
    _closingReads = true;
    await Future.wait(_pendingReads.toList());
    close();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC, id DESC, type DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  void close() {
    _closingReads = true;
    if (!isInitialized) return;
    isInitialized = false;
    _db.dispose();
    _cachedHistoryIds = null;
    cachedHistories.clear();
    _initializing = null;
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        await channel.push(history);
        c++;
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

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
