import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  testWidgets(
    'WebDAV upload failure retains backups; success prunes only old files',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('prime-webdav-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = '${root.path}/cache';
      Directory(App.cachePath).createSync();
      for (final name in ['history.db', 'local_favorite.db']) {
        sqlite3.open('${root.path}/$name').dispose();
      }
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: const SizedBox(),
        ),
      );
      final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      final oldName = '$day-1.venera';
      final newName = '$day-102.venera';
      final remote = <String, List<int>>{
        oldName: utf8.encode('old backup'),
        newName: utf8.encode('existing same-name backup'),
      };
      final operations = <String>[];
      var rejectUpload = true;
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      final listener = (await tester.runAsync(
        () async => server.listen((request) async {
          final name = request.uri.pathSegments.lastOrNull ?? '';
          operations.add('${request.method} $name');
          final body = await request.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          switch (request.method) {
            case 'OPTIONS':
              request.response.statusCode = 200;
            case 'MKCOL':
              request.response.statusCode = 201;
            case 'PROPFIND':
              request.response.statusCode = 207;
              request.response.headers.contentType = ContentType(
                'application',
                'xml',
              );
              final entries = [
                '<d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
                for (final entry in remote.entries)
                  '<d:response><d:href>/${entry.key}</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>${entry.value.length}</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
              ];
              request.response.write(
                '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>',
              );
            case 'PUT':
              if (rejectUpload) {
                request.response.statusCode = 507;
              } else {
                remote[name] = body;
                request.response.statusCode = 201;
              }
            case 'DELETE':
              remote.remove(name);
              request.response.statusCode = 204;
            default:
              request.response.statusCode = 405;
          }
          await request.response.close();
        }),
      ))!;
      appdata.settings['proxy'] = 'direct';
      appdata.settings['webdav'] = [
        'http://127.0.0.1:${server.port}',
        'fixture-user',
        'fixture-password',
      ];
      appdata.settings['dataVersion'] = 100;
      appdata.implicitData['webdavAutoSync'] = false;
      final sync = DataSync();
      try {
        final failed = await tester.runAsync(
          () => sync.uploadData().timeout(const Duration(seconds: 15)),
        );
        expect(failed!.error, isTrue);
        expect(remote.keys, unorderedEquals([oldName, newName]));
        expect(operations.where((op) => op.startsWith('DELETE')), isEmpty);
        expect(sync.isUploading, isFalse);
        rejectUpload = false;
        operations.clear();
        final uploaded = await tester.runAsync(
          () => sync.uploadData().timeout(const Duration(seconds: 15)),
        );
        expect(uploaded!.error, isFalse);
        expect(remote.keys, [newName]);
        expect(remote[newName]!.take(2), [0x50, 0x4b]);
        expect(
          operations.indexOf('PUT $newName'),
          lessThan(operations.indexOf('DELETE $oldName')),
        );
        expect(operations, isNot(contains('DELETE $newName')));
        expect(sync.isUploading, isFalse);
        expect(sync.lastError, isNull);
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          await server.close(force: true);
          await listener.cancel();
          await root.delete(recursive: true);
        });
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
