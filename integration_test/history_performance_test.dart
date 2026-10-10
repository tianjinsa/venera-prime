import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/translations.dart';

class _MeasuredHistory extends HistoryManager {
  _MeasuredHistory() : super.create();

  final limits = <int>[];

  @override
  Future<HistoryPageResult> getPage({
    HistoryCursor? cursor,
    int limit = 60,
    String query = '',
  }) {
    limits.add(limit);
    return super.getPage(cursor: cursor, limit: limit, query: query);
  }

  @override
  List<History> getAll() => throw StateError('Unexpected full history read');
}

/// Real file reads and image decoding, with no external image services.
class _CoverCache implements CacheManager {
  _CoverCache(this.file);

  final File file;
  int reads = 0;

  @override
  Future<File?> findCache(String key) async {
    reads++;
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1200 histories open and scroll with bounded database reads', (
    tester,
  ) async {
    final history = _MeasuredHistory();
    HistoryManager.cache = history;
    await App.init();
    final root = await Directory(
      App.cachePath,
    ).createTemp('history-performance-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    await AppTranslation.init();
    appdata.settings['language'] = 'zh-CN';
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = true;
    appdata.settings['blockedWords'] = List.generate(
      200,
      (i) => 'unused-rule-$i',
    );
    appdata.settings['blockedAuthors'] = [];
    await history.init();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.indigo.shade100, BlendMode.src);
    for (var row = 0; row < 12; row++) {
      canvas.drawRect(
        Rect.fromLTWH(64, 64 + row * 240, 1920, 160),
        Paint()..color = row.isEven ? Colors.indigo : Colors.teal,
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(2048, 3072);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final cover = File('${root.path}/cover.png');
    await cover.writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    final covers = _CoverCache(cover);
    CacheManager.instance = covers;

    final db = sqlite3.open('${root.path}/history.db');
    try {
      db.execute('BEGIN;');
      final insert = db.prepare('''
        INSERT INTO history
          (id, type, title, subtitle, cover, time, ep, page, readEpisode, max_page)
        VALUES (?, 42, ?, 'Test author', ?, ?, 2, 3, '1,2', 100);
      ''');
      try {
        for (var i = 0; i < 1200; i++) {
          insert.execute([
            'fixture-$i',
            'Test comic $i',
            'https://example.invalid/cover-$i.png',
            1700000000000 + i,
          ]);
        }
      } finally {
        insert.dispose();
      }
      db.execute('COMMIT;');
    } finally {
      db.dispose();
    }

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await history.closeAfterReads();
      CacheManager.instance = null;
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.to(() => const HistoryPage()),
                child: const Text('Open test history'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await binding.watchPerformance(() async {
      await tester.tap(find.text('Open test history'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SliverGridComics>(find.byType(SliverGridComics)).comics,
        hasLength(60),
      );
      expect(history.limits, [60]);
      expect(covers.reads, lessThan(30));
    }, reportKey: 'history_open');

    await binding.watchPerformance(() async {
      for (var i = 0; i < 6; i++) {
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -1800),
          2500,
        );
        await tester.pumpAndSettle();
      }
      expect(history.limits.length, greaterThan(1));
      expect(history.limits, everyElement(60));
      expect(tester.takeException(), isNull);
    }, reportKey: 'history_scroll');

    // Keep a compact, content-independent report in the test runner log.
    // ignore: avoid_print
    print(
      'HISTORY_PERFORMANCE ${jsonEncode({'pagesRead': history.limits.length, 'coversRead': covers.reads, ...?binding.reportData})}',
    );
  });
}
