import 'package:flutter/foundation.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';

/// Owns one paged query. Old requests cannot replace a newer search or refresh.
class HistoryPager extends ChangeNotifier {
  HistoryPager({required this.manager, this.pageSize = 60});

  final HistoryManager manager;
  final int pageSize;

  List<History> items = const [];
  String query = '';
  bool loading = false;
  Object? error;
  HistoryCursor? _cursor;
  int _revision = 0;
  bool _disposed = false;
  bool _reloading = false;
  String _requestedQuery = '';

  bool get hasMore => _cursor != null;
  bool get isReloading => loading && _reloading;
  int get revision => _revision;

  bool _isCurrent(int revision) => !_disposed && revision == _revision;

  Future<bool> reload({String? query, bool keepLoaded = true}) async {
    if (_disposed) return false;
    final requestedQuery = query ?? this.query;
    final targetCount = keepLoaded && requestedQuery == this.query
        ? items.length
        : pageSize;
    final revision = ++_revision;
    _requestedQuery = requestedQuery;
    _reloading = true;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final refreshed = <History>[];
      final seen = <History>{};
      HistoryCursor? cursor;
      do {
        final page = await manager.getPage(
          cursor: cursor,
          limit: pageSize,
          query: requestedQuery,
        );
        if (!_isCurrent(revision)) return false;
        refreshed.addAll(page.items.where(seen.add));
        cursor = page.nextCursor;
      } while (cursor != null && refreshed.length < targetCount);
      // Keep the old tiles during a refresh, then replace the snapshot once.
      // This preserves scroll extent and cover state across history updates.
      items = List.unmodifiable(refreshed);
      _cursor = cursor;
      this.query = requestedQuery;
      return true;
    } catch (e, s) {
      if (_isCurrent(revision)) {
        error = e;
        Log.error('History', 'Failed to load history: $e', s);
      }
      return false;
    } finally {
      if (_isCurrent(revision)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> loadMore() async {
    if (_disposed || loading || error != null || !hasMore) return false;
    final revision = _revision;
    _reloading = false;
    loading = true;
    notifyListeners();
    try {
      final page = await manager.getPage(
        cursor: _cursor,
        limit: pageSize,
        query: query,
      );
      if (!_isCurrent(revision)) return false;
      final seen = items.toSet();
      items = List.unmodifiable([
        ...items,
        for (final item in page.items)
          if (seen.add(item)) item,
      ]);
      _cursor = page.nextCursor;
      return true;
    } catch (e, s) {
      if (_isCurrent(revision)) {
        error = e;
        Log.error('History', 'Failed to load more history: $e', s);
      }
      return false;
    } finally {
      if (_isCurrent(revision)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> retry() {
    if (_reloading) return reload(query: _requestedQuery);
    error = null;
    return loadMore();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
