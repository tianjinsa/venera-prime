import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_model_catalog.dart';
import 'package:venera/agent/agent_models.dart';

/// Serves scripted responses so the list request needs no network.
class _ScriptedAdapter implements HttpClientAdapter {
  final requests = <String>[];
  final headers = <Map<String, String>>[];
  final responses = <(int, String)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    headers.add({
      for (final entry in options.headers.entries)
        entry.key.toLowerCase(): '${entry.value}',
    });
    final next = responses.isEmpty ? (404, '{}') : responses.removeAt(0);
    return ResponseBody.fromString(
      next.$2,
      next.$1,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const openAi = AgentModel(
    id: 'm',
    name: 'test',
    baseUrl: 'https://api.example.invalid/v1',
    model: 'test',
  );

  group('model identifiers', () {
    test('endpoints are derived from the configured base address', () {
      expect(
        AgentModelCatalogClient.endpoints(
          'https://api.example.invalid/v1',
          AgentProtocol.chat,
        ).map((uri) => uri.toString()),
        ['https://api.example.invalid/v1/models'],
      );
      // Anthropic's address is versioned under /v1 when the base is bare, so
      // only that path is tried.
      expect(
        AgentModelCatalogClient.endpoints(
          'https://api.example.invalid',
          AgentProtocol.messages,
        ).map((uri) => uri.toString()),
        ['https://api.example.invalid/v1/models'],
      );
      // An unversioned Chat base is also tried under /v1, because some
      // gateways only implement one of the two paths.
      expect(
        AgentModelCatalogClient.endpoints(
          'https://api.example.invalid',
          AgentProtocol.chat,
        ).map((uri) => uri.toString()),
        [
          'https://api.example.invalid/models',
          'https://api.example.invalid/v1/models',
        ],
      );
      // A complete endpoint is accepted as a base address.
      expect(
        AgentModelCatalogClient.endpoints(
          'https://api.example.invalid/v1/chat/completions',
          AgentProtocol.chat,
        ).first.toString(),
        'https://api.example.invalid/v1/models',
      );
    });

    test('all common response shapes reduce to unique identifiers', () {
      expect(
        AgentModelCatalogClient.parseModels({
          'data': [
            {'id': 'gpt-4o', 'object': 'model'},
            {'id': 'gpt-4o-mini'},
            {'id': 'gpt-4o'},
          ],
        }),
        ['gpt-4o', 'gpt-4o-mini'],
      );
      expect(
        AgentModelCatalogClient.parseModels({
          'models': [
            {'name': 'claude-sonnet'},
            {'name': 'claude-haiku'},
          ],
        }),
        ['claude-sonnet', 'claude-haiku'],
      );
      expect(
        AgentModelCatalogClient.parseModels({
          'result': ['qwen-max', '  '],
        }),
        ['qwen-max'],
      );
      expect(AgentModelCatalogClient.parseModels({'foo': []}), isEmpty);
      expect(AgentModelCatalogClient.parseModels(42), isEmpty);
    });

    test('the list request uses the protocol authentication and key', () async {
      final adapter = _ScriptedAdapter()
        ..responses.add((
          200,
          jsonEncode({
            'data': [
              {'id': 'a-model'},
            ],
          }),
        ));
      final catalog = AgentModelCatalogClient(
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      final ids = await catalog.listModels(
        baseUrl: openAi.baseUrl,
        protocol: AgentProtocol.chat,
        apiKey: 'local-test-key',
      );
      expect(ids, ['a-model']);
      expect(adapter.requests, ['https://api.example.invalid/v1/models']);
      expect(adapter.headers.single['authorization'], 'Bearer local-test-key');
    });

    test('Anthropic lists use x-api-key and follow last_id pages', () async {
      final adapter = _ScriptedAdapter()
        ..responses.addAll([
          (
            200,
            jsonEncode({
              'data': [
                {'id': 'claude-a'},
              ],
              'has_more': true,
              'last_id': 'claude-a',
            }),
          ),
          (
            200,
            jsonEncode({
              'data': [
                {'id': 'claude-b'},
              ],
              'has_more': false,
            }),
          ),
        ]);
      final catalog = AgentModelCatalogClient(
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      final ids = await catalog.listModels(
        baseUrl: 'https://api.example.invalid/v1',
        protocol: AgentProtocol.messages,
        apiKey: 'local-test-key',
      );
      expect(ids, ['claude-a', 'claude-b']);
      expect(adapter.headers.first['x-api-key'], 'local-test-key');
      expect(adapter.headers.first['anthropic-version'], '2023-06-01');
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last, contains('after_id=claude-a'));
    });

    test(
      'the versioned fallback is used only when the base lacks one',
      () async {
        final adapter = _ScriptedAdapter()
          ..responses.addAll([
            (404, '{}'),
            (
              200,
              jsonEncode({
                'data': [
                  {'id': 'local-model'},
                ],
              }),
            ),
          ]);
        final catalog = AgentModelCatalogClient(
          createDio: () => Dio()..httpClientAdapter = adapter,
        );
        final ids = await catalog.listModels(
          baseUrl: 'http://127.0.0.1:1234',
          protocol: AgentProtocol.chat,
        );
        expect(ids, ['local-model']);
        expect(adapter.requests, [
          'http://127.0.0.1:1234/models',
          'http://127.0.0.1:1234/v1/models',
        ]);
      },
    );

    test(
      'missing endpoints, bad keys and invalid bodies are reported',
      () async {
        Future<AgentException> failure(List<(int, String)> script) async {
          final adapter = _ScriptedAdapter()..responses.addAll(script);
          final catalog = AgentModelCatalogClient(
            createDio: () => Dio()..httpClientAdapter = adapter,
          );
          try {
            await catalog.listModels(
              baseUrl: 'https://api.example.invalid/v1',
              protocol: AgentProtocol.chat,
            );
            fail('expected a failure');
          } on AgentException catch (e) {
            return e;
          }
        }

        expect((await failure([(404, '{}')])).code, 'MODEL_LIST_UNSUPPORTED');
        expect((await failure([(401, '{}')])).code, 'MODEL_LIST_AUTH_FAILED');
        expect(
          (await failure([(200, '<html></html>')])).code,
          'MODEL_LIST_INVALID',
        );
        expect(
          (await failure([(200, '{"data":[]}')])).code,
          'MODEL_LIST_INVALID',
        );
        expect((await failure([(500, '{}')])).code, 'MODEL_LIST_FAILED');
      },
    );

    test('a request never carries the key into its error message', () async {
      final adapter = _ScriptedAdapter()..responses.add((401, '{}'));
      final catalog = AgentModelCatalogClient(
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      try {
        await catalog.listModels(
          baseUrl: openAi.baseUrl,
          protocol: AgentProtocol.chat,
          apiKey: 'local-test-key',
        );
        fail('expected a failure');
      } on AgentException catch (e) {
        expect(e.message, isNot(contains('local-test-key')));
      }
    });
  });
}
