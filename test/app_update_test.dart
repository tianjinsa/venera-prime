import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_update.dart';

ReleaseAsset apk(String name) => ReleaseAsset(
  name: name,
  url: 'https://github.com/venera-app/venera-prime/releases/download/v3/$name',
  size: 4,
);
LatestRelease release(List<ReleaseAsset> assets) =>
    LatestRelease(version: '3.0', title: '', body: '', url: '', assets: assets);

void main() {
  test(
    'select APK by ABI preference with universal fallback, never incompatible split',
    () {
      final assets = [
        apk('venera-arm64-v8a.apk'),
        apk('venera-x86_64.apk'),
        apk('venera-armeabi-v7a.apk'),
        apk('venera.apk'),
      ];
      expect(
        release(assets).androidAsset(['arm64-v8a', 'armeabi-v7a'])!.name,
        'venera-arm64-v8a.apk',
      );
      expect(
        release(assets).androidAsset(['x86_64', 'x86'])!.name,
        'venera-x86_64.apk',
      );
      expect(release(assets).androidAsset(['mips'])!.name, 'venera.apk');
      expect(release(assets.take(3).toList()).androidAsset(['mips']), isNull);
    },
  );

  test(
    'parse release assets, reject foreign download URLs and ignore malformed data',
    () {
      final parsed = LatestRelease.fromJson({
        'tag_name': 'v3.0.0+300',
        'name': '',
        'assets': [
          {
            'name': 'venera.apk',
            'browser_download_url': apk('venera.apk').url,
            'size': 4,
          },
          {
            'name': 'other.apk',
            'browser_download_url': 'https://example.com/app.apk',
            'size': 4,
          },
          {'name': 'broken.apk'},
        ],
      });
      expect(parsed.version, '3.0.0');
      expect(parsed.assets.single.name, 'venera.apk');
    },
  );

  test(
    'stable version comparison handles differing lengths and build metadata',
    () {
      expect(isNewerAppVersion('2.4.10', '2.4.9'), isTrue);
      expect(isNewerAppVersion('2.5', '2.4.6'), isTrue);
      expect(isNewerAppVersion('2.4.6.1', '2.4.6'), isTrue);
      expect(isNewerAppVersion('2.4.6+246', '2.4.6'), isFalse);
      expect(isNewerAppVersion('2.4', '2.4.0'), isFalse);
      expect(isNewerAppVersion('3.0.0-beta', '2.4.6'), isFalse);
      expect(isNewerAppVersion('invalid', '2.4.6'), isFalse);
    },
  );

  group('download verification', () {
    late HttpServer server;
    late Directory dir;
    final bytes = [1, 2, 3, 4];
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('update-test-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.add(bytes);
        request.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
    Dio localDio() => Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealHttpOverrides(),
        ),
      );
    ReleaseAsset asset({int size = 4, String? digest}) => ReleaseAsset(
      name: 'venera.apk',
      url: 'http://127.0.0.1:${server.port}/venera.apk',
      size: size,
      digest: digest,
    );

    test(
      'verified download becomes installable and partial file is removed',
      () async {
        final downloaded = await AppUpdateDownloader(dio: localDio()).download(
          asset(digest: 'sha256:${sha256.convert(bytes)}'),
          dir,
          cancelToken: CancelToken(),
        );
        expect(await downloaded.readAsBytes(), bytes);
        expect(await File('${downloaded.path}.part').exists(), isFalse);
      },
    );
    test('size or digest mismatch never leaves an installable file', () async {
      for (final bad in [asset(size: 9), asset(digest: 'sha256:${'0' * 64}')]) {
        await expectLater(
          AppUpdateDownloader(
            dio: localDio(),
          ).download(bad, dir, cancelToken: CancelToken()),
          throwsFormatException,
        );
        expect(dir.listSync(), isEmpty);
      }
    });
    test('cancelled downloads clean up partial files', () async {
      final cancel = CancelToken()..cancel();
      await expectLater(
        AppUpdateDownloader(
          dio: localDio(),
        ).download(asset(), dir, cancelToken: cancel),
        throwsA(isA<DioException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
    test('path traversal cannot escape update directory', () async {
      await expectLater(
        AppUpdateDownloader(dio: localDio()).download(
          ReleaseAsset(name: '../bad.apk', url: asset().url, size: 4),
          dir,
          cancelToken: CancelToken(),
        ),
        throwsFormatException,
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  testWidgets(
    'Android updater passes device ABIs and APK path over native channel',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/method_channel'),
        (call) async {
          calls.add(call);
          return call.method == 'getSupportedAbis'
              ? ['arm64-v8a', 'armeabi-v7a']
              : false;
        },
      );
      expect(await AndroidAppUpdater.supportedAbis(), [
        'arm64-v8a',
        'armeabi-v7a',
      ]);
      expect(
        await AndroidAppUpdater.install(File('/cache/updates/venera.apk')),
        isFalse,
      );
      expect(calls.last.arguments, {'path': '/cache/updates/venera.apk'});
    },
  );
}

class _RealHttpOverrides extends HttpOverrides {}
