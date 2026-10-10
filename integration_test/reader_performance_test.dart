import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const idleProbe = bool.fromEnvironment('READER_IDLE_PROBE');

  testWidgets('large ordinary pages survive repeated reader entry and exit', (
    tester,
  ) async {
    await App.init();
    final root = await Directory(
      App.cachePath,
    ).createTemp('reader-performance-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    await AppTranslation.init();
    appdata.settings['language'] = 'en-US';
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    appdata.settings['enablePageAnimation'] = true;
    appdata.settings['enableClockAndBatteryInfoInReader'] = idleProbe;
    appdata.settings['enableTurnPageByVolumeKey'] = false;
    appdata.settings['recordReadingStatistics'] = false;
    appdata.settings['removeReadLaterOnComplete'] = false;
    appdata.settings['enableCustomImageProcessing'] = false;
    appdata.settings['showSystemStatusBar'] = true;
    appdata.settings['webdav'] = [];

    final directory = await Directory(
      '${root.path}/local/fixture',
    ).create(recursive: true);
    await File('${root.path}/local_path').writeAsString('${root.path}/local');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.indigo.shade50, BlendMode.src);
    for (var row = 0; row < 12; row++) {
      canvas.drawRect(
        Rect.fromLTWH(64, 64 + row * 240, 1920, 160),
        Paint()..color = row.isEven ? Colors.indigo : Colors.teal,
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(2048, 3072);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    for (var page = 1; page <= 32; page++) {
      await File(
        '${directory.path}/$page.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
    }
    image.dispose();
    picture.dispose();
    await LocalManager().init();
    await LocalFavoritesManager().init();
    await HistoryManager().init();
    final comic = LocalComic(
      id: 'ordinary-performance-fixture',
      title: 'Ordinary performance fixture',
      subtitle: 'Generated shapes',
      tags: [],
      directory: 'fixture',
      chapters: null,
      cover: '1.png',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
    await LocalManager().add(comic);
    final history = History.fromModel(model: comic, ep: 1, page: 1);
    final samples = <Map<String, Object>>[];
    void sample(String phase) {
      final cache = PaintingBinding.instance.imageCache;
      samples.add({
        'phase': phase,
        'rss': ProcessInfo.currentRss,
        'cacheBytes': cache.currentSizeBytes,
        'cacheLimit': cache.maximumSizeBytes,
        'liveImages': cache.liveImageCount,
        'pendingImages': cache.pendingImageCount,
      });
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => WindowFrame(child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.to(
                  () => Reader(
                    type: ComicType.local,
                    cid: comic.id,
                    name: comic.title,
                    chapters: null,
                    history: history,
                    initialPage: history.page,
                    author: comic.subtitle,
                    tags: [],
                  ),
                ),
                child: const Text('Continue test reader'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    sample('before');

    if (!idleProbe) {
      await binding.watchPerformance(() async {
        await tester.tap(find.text('Continue test reader'));
        await tester.pumpAndSettle();
        expect(find.byType(Reader), findsOneWidget);
        sample('first-entry');
        for (final page in [4.0, 8.0, 12.0, 16.0, 20.0, 24.0]) {
          tester
              .widget<CustomSlider>(find.byType(CustomSlider))
              .onChanged(page);
          await tester.pumpAndSettle();
          sample('page-$page');
        }
        App.rootNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        sample('first-exit');
      }, reportKey: 'reader_fill_and_exit');

      await binding.watchPerformance(() async {
        for (var i = 0; i < 4; i++) {
          await tester.tap(find.text('Continue test reader'));
          await tester.pumpAndSettle();
          sample('reentry-$i');
          App.rootNavigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          sample('exit-$i');
        }
      }, reportKey: 'reader_reentry');
      await tester.pump(const Duration(seconds: 2));
    } else {
      for (final mode in ['galleryLeftToRight', 'continuousTopToBottom']) {
        appdata.settings['readerMode'] = mode;
        history.page = 1;
        await tester.tap(find.text('Continue test reader'));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(Reader));
        final horizontal = mode == 'galleryLeftToRight';
        final start = Offset(
          rect.left + rect.width * (horizontal ? .8 : .5),
          rect.top + rect.height * (horizontal ? .5 : .75),
        );
        final delta = horizontal
            ? Offset(-rect.width * .65, 0)
            : Offset(0, -rect.height * .55);
        Future<void> swipe() async {
          await tester.flingFrom(start, delta, 1000);
          await tester.pumpAndSettle();
        }

        await binding.watchPerformance(() async {
          for (var i = 0; i < 5; i++) {
            await swipe();
          }
        }, reportKey: '${mode}_continuous_swipes');

        await binding.watchPerformance(() async {
          for (final milliseconds in [1200, 3200, 6200]) {
            // Let route/image animations and the history debounce finish,
            // then exercise the first real gesture after a quiet interval.
            await Future<void>.delayed(Duration(milliseconds: milliseconds));
            await swipe();
            sample('$mode-idle-$milliseconds');
          }
        }, reportKey: '${mode}_idle_swipes');

        await binding.watchPerformance(() async {
          final delivered = Completer<void>();
          // Deliver the same platform message Flutter receives from Android.
          // This tests the response, without exhausting the device's memory.
          tester.binding.channelBuffers.push(
            SystemChannels.system.name,
            SystemChannels.system.codec.encodeMessage({
              'type': 'memoryPressure',
            }),
            (_) => delivered.complete(),
          );
          await delivered.future;
          expect(
            PaintingBinding.instance.imageCache.maximumSizeBytes,
            32 << 20,
          );
          sample('$mode-pressure');
          for (var i = 0; i < 3; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            await swipe();
            sample('$mode-pressure-swipe-$i');
          }
        }, reportKey: '${mode}_pressure_swipes');
        expect(history.page, greaterThan(1));
        App.rootNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
        sample('$mode-exit');
      }
    }
    expect(tester.takeException(), isNull);
    binding.reportData!['memorySamples'] = samples;
    // ignore: avoid_print
    print('READER_MEMORY ${jsonEncode(samples)}');
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    LocalManager().close();
    LocalFavoritesManager().close();
    await HistoryManager().closeAfterReads();
    await root.delete(recursive: true);
  });
}
