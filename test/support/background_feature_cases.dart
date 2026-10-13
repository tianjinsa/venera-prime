import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

import '../background_task_overlay_test.dart' as overlay;
import '../favorites_update_test.dart' as favorites;
import '../history_refresh_background_test.dart' as history;
import '../loading_dialog_background_test.dart' as loading;
import '../network_favorite_import_background_test.dart' as network;
import '../reader_page_margin_test.dart' as reader;
import 'test_translations.dart';

/// Only widget tests are registered here. No application initialization, real
/// account, installed comic source, or owner database is read by this suite.
void registerBackgroundFeatureTests() {
  late Directory sandbox;
  const pathMethods = [
    'getApplicationSupportPath',
    'getApplicationDocumentsPath',
    'getApplicationCachePath',
    'getTemporaryPath',
    'getExternalStoragePath',
  ];
  setUpAll(ensureTestTranslations);
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('background-features-');
    App.dataPath = sandbox.path;
    App.cachePath = sandbox.path;
    App.externalStoragePath = sandbox.path;
    final local = Directory('${sandbox.path}/local')..createSync();
    File('${sandbox.path}/local_path').writeAsStringSync(local.path);
    appdata.settings['webdav'] = [];
    appdata.settings['language'] = 'en-US';
    appdata.implicitData['webdavAutoSync'] = false;
    BackgroundTasks.instance.configure(history: {});
    BackgroundTasks.instance.clearFinished();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => sandbox.path,
    );
    for (final method in pathMethods) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.path_provider_android.PathProviderApi.$method',
        (_) async => const StandardMessageCodec().encodeMessage([sandbox.path]),
      );
    }
  });
  tearDown(() async {
    // Individual DB fixtures use their own sub-sandboxes and close them first.
    // These idempotent closes also cover suites that do not open a database.
    LocalManager().close();
    LocalFavoritesManager().close();
    HistoryManager().close();
    BackgroundTasks.instance.configure(history: {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    for (final method in pathMethods) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.path_provider_android.PathProviderApi.$method',
        null,
      );
    }
    await sandbox.delete(recursive: true);
  });

  testWidgets(
    'Cache retention uses last access and never preserves cached data',
    (tester) async {
      await tester.runAsync(() async {
        var now = DateTime(2026, 1, 1);
        final manager = CacheManager.open(
          directory: '${sandbox.path}/test-cache',
          databasePath: '${sandbox.path}/test-cache.db',
          now: () => now,
        );
        try {
          await manager.ready;
          manager.setRetentionDays(1);
          await manager.writeCache('page', [1, 2, 3]);
          now = now.add(const Duration(hours: 23));
          expect(await manager.readCache('page'), [1, 2, 3]);
          now = now.add(const Duration(hours: 23));
          await manager.checkCache();
          expect(manager.currentSize, 3);
          now = now.add(const Duration(hours: 2));
          await manager.checkCache();
          expect(await manager.readCache('page'), isNull);
          expect(manager.currentSize, 0);
          manager.setRetentionDays(0);
          await manager.writeCache('kept', [4, 5]);
          now = now.add(const Duration(days: 90));
          await manager.checkCache();
          expect(await manager.readCache('kept'), [4, 5]);
        } finally {
          await manager.close();
        }
      });
    },
  );

  group('Reader margins (4)', reader.main);
  group('Task overlay (3)', overlay.main);
  group('Loading dialog background lifecycle (3)', loading.main);
  group('Favorite metadata refresh (2)', favorites.main);
  group('Network favorites import (4)', network.main);
  group('History refresh widget lifecycle (2)', () {
    history.registerHistoryBackgroundTests(widgetOnly: true);
  });
}
