import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/cloudflare.dart';

AppUpdateDownloader nativeDownloader() {
  // App initialization is intentionally skipped; retain its stream interceptors.
  final dio = AppDio()
    ..interceptors.addAll([
      NetworkCacheManager(),
      CloudflareInterceptor(),
      MyLogInterceptor(),
    ]);
  return AppUpdateDownloader(dio: dio);
}

void main() {
  final feedPath = Platform.environment['PRIME_UPDATE_FEED'];
  test(
    'native updater verifies a real release APK',
    () async {
      final release = LatestRelease.fromJson(
        jsonDecode(await File(feedPath!).readAsString())
            as Map<String, dynamic>,
      );
      final asset = release.androidAsset(['arm64-v8a'])!;
      final directory = await Directory.systemTemp.createTemp('live-update-');
      final previousProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      try {
        final file = await nativeDownloader().download(
          asset,
          directory,
          cancelToken: CancelToken(),
        );
        expect(await file.length(), asset.size);
      } finally {
        appdata.settings['proxy'] = previousProxy;
        await directory.delete(recursive: true);
      }
    },
    skip:
        feedPath == null ||
        Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'native updater downloads every byte after redirects and stream pauses',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(4 * 1024 * 1024 + 123, (i) => i % 251),
      );
      final directory = await Directory.systemTemp.createTemp('native-update-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/app.apk');
        } else {
          request.response.contentLength = bytes.length;
          for (var offset = 0; offset < bytes.length; offset += 16384) {
            final end = (offset + 16384).clamp(0, bytes.length);
            request.response.add(Uint8List.sublistView(bytes, offset, end));
            await request.response.flush();
          }
        }
        await request.response.close();
      });
      final previousProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      try {
        for (final path in ['/app.apk', '/redirect']) {
          final received = <int>[];
          final file = await nativeDownloader().download(
            ReleaseAsset(
              name: 'app.apk',
              url: 'http://127.0.0.1:${server.port}$path',
              size: bytes.length,
              digest: 'sha256:${sha256.convert(bytes)}',
            ),
            directory,
            cancelToken: CancelToken(),
            onProgress: (count, _) => received.add(count),
          );
          expect(await file.length(), bytes.length);
          expect(await file.readAsBytes(), bytes);
          expect(received.last, bytes.length);
          expect(await File('${file.path}.part').exists(), isFalse);
        }
      } finally {
        appdata.settings['proxy'] = previousProxy;
        await server.close(force: true);
        await subscription.cancel();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
