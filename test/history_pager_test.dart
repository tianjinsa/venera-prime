import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_pager.dart';

History _item(String id) => History.fromMap({
  'id': id,
  'type': 42,
  'title': id,
  'subtitle': '',
  'cover': '',
  'time': 1700000000000,
  'ep': 1,
  'page': 1,
});

HistoryPageResult _page(List<String> ids, {bool more = false}) {
  final items = ids.map(_item).toList();
  return HistoryPageResult(
    items,
    nextCursor: more ? HistoryCursor.fromHistory(items.last) : null,
  );
}

class _QueuedHistory extends HistoryManager {
  _QueuedHistory() : super.create();
  final responses = <Future<HistoryPageResult> Function()>[];
  final requests = <({String query, int limit, HistoryCursor? cursor})>[];

  @override
  Future<HistoryPageResult> getPage({
    HistoryCursor? cursor,
    int limit = 60,
    String query = '',
  }) {
    requests.add((query: query, limit: limit, cursor: cursor));
    return responses.removeAt(0)();
  }
}

void main() {
  test(
    'reads bounded pages and atomically refreshes the loaded extent',
    () async {
      final manager = _QueuedHistory();
      final finishRefresh = Completer<HistoryPageResult>();
      manager.responses.addAll([
        () async => _page(['a', 'b'], more: true),
        () async => _page(['c', 'd'], more: true),
        () async => _page(['new-a', 'new-b'], more: true),
        () => finishRefresh.future,
      ]);
      final pager = HistoryPager(manager: manager, pageSize: 2);
      addTearDown(pager.dispose);
      await pager.reload();
      expect(pager.items.map((item) => item.id), ['a', 'b']);
      await pager.loadMore();
      final oldItems = pager.items;
      final refreshing = pager.reload();
      await Future<void>.delayed(Duration.zero);
      expect(pager.items, same(oldItems));
      finishRefresh.complete(_page(['new-c', 'new-d'], more: true));
      expect(await refreshing, isTrue);
      expect(pager.items.map((item) => item.id), [
        'new-a',
        'new-b',
        'new-c',
        'new-d',
      ]);
      expect(manager.requests.map((request) => request.limit), everyElement(2));
    },
  );

  test('a slow old query cannot replace a newer search', () async {
    final manager = _QueuedHistory();
    final old = Completer<HistoryPageResult>();
    final recent = Completer<HistoryPageResult>();
    manager.responses.addAll([() => old.future, () => recent.future]);
    final pager = HistoryPager(manager: manager);
    addTearDown(pager.dispose);
    final oldRequest = pager.reload(query: 'old');
    final newRequest = pager.reload(query: 'new');
    recent.complete(_page(['new']));
    expect(await newRequest, isTrue);
    old.complete(_page(['old']));
    expect(await oldRequest, isFalse);
    expect(pager.items.single.id, 'new');
    expect(pager.query, 'new');
    expect(pager.loading, isFalse);
  });

  test(
    'scroll requests coalesce and cannot append into a different query',
    () async {
      final manager = _QueuedHistory();
      final append = Completer<HistoryPageResult>();
      manager.responses.addAll([
        () async => _page(['a'], more: true),
        () => append.future,
        () async => _page(['new']),
      ]);
      final pager = HistoryPager(manager: manager);
      addTearDown(pager.dispose);
      await pager.reload();
      final oldAppend = pager.loadMore();
      expect(await pager.loadMore(), isFalse);
      expect(manager.requests, hasLength(2));
      await pager.reload(query: 'new');
      append.complete(_page(['old-next']));
      expect(await oldAppend, isFalse);
      expect(pager.items.single.id, 'new');
    },
  );

  test(
    'failed appends retain existing data and retry the same cursor',
    () async {
      final manager = _QueuedHistory();
      manager.responses.addAll([
        () async => _page(['a'], more: true),
        () async => throw StateError('transient read failure'),
        () async => _page(['a', 'b']),
      ]);
      final pager = HistoryPager(manager: manager);
      addTearDown(pager.dispose);
      await pager.reload();
      expect(await pager.loadMore(), isFalse);
      expect(pager.error, isNotNull);
      expect(pager.items.single.id, 'a');
      expect(await pager.retry(), isTrue);
      expect(pager.items.map((item) => item.id), ['a', 'b']);
      expect(manager.requests[1].cursor, same(manager.requests[2].cursor));
      expect(pager.error, isNull);
      expect(pager.hasMore, isFalse);
    },
  );

  test('disposing the page discards outstanding results', () async {
    final manager = _QueuedHistory();
    final pending = Completer<HistoryPageResult>();
    manager.responses.add(() => pending.future);
    final pager = HistoryPager(manager: manager);
    var notifications = 0;
    pager.addListener(() => notifications++);
    final loading = pager.reload();
    pager.dispose();
    pending.complete(_page(['unused']));
    expect(await loading, isFalse);
    expect(notifications, 1);
  });
}
