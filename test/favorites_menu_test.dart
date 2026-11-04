import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

import 'support/test_translations.dart';

void main() {
  for (final width in [360.0, 1100.0]) {
    testWidgets('favorite menus export and reimport folders at width $width', (
      tester,
    ) async {
      await ensureTestTranslations();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('favorite-menu-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = root.path;
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(appdata.toJson())),
      );
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      appdata.settings['webdav'] = [];
      appdata.settings['favorites'] = <String>[];
      appdata.implicitData.remove('favoriteFolder');
      final exported = File('${root.path}/saved-favorites.json');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => switch (call.method) {
          'getSavePath' => exported.path,
          'openFile' => [exported.path],
          _ => null,
        },
      );
      final manager = LocalFavoritesManager();
      manager.close();
      await tester.runAsync(() => manager.init());
      manager.createFolder('Fixture folder');
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            builder: (context, child) => WindowFrame(child!),
            home: const Scaffold(body: FavoritesPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('favorites-overview-menu')));
        await tester.pumpAndSettle();
        expect(find.text('Import from file'), findsOneWidget);
        expect(find.text('Update Comics Info'), findsOneWidget);
        await tester.tap(find.text('Export'));
        await tester.pumpAndSettle();
        expect(find.byType(SimpleDialog), findsOneWidget);
        await tester.runAsync(
          () => tester.tap(find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text('Fixture folder'),
          )),
        );
        await settle();
        expect(exported.existsSync(), isTrue);
        final backup = jsonDecode(exported.readAsStringSync());
        expect(backup['name'], 'Fixture folder');
        expect(backup['comics'], isEmpty);

        await tester.tap(find.text('Favorite Folders'));
        await settle();
        await tester.tap(find.byKey(const Key('favorites-all-menu')));
        await tester.pumpAndSettle();
        expect(find.text('Export'), findsOneWidget);
        expect(find.text('Import from file'), findsOneWidget);
        expect(find.text('Delete Folder'), findsNothing);
        App.rootPop();
        await tester.pumpAndSettle();

        // Return through the page state to inspect a regular folder as well.
        final dynamic state = tester.state(find.byType(FavoritesPage));
        state.setFolder(false, 'Fixture folder');
        await settle();
        await tester.tap(find.byKey(const Key('favorites-folder-menu')));
        await tester.pumpAndSettle();
        for (final label in ['Rename', 'Reorder', 'Export', 'Update Comics Info', 'Delete Folder']) {
          expect(find.text(label), findsOneWidget);
        }
        App.rootPop();
        state.setFolder(false, null);
        await settle();
        await tester.tap(find.byKey(const Key('favorites-overview-menu')));
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Import from file')));
        await settle();
        expect(manager.folderNames, contains('Fixture folder(0)'));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        manager.close();
        appdata.restoreMemorySnapshot(snapshot);
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }
}
