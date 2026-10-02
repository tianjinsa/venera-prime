import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cache.dart';

void main() {
  test(
    'failed HEAD freshness check falls back to an actual GET',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      final subscription = server.listen((request) async {
        methods.add(request.method);
        if (request.method == 'HEAD') {
          request.response.statusCode = 503;
        } else {
          request.response.write('fresh content');
        }
        await request.response.close();
      });
      appdata.settings['proxy'] = 'direct';
      final uri = Uri.parse('http://127.0.0.1:${server.port}/comic');
      final cache = NetworkCacheManager()..clear();
      cache.setCache(
        NetworkCache(
          uri: uri,
          requestHeaders: {},
          responseHeaders: {},
          data: 'stale content',
          time: DateTime.now().subtract(const Duration(minutes: 1)),
          size: 32,
        ),
      );
      final dio = Dio(BaseOptions(responseType: ResponseType.plain))
        ..interceptors.add(cache);
      try {
        final response = await dio
            .getUri<String>(uri)
            .timeout(const Duration(seconds: 10));
        expect(response.data, 'fresh content');
        expect(methods, ['HEAD', 'GET']);
      } finally {
        dio.close(force: true);
        cache.clear();
        await server.close(force: true);
        await subscription.cancel();
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
