import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'folder deletion succeeds while a background reader holds a snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp('favorite-lock-');
      App.dataPath = directory.path;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => directory.path);
      final favorites = LocalFavoritesManager()..close();
      final acquired = ReceivePort();
      try {
        await favorites.init();
        favorites.createFolder('temporary');
        final dbPath = '${directory.path}/local_favorite.db';
        final port = acquired.sendPort;
        final reader = Isolate.run(() {
          final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
          try {
            db.execute('BEGIN;');
            db.select('SELECT * FROM "temporary";');
            port.send(true);
            sleep(const Duration(milliseconds: 150));
            db.execute('COMMIT;');
          } finally {
            db.dispose();
          }
        });
        await acquired.first.timeout(const Duration(seconds: 5));
        favorites.deleteFolder('temporary');
        await reader;
        expect(favorites.existsFolder('temporary'), false);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        acquired.close();
        favorites.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
