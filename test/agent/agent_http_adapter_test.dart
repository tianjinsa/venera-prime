import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_http_adapter.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'Agent transport compatibility',
    () {
      late Map<String, dynamic> settings;
      late Dio agent;

      setUp(() async {
        settings = jsonDecode(jsonEncode(appdata.toJson()));
        appdata.settings['proxy'] = 'direct';
        appdata.settings['enableDnsOverrides'] = false;
        await ensureRHttpInitialized();
        agent = Dio(
          BaseOptions(
            responseType: ResponseType.plain,
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (status) => status != null,
          ),
        )..httpClientAdapter = AgentHttpAdapter();
      });

      tearDown(() {
        agent.close(force: true);
        appdata.restoreMemorySnapshot(settings);
      });

      test(
        'Agent redirects stay disabled while comic requests follow them',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final received = <String>[];
          server.listen((request) async {
            received.add(request.uri.path);
            if (request.uri.path == '/redirect') {
              request.response.statusCode = HttpStatus.found;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/target',
              );
            }
            request.response.write(
              request.headers.value(HttpHeaders.authorizationHeader) ?? 'comic',
            );
            await request.response.close();
          });
          final url = 'http://127.0.0.1:${server.port}/redirect';
          final response = await agent.get<String>(
            url,
            options: Options(headers: {'Authorization': 'Bearer agent-test'}),
          );
          expect(response.statusCode, HttpStatus.found);
          expect(response.data, 'Bearer agent-test');
          expect(received, ['/redirect']);

          final comics = AppDio(BaseOptions(responseType: ResponseType.plain));
          addTearDown(() => comics.close(force: true));
          expect((await comics.get<String>(url)).data, 'comic');
          expect(received, ['/redirect', '/redirect', '/target']);
        },
      );

      test('Agent requests pick up DNS and proxy preference changes', () async {
        final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => direct.close(force: true));
        addTearDown(() => proxy.close(force: true));
        direct.listen((request) async {
          request.response.write('direct');
          await request.response.close();
        });
        proxy.listen((request) async {
          request.response.write('proxy');
          await request.response.close();
        });
        appdata.settings['enableDnsOverrides'] = true;
        appdata.settings['dnsOverrides'] = {'agent-merge.test': '127.0.0.1'};
        final url = 'http://agent-merge.test:${direct.port}/model';
        expect((await agent.get<String>(url)).data, 'direct');

        appdata.settings['proxy'] = '127.0.0.1:${proxy.port}';
        expect((await agent.get<String>(url)).data, 'proxy');
      });

      test('cancelling an Agent request keeps comic requests usable', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final started = Completer<void>();
        server.listen((request) async {
          if (request.uri.path == '/wait') {
            started.complete();
            return;
          }
          request.response.write('comic');
          await request.response.close();
        });
        final token = CancelToken();
        final request = agent.get<String>(
          'http://127.0.0.1:${server.port}/wait',
          cancelToken: token,
        );
        final cancelled = expectLater(
          request,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await started.future.timeout(const Duration(seconds: 5));
        token.cancel('test cancellation');
        await cancelled.timeout(const Duration(seconds: 5));
        final comics = AppDio(BaseOptions(responseType: ResponseType.plain));
        addTearDown(() => comics.close(force: true));
        expect(
          (await comics.get<String>(
            'http://127.0.0.1:${server.port}/comic',
          )).data,
          'comic',
        );
      });
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
