import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';

import 'support/test_translations.dart';
import 'package:venera/network/cache.dart';

Future<void> _waitForContinuousImages(WidgetTester tester) async {
  if (find.byType(Reader).evaluate().isEmpty ||
      !appdata.settings['readerMode'].toString().startsWith('continuous')) {
    return;
  }
  bool imagesDecoded() {
    final images = find.byType(ComicImage);
    return images.evaluate().isNotEmpty &&
        images.evaluate().every(
          (element) => find
              .descendant(
                of: find.byWidget(element.widget),
                matching: find.byType(RawImage),
              )
              .evaluate()
              .isNotEmpty,
        );
  }

  for (var i = 0; i < 60 && !imagesDecoded(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    imagesDecoded(),
    isTrue,
    reason: 'chapter navigation waits for decoded image extents',
  );
}

void main() {
  testWidgets(
    'site chapter links override descending source order independently of display order',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await ensureTestTranslations();
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(appdata.toJson())),
      );
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('chapter-direction-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = root.path;
      for (final channel in [
        'flutter_memory_info',
        'window_manager',
        'venera/method_channel',
      ]) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
      }
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      appdata.settings['enablePageAnimation'] = false;
      appdata.settings['readerTwoPageSpread'] = false;
      appdata.settings['limitImageWidth'] = false;
      appdata.settings['enableTapToTurnPages'] = true;
      appdata.settings['enableDoubleTapToZoom'] = false;
      appdata.settings['enableClockAndBatteryInfoInReader'] = false;
      appdata.settings['enableTurnPageByVolumeKey'] = false;
      appdata.settings['recordReadingStatistics'] = false;
      appdata.settings['removeReadLaterOnComplete'] = false;
      appdata.settings['webdav'] = [];
      final local = LocalManager();
      late LocalComic comic;
      const chapters = ComicChapters.grouped({
        '连载': {
          'https://www.manhuaren.com/m103988/': '第90话',
          'https://www.manhuaren.com/m103987/': '第89话',
          'https://www.manhuaren.com/m103986/': '第88话',
        },
      });
      await tester.runAsync(() async {
        File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
        for (final ep in chapters.ids) {
          final dir = Directory(
            '${root.path}/local/comic/${LocalManager.getChapterDirectoryName(ep)}',
          )..createSync(recursive: true);
          for (var i = 1; i <= 2; i++) {
            File('${dir.path}/$i.png').writeAsBytesSync(bytes);
          }
        }
        await local.init();
        await LocalFavoritesManager().init();
        await HistoryManager().init();
        comic = LocalComic(
          id: 'direction',
          title: 'Direction',
          subtitle: '',
          tags: [],
          directory: 'comic',
          chapters: chapters,
          cover:
              '${LocalManager.getChapterDirectoryName(chapters.ids.first)}/1.png',
          comicType: ComicType.local,
          downloadedChapters: chapters.ids.toList(),
          createdAt: DateTime.now(),
        );
        await local.add(comic);
      });
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        for (
          var i = 0;
          i < 60 && find.byType(Reader).evaluate().isNotEmpty;
          i++
        ) {
          final dynamic state = tester.state(find.byType(Reader));
          if (!state.isLoading && find.byType(RawImage).evaluate().isNotEmpty) {
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await _waitForContinuousImages(tester);
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle();
        local.close();
        LocalFavoritesManager().close();
        HistoryManager().close();
        appdata.restoreMemorySnapshot(snapshot);
        NetworkCacheManager().clear();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      for (final mode in ReaderMode.values) {
        for (final displayOrder in ['source', 'reverse']) {
          appdata.settings['readerMode'] = mode.key;
          appdata.settings['reverseTapToTurnPages'] = false;
          appdata.settings['comicChapterReadingOrder'] = <String, dynamic>{};
          appdata.settings['detectedChapterReadingOrder'] = <String, dynamic>{};
          appdata.settings['comicChapterOrder'] = {
            'direction@local': displayOrder,
          };
          final page =
              '<a href="javascript:pushHistory(\'/m103986/\');">上一章</a><a href="javascript:pushHistory(\'/m103988/\');">下一章</a>';
          final uri = Uri.parse('https://www.manhuaren.com/m103987//');
          NetworkCacheManager().setCache(
            NetworkCache(
              uri: uri,
              requestHeaders: {},
              responseHeaders: {},
              data: page,
              time: DateTime.now(),
              size: page.length,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => Material(child: WindowFrame(child!)),
              home: Reader(
                key: ValueKey('${mode.key}-$displayOrder'),
                type: ComicType.local,
                cid: comic.id,
                name: comic.title,
                chapters: chapters,
                initialChapter: 2,
                history: History.fromModel(model: comic, ep: 2, page: 1),
                author: '',
                tags: [],
              ),
            ),
          );
          await settle();
          final dynamic state = tester.state(find.byType(Reader));
          final rect = tester.getRect(find.byType(Reader));
          final vertical = mode.key.endsWith('TopToBottom');
          final rtl = mode.key.endsWith('RightToLeft');
          final next = vertical
              ? Offset(rect.center.dx, rect.bottom - 50)
              : Offset(rtl ? rect.left + 50 : rect.right - 50, rect.center.dy);
          final previous = vertical
              ? Offset(rect.center.dx, rect.top + 50)
              : Offset(rtl ? rect.right - 50 : rect.left + 50, rect.center.dy);
          expect(state.chapter, 2);
          expect(state.adjacentChapter(forward: true), 1);
          expect(state.adjacentChapter(forward: false), 3);
          expect(
            appdata
                .settings['detectedChapterReadingOrder']['direction@local@1'],
            isTrue,
          );
          // Cached links establish chronology; it remains available offline.
          NetworkCacheManager().clear();
          await tester.tapAt(previous);
          await settle();
          expect(
            state.chapter,
            3,
            reason: '89 -> 88 in ${mode.key}, directory=$displayOrder',
          );
          if (mode.isContinuous) {
            final position = tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: find.byType(ScrollablePositionedList),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                )
                .position;
            expect(
              position.pixels,
              closeTo(position.maxScrollExtent, .5),
              reason: 'previous chapter opens at its actual end in ${mode.key}',
            );
          } else {
            expect(state.page, 2);
          }
          expect(state.isFirstChapterOfGroup, isTrue);
          await tester.tapAt(next);
          await settle();
          expect(state.chapter, 2);
          expect(state.page, 1);
          state.toPage(2, animate: false);
          await settle();
          await tester.tapAt(next);
          await settle();
          expect(
            state.chapter,
            1,
            reason: '89 -> 90 in ${mode.key}, directory=$displayOrder',
          );
          expect(state.page, 1);
          expect(state.isLastChapterOfGroup, isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => Material(child: WindowFrame(child!)),
              home: const SizedBox(),
            ),
          );
          await settle();
        }
      }
    },
  );
}
