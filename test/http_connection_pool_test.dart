import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

Future<String?> _get(
  String url, {
  Map<String, String> headers = const {},
}) async {
  final dio = AppDio(
    BaseOptions(
      headers: {'user-agent': 'connection-pool-test', ...headers},
      responseType: ResponseType.plain,
    ),
  );
  try {
    return (await dio.get<String>(url).timeout(const Duration(seconds: 10)))
        .data;
  } finally {
    dio.close();
  }
}

void _setSettings(Map<String, dynamic> values) {
  for (final entry in values.entries) {
    appdata.settings[entry.key] = entry.value;
  }
}

void main() => registerHttpConnectionPoolTests();

void registerHttpConnectionPoolTests({bool device = false}) {
  void register(
    String name,
    Future<void> Function() body, {
    bool skip = false,
  }) {
    if (device) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      }, skip: skip);
    } else {
      test(name, body, skip: skip);
    }
  }

  final skipNative =
      !device && Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1';
  register(
    'separate image clients reuse connections with unchanged settings',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>{};
      final subscription = server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.write('image bytes');
        await request.response.close();
      });
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      try {
        for (var i = 0; i < 8; i++) {
          expect(
            await _get('http://127.0.0.1:${server.port}/image-$i'),
            'image bytes',
          );
        }
        expect(
          ports.length,
          1,
          reason: '8 sequential requests should reuse TCP',
        );
        if (device) {
          print(
            'PERFORMANCE_HTTP_POOL: 8 requests, ${ports.length} TCP connection',
          );
        }
      } finally {
        appdata.settings['proxy'] = oldProxy;
        await server.close(force: true);
        await subscription.cancel();
      }
    },
    skip: skipNative,
  );

  register('TLS setting changes replace the shared connection pool', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ports = <int>{};
    final subscription = server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      request.response.write('ok');
      await request.response.close();
    });
    final previous = {
      for (final key in ['proxy', 'sni', 'ignoreBadCertificate'])
        key: appdata.settings[key],
    };
    _setSettings({
      'proxy': 'direct',
      'sni': true,
      'ignoreBadCertificate': false,
    });
    final url = 'http://127.0.0.1:${server.port}/';
    try {
      await _get(url);
      await _get(url);
      expect(ports.length, 1);
      appdata.settings['sni'] = false;
      await _get(url);
      expect(ports.length, 2);
      appdata.settings['ignoreBadCertificate'] = true;
      await _get(url);
      await _get(url);
      expect(ports.length, 3);
    } finally {
      _setSettings(previous);
      await server.close(force: true);
      await subscription.cancel();
    }
  }, skip: skipNative);

  register(
    'proxy changes apply to the next request and preserve active streams',
    () async {
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finishSlow = Completer<void>();
      final directSubscription = direct.listen((request) async {
        if (request.uri.path == '/slow') {
          request.response.write('before');
          await request.response.flush();
          await finishSlow.future;
          request.response.write('after');
        } else {
          request.response.write('direct');
        }
        await request.response.close();
      });
      final proxySubscription = proxy.listen((request) async {
        request.response.write('proxy');
        await request.response.close();
      });
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final dio = AppDio(
        BaseOptions(
          headers: {'user-agent': 'connection-pool-test'},
          responseType: ResponseType.stream,
        ),
      );
      try {
        final url = 'http://127.0.0.1:${direct.port}';
        expect(await _get(url), 'direct');
        final response = await dio.get<ResponseBody>('$url/slow');
        final bytes = response.data!.stream.fold<List<int>>(
          [],
          (all, next) => all..addAll(next),
        );
        appdata.settings['proxy'] = 'http://127.0.0.1:${proxy.port}';
        expect(await _get(url), 'proxy');
        finishSlow.complete();
        expect(
          String.fromCharCodes(
            await bytes.timeout(const Duration(seconds: 10)),
          ),
          'beforeafter',
        );
        appdata.settings['proxy'] = 'direct';
        expect(await _get(url), 'direct');
      } finally {
        if (!finishSlow.isCompleted) finishSlow.complete();
        dio.close();
        appdata.settings['proxy'] = oldProxy;
        await direct.close(force: true);
        await proxy.close(force: true);
        await directSubscription.cancel();
        await proxySubscription.cancel();
      }
    },
    skip: skipNative,
  );

  register(
    'changed DNS override routes to the new address immediately',
    () async {
      final first = await HttpServer.bind('127.0.0.1', 0);
      late HttpServer second;
      try {
        second = await HttpServer.bind('127.0.0.2', first.port);
      } on SocketException catch (error) {
        await first.close(force: true);
        markTestSkipped(
          'Platform cannot bind alternate loopback address: $error',
        );
        return;
      }
      final firstSubscription = first.listen((request) async {
        request.response.write('first');
        await request.response.close();
      });
      final secondSubscription = second.listen((request) async {
        request.response.write('second');
        await request.response.close();
      });
      final previous = {
        for (final key in ['proxy', 'enableDnsOverrides', 'dnsOverrides'])
          key: appdata.settings[key],
      };
      _setSettings({
        'proxy': 'direct',
        'enableDnsOverrides': true,
        'dnsOverrides': {'image-pool.invalid': '127.0.0.1'},
      });
      final url = 'http://image-pool.invalid:${first.port}/';
      try {
        expect(await _get(url), 'first');
        appdata.settings['dnsOverrides'] = {'image-pool.invalid': '127.0.0.2'};
        expect(await _get(url), 'second');
      } finally {
        _setSettings(previous);
        await first.close(force: true);
        await second.close(force: true);
        await firstSubscription.cancel();
        await secondSubscription.cancel();
      }
    },
    skip: skipNative,
  );

  register('pooled requests keep authentication headers isolated', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ports = <int>{};
    final subscription = server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      request.response.write(
        '${request.headers.value('authorization') ?? 'none'}|'
        '${request.headers.value('x-source') ?? 'none'}',
      );
      await request.response.close();
    });
    final oldProxy = appdata.settings['proxy'];
    appdata.settings['proxy'] = 'direct';
    final url = 'http://127.0.0.1:${server.port}/';
    try {
      expect(
        await _get(url, headers: {'authorization': 'test-a', 'x-source': 'a'}),
        'test-a|a',
      );
      expect(
        await _get(url, headers: {'authorization': 'test-b', 'x-source': 'b'}),
        'test-b|b',
      );
      expect(await _get(url), 'none|none');
      expect(ports.length, 1);
    } finally {
      appdata.settings['proxy'] = oldProxy;
      await server.close(force: true);
      await subscription.cancel();
    }
  }, skip: skipNative);

  register(
    'simultaneous first requests retain one reusable shared pool',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final initialPorts = <int>{};
      final reusedPorts = <int>{};
      final allStarted = Completer<void>();
      final allReusedStarted = Completer<void>();
      var started = 0;
      var reusedStarted = 0;
      final subscription = server.listen((request) async {
        if (request.uri.path == '/first') {
          initialPorts.add(request.connectionInfo!.remotePort);
          if (++started == 8) allStarted.complete();
          await allStarted.future;
        } else {
          reusedPorts.add(request.connectionInfo!.remotePort);
          if (++reusedStarted == 8) allReusedStarted.complete();
          await allReusedStarted.future;
        }
        request.response.write('ok');
        await request.response.close();
      });
      final previous = {
        for (final key in ['proxy', 'enableDnsOverrides', 'dnsOverrides'])
          key: appdata.settings[key],
      };
      // A new effective configuration forces the asynchronous client-creation
      // path even when another test already initialized the native bridge.
      _setSettings({
        'proxy': 'direct',
        'enableDnsOverrides': true,
        'dnsOverrides': {'concurrent-pool.invalid': '127.0.0.1'},
      });
      final url = 'http://concurrent-pool.invalid:${server.port}';
      try {
        expect(
          await Future.wait(List.generate(8, (_) => _get('$url/first'))),
          everyElement('ok'),
        );
        expect(initialPorts, isNotEmpty);
        expect(initialPorts.length, lessThanOrEqualTo(8));
        expect(
          await Future.wait(List.generate(8, (_) => _get('$url/reused'))),
          everyElement('ok'),
        );
        expect(reusedPorts.difference(initialPorts), isEmpty);
        if (device) {
          print(
            'PERFORMANCE_HTTP_CONCURRENT: first=${initialPorts.length}, reused=${reusedPorts.length}, new=0',
          );
        }
      } finally {
        if (!allStarted.isCompleted) allStarted.complete();
        if (!allReusedStarted.isCompleted) allReusedStarted.complete();
        _setSettings(previous);
        await server.close(force: true);
        await subscription.cancel();
      }
    },
    skip: skipNative,
  );
}
