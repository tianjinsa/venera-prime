import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_model_discovery.dart';
import 'package:venera/agent/agent_models.dart';

class DiscoveryAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  bool cancelled = false;
  DiscoveryAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    cancelFuture?.then((_) => cancelled = true);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody modelListBody(Object data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
AgentModel discoveryModel(
  AgentProtocol protocol, [
  String url = 'https://provider.invalid/proxy/v1',
]) => AgentModel(
  id: 'test',
  name: 'test',
  model: 'test',
  protocol: protocol,
  baseUrl: url,
  headers: const {'X-Gateway': 'custom', 'anthropic-beta': 'test-beta'},
);
Matcher code(String value) =>
    throwsA(isA<AgentException>().having((e) => e.code, 'code', value));

void main() {
  for (final protocol in AgentProtocol.values) {
    test(
      '${protocol.id} normalizes full endpoints and forwards authentication',
      () async {
        final adapter = DiscoveryAdapter(
          (_) => modelListBody({
            'data': [
              {'id': 'model-1'},
            ],
          }),
        );
        final discovery = AgentModelDiscovery(
          dio: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(discovery.close);
        final models = await discovery.fetch(
          connection: discoveryModel(
            protocol,
            'https://provider.invalid/proxy/v1${protocol.path}/',
          ),
          apiKey: 'test-key',
          run: AgentRun(),
        );
        expect(models.single.id, 'model-1');
        final request = adapter.requests.single;
        expect(request.uri.path, '/proxy/v1/models');
        expect(request.method, 'GET');
        expect(request.followRedirects, false);
        expect(request.headers['X-Gateway'], 'custom');
        expect(request.headers['Accept'], 'application/json');
        if (protocol == AgentProtocol.messages) {
          expect(request.headers['x-api-key'], 'test-key');
          expect(request.headers['anthropic-version'], '2023-06-01');
          expect(request.headers['anthropic-beta'], 'test-beta');
          expect(request.headers.containsKey('Authorization'), false);
        } else {
          expect(request.headers['Authorization'], 'Bearer test-key');
        }
      },
    );
  }

  test(
    'parses common arrays and nested envelopes, preserves IDs and removes duplicates',
    () {
      final rows = [
        'exact-model',
        {'id': 'a:b/model@latest', 'display_name': '可读名称'},
        {'model': 'second'},
        {'name': 'third'},
        {'id': 'exact-model'},
        null,
        {'id': 3},
        {'id': ''},
      ];
      for (final raw in [
        rows,
        {'data': rows},
        {'models': rows},
        {'items': rows},
        {'results': rows},
        {
          'data': {'models': rows},
        },
      ]) {
        final result = AgentModelDiscovery.parse(raw);
        expect(result.map((m) => m.id), [
          'exact-model',
          'a:b/model@latest',
          'second',
          'third',
        ]);
        expect(result[1].name, '可读名称');
      }
      expect(AgentModelDiscovery.parse({'data': []}), isEmpty);
      expect(
        () => AgentModelDiscovery.parse({'error': 'denied'}),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentModelDiscovery.parse({
          'data': [null],
        }),
        throwsA(isA<AgentException>()),
      );
    },
  );

  test(
    'Anthropic reads all pages with after_id and deduplicates across pages',
    () async {
      final adapter = DiscoveryAdapter(
        (request) => modelListBody(
          request.uri.queryParameters['after_id'] == null
              ? {
                  'data': [
                    {'id': 'z', 'display_name': 'Z'},
                  ],
                  'last_id': 'z',
                  'has_more': true,
                }
              : {
                  'data': [
                    {'id': 'a'},
                    {'id': 'z'},
                  ],
                  'has_more': false,
                },
        ),
      );
      final discovery = AgentModelDiscovery(
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(discovery.close);
      final models = await discovery.fetch(
        connection: discoveryModel(AgentProtocol.messages),
        apiKey: '',
        run: AgentRun(),
      );
      expect(models.map((m) => m.id), ['a', 'z']);
      expect(adapter.requests[1].uri.queryParameters, {
        'limit': '100',
        'after_id': 'z',
      });
      expect(
        adapter.requests
            .singleWhere((r) => r.uri.queryParameters['after_id'] == null)
            .headers
            .containsKey('x-api-key'),
        false,
      );
    },
  );

  test(
    'invalid pagination cannot loop or silently return partial results',
    () async {
      for (final data in [
        {'data': [], 'has_more': true},
        {
          'data': [
            {'id': 'same'},
          ],
          'last_id': 'same',
          'has_more': true,
        },
      ]) {
        final adapter = DiscoveryAdapter((_) => modelListBody(data));
        final discovery = AgentModelDiscovery(
          dio: Dio()..httpClientAdapter = adapter,
        );
        await expectLater(
          discovery.fetch(
            connection: discoveryModel(AgentProtocol.messages),
            apiKey: '',
            run: AgentRun(),
          ),
          code('INVALID_MODEL_LIST'),
        );
        expect(adapter.requests.length, lessThanOrEqualTo(2));
        discovery.close();
      }
    },
  );

  test(
    'unsupported endpoints and auth errors leave manual configuration available without echoing secrets',
    () async {
      for (final status in [404, 405, 501, 401, 403]) {
        final adapter = DiscoveryAdapter(
          (_) => modelListBody({
            'error': 'test-secret custom-header-secret',
          }, status),
        );
        final discovery = AgentModelDiscovery(
          dio: Dio()..httpClientAdapter = adapter,
        );
        try {
          await discovery.fetch(
            connection: discoveryModel(AgentProtocol.chat),
            apiKey: 'test-secret',
            run: AgentRun(),
          );
          fail('must fail');
        } on AgentException catch (e) {
          expect(
            e.code,
            [404, 405, 501].contains(status)
                ? 'MODELS_UNSUPPORTED'
                : 'MODEL_LIST_FAILED',
          );
          expect(e.message, contains('手动填写'));
          expect(e.message, isNot(contains('secret')));
        } finally {
          discovery.close();
        }
      }
    },
  );

  test('cancels in-flight requests and bounds response wait', () async {
    final adapter = DiscoveryAdapter((_) => Completer<ResponseBody>().future);
    final discovery = AgentModelDiscovery(
      dio: Dio()..httpClientAdapter = adapter,
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(discovery.close);
    final run = AgentRun();
    final pending = discovery.fetch(
      connection: discoveryModel(AgentProtocol.chat),
      apiKey: '',
      run: run,
    );
    run.cancel();
    await expectLater(pending, code('CANCELLED'));
    await expectLater(
      discovery.fetch(
        connection: discoveryModel(AgentProtocol.chat),
        apiKey: '',
        run: AgentRun(),
      ),
      code('TIMEOUT'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(adapter.cancelled, true);
  });

  test('rejects invalid JSON and oversized bodies', () async {
    for (final body in ['<html>not JSON</html>', 'x' * (4 * 1024 * 1024 + 1)]) {
      final adapter = DiscoveryAdapter(
        (_) => ResponseBody.fromString(body, 200),
      );
      final discovery = AgentModelDiscovery(
        dio: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(
        discovery.fetch(
          connection: discoveryModel(AgentProtocol.chat),
          apiKey: '',
          run: AgentRun(),
        ),
        code(
          body.startsWith('<') ? 'INVALID_MODEL_LIST' : 'MODEL_LIST_TOO_LARGE',
        ),
      );
      discovery.close();
    }
  });
}
