import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  testWidgets(
    'continuous reader remains scrollable after repeated scrubbing and margin drags',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppTranslation.init();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader-scrub-'),
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
      appdata.settings['readerMode'] = 'continuousTopToBottom';
      appdata.settings['enablePageAnimation'] = true;
      appdata.settings['limitImageWidth'] = true;
      appdata.settings['enableClockAndBatteryInfoInReader'] = false;
      appdata.settings['enableTurnPageByVolumeKey'] = false;
      appdata.settings['recordReadingStatistics'] = false;
      appdata.settings['removeReadLaterOnComplete'] = false;
      appdata.settings['webdav'] = [];
      final local = LocalManager();
      late LocalComic comic;
      await tester.runAsync(() async {
        final dir = Directory('${root.path}/local/comic')
          ..createSync(recursive: true);
        File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
        );
        for (var i = 1; i <= 30; i++) {
          File('${dir.path}/$i.png').writeAsBytesSync(bytes);
        }
        await local.init();
        await LocalFavoritesManager().init();
        await HistoryManager().init();
        comic = LocalComic(
          id: 'scrub-test',
          title: 'Scrub test',
          subtitle: '',
          tags: [],
          directory: 'comic',
          chapters: null,
          cover: '1.png',
          comicType: ComicType.local,
          downloadedChapters: [],
          createdAt: DateTime.now(),
        );
        await local.add(comic);
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Reader(
            type: ComicType.local,
            cid: comic.id,
            name: comic.title,
            chapters: null,
            history: History.fromModel(model: comic, ep: 1, page: 1),
            author: '',
            tags: [],
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var i = 0;
        i < 20 &&
            tester.widget<CustomSlider>(find.byType(CustomSlider)).max < 30;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(CustomSlider), findsOneWidget);
      expect(tester.widget<CustomSlider>(find.byType(CustomSlider)).max, 30);
      // Invoke rapid slider callbacks before a frame, the original freeze trigger.
      for (final page in [25.0, 3.0, 28.0, 5.0, 16.0]) {
        tester.widget<CustomSlider>(find.byType(CustomSlider)).onChanged(page);
      }
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<CustomSlider>(find.byType(CustomSlider)).value, 16);
      final blockers = tester.widgetList<AbsorbPointer>(
        find.byType(AbsorbPointer),
      );
      expect(blockers.where((w) => w.absorbing), isEmpty);
      // x=40 is well outside the centered, width-limited image (x=290..710).
      await tester.dragFrom(const Offset(40, 450), const Offset(0, -350));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<CustomSlider>(find.byType(CustomSlider)).value,
        greaterThan(16),
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: const SizedBox(),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
