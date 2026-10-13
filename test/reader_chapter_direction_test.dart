import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

void main() {
  testWidgets(
    'tap direction stays consistent across chapter boundaries in all six modes',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppTranslation.init();
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
      const chapters = ComicChapters({'ep1': 'First', 'ep2': 'Second'});
      await tester.runAsync(() async {
        File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
        for (final ep in chapters.ids) {
          final dir = Directory('${root.path}/local/comic/$ep')
            ..createSync(recursive: true);
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
          cover: 'ep1/1.png',
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
      }

      for (final mode in ReaderMode.values) {
        for (final reversed in [false, true]) {
          appdata.settings['readerMode'] = mode.key;
          appdata.settings['reverseTapToTurnPages'] = reversed;
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              // Match main.dart: Reader's custom scaffold inherits its body
              // text style from the app-level Material. Without it, swipe
              // prompts use Flutter's 48px missing-Material diagnostic style.
              builder: (context, child) => Material(child: WindowFrame(child!)),
              home: Reader(
                key: ValueKey('${mode.key}-$reversed'),
                type: ComicType.local,
                cid: comic.id,
                name: comic.title,
                chapters: chapters,
                history: History.fromModel(model: comic, ep: 1, page: 1),
                author: '',
                tags: [],
              ),
            ),
          );
          await settle();
          final readerContext = tester.element(find.byType(Reader));
          expect(
            DefaultTextStyle.of(readerContext).style.fontSize,
            Theme.of(readerContext).textTheme.bodyMedium!.fontSize,
            reason: 'reader inherits the same body text style as the real app',
          );
          for (
            var i = 0;
            i < 30 &&
                tester.widgetList<RawImage>(find.byType(RawImage)).isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          final dynamic state = tester.state(find.byType(Reader));
          final rect = tester.getRect(find.byType(Reader));
          final vertical = mode.key.endsWith('TopToBottom');
          final rtl = mode.key.endsWith('RightToLeft');
          final nextAtEnd = !rtl != reversed;
          final next = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .1 : .9),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .9 : .1),
                  rect.center.dy,
                );
          final prev = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .9 : .1),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .1 : .9),
                  rect.center.dy,
                );
          expect(state.chapter, 1, reason: '${mode.key}, reverse=$reversed');
          expect(state.page, 1);
          await tester.tapAt(next);
          await settle();
          expect(
            state.page,
            2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          await tester.tapAt(next);
          await settle();
          expect(state.chapter, 2);
          expect(state.page, 1);
          await tester.tapAt(prev);
          await settle();
          expect(state.chapter, 1);
          expect(
            state.page,
            2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          await tester.tapAt(prev);
          await settle();
          expect(state.page, 1);
          await tester.tapAt(prev);
          await settle();
          expect(state.chapter, 1);
          expect(state.page, 1);
          state.toChapter(2);
          await settle();
          state.toPage(2, animate: false);
          await settle();
          await tester.tapAt(next);
          await settle();
          expect(state.chapter, 2);
          expect(
            state.page,
            2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          // Swipes use the same reading order irrespective of reversed taps.
          state.toChapter(1);
          await settle();
          state.toPage(2, animate: false);
          await settle();
          final forwardSwipe = vertical
              ? const Offset(0, -700)
              : Offset(rtl ? 700 : -700, 0);
          for (var i = 0; i < 4 && state.chapter == 1; i++) {
            await tester.dragFrom(rect.center, forwardSwipe);
            await settle();
          }
          expect(
            state.chapter,
            2,
            reason: 'forward swipe ${mode.key}, reverse=$reversed',
          );
          state.toPage(1, animate: false);
          await settle();
          for (var i = 0; i < 4 && state.chapter == 2; i++) {
            await tester.dragFrom(rect.center, -forwardSwipe);
            await settle();
          }
          expect(
            state.chapter,
            1,
            reason: 'backward swipe ${mode.key}, reverse=$reversed',
          );
          if (mode == ReaderMode.continuousTopToBottom && !reversed) {
            // At the bottom of short pages, page 1 may still be partly visible.
            tester.view.physicalSize = const Size(1000, 1800);
            await settle();
            state.toPage(2, animate: false);
            await settle();
            final tall = tester.getRect(find.byType(Reader));
            await tester.tapAt(
              Offset(tall.center.dx, tall.top + tall.height * .9),
            );
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'short final page still advances to next chapter',
            );
            tester.view.physicalSize = const Size(1000, 1000);
            await settle();
          }
          expect(
            tester.takeException(),
            isNull,
            reason: '${mode.key}, reverse=$reversed',
          );
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
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
