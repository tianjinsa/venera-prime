import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';

class _Source implements ComicSource {
  @override
  String get key => 'history-refresh-test';
  int calls = 0;
  Completer<void>? gate;
  String? errorMessage;
  @override
  LoadComicFunc get loadComicInfo => (id) async {
    calls++;
    await gate?.future;
    if (errorMessage != null) return Res.error(errorMessage!);
    return Res(
      ComicDetails.fromJson({
        'title': 'Updated $id',
        'cover': '',
        'tags': <String, dynamic>{},
        'sourceKey': key,
        'comicId': id,
      }),
    );
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() => registerHistoryBackgroundTests();

void registerHistoryBackgroundTests({bool widgetOnly = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HistoryManager manager;
  late _Source source;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('history-background-');
    App.dataPath = directory.path;
    manager = HistoryManager();
    manager.close();
    await manager.init();
    source = _Source();
    ComicSourceManager().add(source);
  });
  tearDown(() async {
    ComicSourceManager().remove(source.key);
    manager.close();
    await directory.delete(recursive: true);
  });
  History history(String id, {ComicType? type}) => History.fromMap({
    'id': id,
    'type': (type ?? ComicType.fromKey(source.key)).value,
    'title': 'Old $id',
    'subtitle': '',
    'cover': '',
    'time': 0,
    'ep': 1,
    'page': 2,
    'max_page': 20,
  });

  if (!widgetOnly) {
    test(
      'history refresh retains current reading progress and cannot resurrect deletions',
      () async {
        source.gate = Completer<void>();
        final original = history('1');
        manager.addHistory(original);
        final result = manager.refreshHistoryInfo(original);
        await Future<void>.delayed(Duration.zero);
        final newer = history('1')
          ..page = 12
          ..group = 3;
        manager.addHistory(newer);
        source.gate!.complete();
        expect(await result, isTrue);
        final updated = manager.find('1', original.type)!;
        expect(updated.title, 'Updated 1');
        expect(updated.page, 12);
        expect(updated.group, 3);
        source.gate = Completer<void>();
        final removed = manager.refreshHistoryInfo(updated);
        await Future<void>.delayed(Duration.zero);
        manager.remove('1', original.type);
        source.gate!.complete();
        await removed;
        expect(manager.find('1', original.type), isNull);
      },
    );

    test(
      'history batch reports individual failure titles and reasons',
      () async {
        manager.addHistory(
          history('missing', type: const ComicType(987654321)),
        );
        manager.addHistory(history('local', type: ComicType.local));
        final failures = <String>[];
        final events = await manager
            .refreshAllHistoriesStream(
              onError: (comic, reason) =>
                  failures.add('${comic.title}: $reason'),
            )
            .toList();
        expect(events.last.failed, 1);
        expect(events.last.skipped, 1);
        expect(failures.single, 'Old missing: Comic source is unavailable');
      },
    );

    test('cancellation before a batch launches no source requests', () async {
      for (var i = 0; i < 12; i++) {
        manager.addHistory(history('$i'));
      }
      await manager
          .refreshAllHistoriesStream(isCancelled: () => true)
          .drain<void>();
      expect(source.calls, 0);
    });
  }

  testWidgets(
    'cancellation drains queued work without starting later batches',
    (tester) async {
      source.gate = Completer<void>();
      for (var i = 0; i < 12; i++) {
        manager.addHistory(history('$i'));
      }
      var cancelled = false;
      final result = manager
          .refreshAllHistoriesStream(isCancelled: () => cancelled)
          .toList();
      await tester.pump();
      expect(source.calls, 5);
      cancelled = true;
      source.gate!.complete();
      await tester.pump(const Duration(seconds: 6));
      await result;
      expect(source.calls, 5);
      expect(manager.getAll().every((h) => h.title.startsWith('Old')), isTrue);
    },
  );

  testWidgets('exhausted history retries retain the source error reason', (
    tester,
  ) async {
    source.errorMessage = 'HTTP 503: source maintenance';
    manager.addHistory(history('failed'));
    final failures = <String>[];
    final result = manager
        .refreshAllHistoriesStream(
          onError: (comic, reason) => failures.add('${comic.title}: $reason'),
        )
        .toList();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    final events = await result;
    expect(source.calls, 3);
    expect(events.last.failed, 1);
    expect(failures.single, contains('Old failed:'));
    expect(failures.single, contains('HTTP 503: source maintenance'));
  });
}
