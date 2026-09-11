import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_wire.dart';

class _WaitingAdapter implements HttpClientAdapter {
  final cancelled = Completer<void>();
  final response = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    cancelFuture?.then((_) => cancelled.complete());
    return response.future;
  }

  @override
  void close({bool force = false}) {
    if (!response.isCompleted) {
      response.complete(ResponseBody.fromString('', 200));
    }
  }
}

String _event(AgentJson delta, [String? finish]) =>
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    })}\r\n\r\n';

Stream<List<int>> _bytes(String content) =>
    Stream.fromIterable(utf8.encode(content).map((byte) => [byte]));

const _model = AgentModel(
  id: 'model',
  name: 'Test',
  baseUrl: 'https://example.invalid/v1',
  model: 'test-model',
);

void main() {
  test('SSE handles split UTF-8, CRLF, multiple tool indexes and usage', () async {
    final content =
        ': keepalive\r\n\r\n${_event({'content': '中文', 'reasoning_content': '考虑'})}${_event({
          'tool_calls': [
            {
              'index': 1,
              'id': 'b',
              'function': {'name': 'later_check', 'arguments': '{"comics":['},
            },
            {
              'index': 0,
              'id': 'a',
              'function': {'name': 'fav_', 'arguments': '{"comics":["jm:'},
            },
          ],
        })}${_event({
          'tool_calls': [
            {
              'index': 0,
              'function': {'name': 'check', 'arguments': '123"]}'},
            },
            {
              'index': 1,
              'function': {'arguments': '"jm:123"]}'},
            },
          ],
        }, 'tool_calls')}data: {"choices":[],"usage":{"total_tokens":123}}\r\n\r\ndata: [DONE]\r\n\r\n';
    final updates = <String>[];
    final result = await AgentClient.readResponse(
      _bytes(content),
      AgentRun(),
      (type, text) => updates.add('$type:$text'),
    );
    expect(result.text, '中文');
    expect(result.reasoning, '考虑');
    expect(result.tools.map((t) => t.id), ['a', 'b']);
    expect(result.tools.first.name, 'fav_check');
    expect(jsonDecode(result.tools.first.arguments), {
      'comics': ['jm:123'],
    });
    expect(updates, containsAll(['text:中文', 'reasoning:考虑']));
  });

  test(
    'SSE accepts multiline data events and non-stream JSON gateways',
    () async {
      final json = jsonEncode({
        'choices': [
          {
            'message': {'content': '完成', 'tool_calls': []},
            'finish_reason': 'stop',
          },
        ],
      });
      final full = await AgentClient.readResponse(
        _bytes(json),
        AgentRun(),
        (_, _) {},
      );
      expect(full.text, '完成');
      final stream =
          'data: {"choices": [\n'
          'data: {"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n';
      expect(
        (await AgentClient.readResponse(
          _bytes(stream),
          AgentRun(),
          (_, _) {},
        )).text,
        'ok',
      );
    },
  );

  test(
    'disconnected or length-truncated tool calls cannot reach dispatch',
    () async {
      for (final finish in [null, 'length']) {
        final event = _event({
          'tool_calls': [
            {
              'index': 0,
              'id': 'call',
              'function': {
                'name': 'later_add',
                'arguments': '{"comics":["jm:1"]}',
              },
            },
          ],
        }, finish);
        await expectLater(
          AgentClient.readResponse(_bytes(event), AgentRun(), (_, _) {}),
          throwsA(
            isA<AgentException>().having(
              (e) => e.code,
              'code',
              'INCOMPLETE_RESPONSE',
            ),
          ),
        );
      }
      await expectLater(
        AgentClient.readResponse(
          _bytes(
            _event({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call',
                  'function': {'name': 'later_add', 'arguments': '{"comics":'},
                },
              ],
            }, 'tool_calls'),
          ),
          AgentRun(),
          (_, _) {},
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('model patches cannot replace messages, model, tools, or stream', () {
    final model = AgentModel(
      id: 'm',
      name: 'test',
      baseUrl: 'https://example.invalid/v1/',
      model: 'actual',
      stream: false,
      extraBody: {
        'model': 'wrong',
        'messages': [],
        'tools': [],
        'stream': true,
        'n': 99,
      },
      thinkingLevels: const [
        AgentThinkingLevel(
          id: 'high',
          label: 'High',
          params: {'reasoning_effort': 'high', 'tool_choice': 'none'},
        ),
      ],
      defaultThinking: 'high',
    );
    final body = AgentClient.requestBody(
      model: model,
      thinkingId: 'high',
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: [
        {'type': 'function'},
      ],
    );
    expect(body['model'], 'actual');
    expect(body['messages'], isNotEmpty);
    expect(body['tools'], isNotEmpty);
    expect(body['tool_choice'], 'auto');
    expect(body['stream'], false);
    expect(body['reasoning_effort'], 'high');
    expect(body['n'], 1);
    expect(
      model.endpoint.toString(),
      'https://example.invalid/v1/chat/completions',
    );
    expect(
      const AgentModel(
        id: 'a',
        name: 'b',
        baseUrl: 'https://example.invalid/v1/chat/completions',
        model: 'c',
      ).endpoint.toString(),
      'https://example.invalid/v1/chat/completions',
    );
  });

  test('wire trims whole turns and pairs tool results with their calls', () {
    AgentMessage user(String id) => AgentMessage(
      id: id,
      conversationId: 'c',
      role: 'user',
      parts: [
        {'type': 'text', 'text': id},
      ],
      createdAt: 1,
    );
    final assistant = AgentMessage(
      id: 'a',
      conversationId: 'c',
      role: 'assistant',
      createdAt: 1,
      parts: [
        {'type': 'reasoning', 'text': 'private reasoning'},
        {
          'type': 'tool_call',
          'id': 'call',
          'name': 'showcase_comics',
          'arguments': {
            'comics': [
              {'source_key': 'jm', 'comic_id': '1', 'title': 'redundant'},
            ],
          },
          'state': 'done',
          'result': {
            'ok': true,
            'data': {'count': 1},
          },
        },
        {
          'type': 'tool_call',
          'id': 'pending',
          'name': 'later_add',
          'arguments': {
            'comics': ['jm:1'],
          },
          'state': 'interrupted',
        },
      ],
    );
    final history = [user('old'), user('new'), assistant];
    final wire = agentWire(history, _model, maxTurns: 1);
    expect(wire.map((m) => m['role']), [
      'system',
      'user',
      'assistant',
      'tool',
      'tool',
    ]);
    expect(wire[1]['content'], 'new');
    expect(wire[2].containsKey('reasoning_content'), false);
    expect((wire[2]['tool_calls'] as List).map((c) => c['id']), [
      'call',
      'pending',
    ]);
    expect(wire[3]['tool_call_id'], 'call');
    expect(jsonDecode(wire[4]['content'])['error']['code'], 'CANCELLED');
    expect(
      jsonDecode(
        wire[2]['tool_calls'][0]['function']['arguments'],
      )['comics'][0],
      {'source_key': 'jm', 'comic_id': '1'},
    );
    final withReasoning = AgentModel.fromJson({
      ..._model.toJson(),
      'include_reasoning_in_context': true,
    });
    expect(
      agentWire(
        history,
        withReasoning,
      ).where((m) => m['role'] == 'assistant').single['reasoning_content'],
      'private reasoning',
    );
  });

  test('large tool outputs remain valid JSON', () {
    final value = {
      'ok': true,
      'data': {
        'description': '长' * 30000,
        'items': List.generate(
          80,
          (i) => {'comic_id': i.toString(), 'title': 'x' * 600},
        ),
      },
    };
    final result = agentToolContent(value);
    expect(result.length, lessThanOrEqualTo(16000));
    expect(jsonDecode(result)['truncated'], true);
  });

  test(
    'header timeout cancels an adapter that does not enforce Dio timeouts',
    () async {
      final adapter = _WaitingAdapter();
      final client = AgentClient(
        dio: Dio()..httpClientAdapter = adapter,
        responseTimeout: const Duration(milliseconds: 100),
      );
      try {
        await expectLater(
          client.complete(
            model: _model,
            apiKey: '',
            thinkingId: null,
            messages: [],
            tools: [],
            run: AgentRun(),
            onDelta: (_, _) {},
          ),
          throwsA(
            isA<AgentException>().having((e) => e.code, 'code', 'TIMEOUT'),
          ),
        );
        await adapter.cancelled.future.timeout(const Duration(seconds: 2));
      } finally {
        client.close();
      }
    },
  );

  test(
    'HTTP client uses configured endpoint and reports cancellation without exposing keys',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      String? authorization;
      String? path;
      final subscription = server.listen((request) async {
        authorization = request.headers.value('authorization');
        path = request.uri.path;
        await utf8.decoder.bind(request).join();
        received.complete();
        // Leave the response waiting to exercise cancellation before headers.
      });
      final client = AgentClient(dio: Dio());
      final run = AgentRun();
      final model = AgentModel(
        id: 'm',
        name: 'test',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test',
      );
      try {
        final future = client.complete(
          model: model,
          apiKey: 'local-test-secret',
          thinkingId: null,
          messages: [
            {'role': 'user', 'content': 'test'},
          ],
          tools: [],
          run: run,
          onDelta: (_, _) {},
        );
        final expectation = expectLater(
          future,
          throwsA(
            isA<AgentException>().having((e) => e.code, 'code', 'CANCELLED'),
          ),
        );
        await received.future.timeout(const Duration(seconds: 5));
        run.cancel();
        await expectation.timeout(const Duration(seconds: 2));
        expect(authorization, 'Bearer local-test-secret');
        expect(path, '/v1/chat/completions');
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
