import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_protocol.dart';
import 'package:venera/agent/agent_wire.dart';

Stream<List<int>> _bytes(String content) =>
    Stream.fromIterable(utf8.encode(content).map((byte) => [byte]));

String _sse(List<AgentJson> events) => [
  for (final event in events)
    'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n',
].join();

AgentModel _model(AgentProtocol protocol, {bool reasoning = false}) =>
    AgentModel(
      id: protocol.id,
      name: protocol.label,
      baseUrl: 'https://example.invalid/v1',
      model: 'test-model',
      protocol: protocol,
      includeReasoning: reasoning,
      supportsVision: true,
      extraBody: const {'messages': 'patched', 'input': 'patched'},
    );

const _parameters = {
  'type': 'object',
  'properties': {
    'folder': {'type': 'string'},
  },
};

const _tools = [
  {
    'type': 'function',
    'function': {
      'name': 'fav_add',
      'description': '加入收藏',
      'parameters': _parameters,
    },
  },
];

/// A task with a picture, a tool round and a supplement from the user.
List<AgentMessage> _history({AgentJson? provider}) => [
  AgentMessage(
    id: 'user',
    conversationId: 'c',
    role: 'user',
    createdAt: 1,
    parts: [
      {'type': 'text', 'text': '加入收藏'},
      {
        'type': 'image',
        'id': 'img',
        'name': 'a.png',
        'mime_type': 'image/png',
        'byte_length': 3,
      },
    ],
  ),
  AgentMessage(
    id: 'step',
    conversationId: 'c',
    role: 'assistant',
    createdAt: 2,
    modelId: provider == null ? null : provider['model'] as String,
    parts: [
      {'type': 'reasoning', 'text': '想一想'},
      {'type': 'text', 'text': '正在加入'},
      if (provider != null) {'type': 'provider_state', ...provider},
      {
        'type': 'tool_call',
        'id': 'call:1',
        'name': 'fav_add',
        'arguments': {'folder': '默认'},
        'state': 'done',
        'result': {'ok': true},
      },
    ],
  ),
  AgentMessage(
    id: 'more',
    conversationId: 'c',
    role: 'user',
    createdAt: 3,
    parts: [
      {'type': 'text', 'text': '顺便展示', 'follow_up_to': 'user'},
    ],
  ),
];

List<AgentJson> _wire(AgentModel model, {AgentJson? provider}) => agentWire(
  _history(provider: provider),
  model,
  imageDataUrl: (_, _) => 'data:image/png;base64,AAAA',
);

void main() {
  test('each protocol uses its own endpoint and authentication', () {
    for (final (protocol, path) in [
      (AgentProtocol.chat, '/v1/chat/completions'),
      (AgentProtocol.responses, '/v1/responses'),
      (AgentProtocol.messages, '/v1/messages'),
    ]) {
      final model = _model(protocol);
      expect(model.endpoint.path, path);
      // A full address of any protocol is used as the base address.
      for (final full in [
        'https://example.invalid/v1/chat/completions',
        'https://example.invalid/v1/responses/',
        'https://example.invalid/v1/messages',
      ]) {
        expect(
          AgentModel.fromJson({
            ...model.toJson(),
            'base_url': full,
          }).endpoint.toString(),
          'https://example.invalid$path',
        );
      }
    }
    expect(
      AgentModel.fromJson({
        ..._model(AgentProtocol.messages).toJson(),
        'base_url': 'https://api.anthropic.com',
      }).endpoint.toString(),
      'https://api.anthropic.com/v1/messages',
    );
    final anthropic = AgentProtocolCodec.headers(
      _model(AgentProtocol.messages),
      'secret',
    );
    expect(anthropic['x-api-key'], 'secret');
    expect(anthropic['anthropic-version'], '2023-06-01');
    expect(anthropic.containsKey('Authorization'), false);
    expect(
      AgentProtocolCodec.headers(
        _model(AgentProtocol.responses),
        'secret',
      )['Authorization'],
      'Bearer secret',
    );
    // Older configurations without a protocol keep using Chat Completions.
    final legacy = _model(AgentProtocol.chat).toJson()..remove('protocol');
    expect(AgentModel.fromJson(legacy).protocol, AgentProtocol.chat);
  });

  test('Responses requests map history, images, tools and results', () {
    final model = _model(AgentProtocol.responses);
    final body = AgentClient.requestBody(
      model: model,
      thinkingId: null,
      messages: _wire(model),
      tools: _tools,
    );
    expect(body['model'], 'test-model');
    expect(body['store'], false);
    expect(body.containsKey('messages'), false);
    expect(body['instructions'], agentSystemPrompt);
    expect(body['tools'], [
      {
        'type': 'function',
        'name': 'fav_add',
        'description': '加入收藏',
        'parameters': _parameters,
      },
    ]);
    expect(body['tool_choice'], 'auto');
    final input = body['input'] as List;
    expect(input[0], {
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': '加入收藏'},
        {'type': 'input_image', 'image_url': 'data:image/png;base64,AAAA'},
      ],
    });
    expect(input[1], {'role': 'assistant', 'content': '正在加入'});
    expect(input[2], {
      'type': 'function_call',
      'call_id': 'call:1',
      'name': 'fav_add',
      'arguments': '{"folder":"默认"}',
    });
    expect(input[3]['type'], 'function_call_output');
    expect(input[3]['call_id'], 'call:1');
    expect(input[4], {'role': 'user', 'content': '顺便展示'});
    expect(body.containsKey('include'), false);
    expect(
      AgentClient.requestBody(
        model: _model(AgentProtocol.responses, reasoning: true),
        thinkingId: null,
        messages: [],
        tools: _tools,
      )['include'],
      ['reasoning.encrypted_content'],
    );
  });

  test('Messages requests alternate roles and satisfy required fields', () {
    final model = AgentModel.fromJson({
      ..._model(AgentProtocol.messages).toJson(),
      'thinking_levels': [
        {
          'id': 'deep',
          'label': '深度',
          'params': {
            'thinking': {'type': 'enabled', 'budget_tokens': 4000},
          },
        },
      ],
      'default_thinking': 'deep',
    });
    final body = AgentClient.requestBody(
      model: model,
      thinkingId: 'deep',
      messages: _wire(model),
      tools: _tools,
    );
    expect(body['system'], agentSystemPrompt);
    expect(body['max_tokens'], 4000 + 8192);
    expect(body.containsKey('input'), false);
    expect(body['tool_choice'], {'type': 'auto'});
    expect(body['tools'], [
      {'name': 'fav_add', 'description': '加入收藏', 'input_schema': _parameters},
    ]);
    final messages = body['messages'] as List;
    expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
    expect(messages[0]['content'][1], {
      'type': 'image',
      'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'},
    });
    expect(messages[1]['content'], [
      {'type': 'text', 'text': '正在加入'},
      {
        'type': 'tool_use',
        'id': 'call_1',
        'name': 'fav_add',
        'input': {'folder': '默认'},
      },
    ]);
    // Tool results come first; the supplement joins the same user turn.
    expect(messages[2]['content'][0]['type'], 'tool_result');
    expect(messages[2]['content'][0]['tool_use_id'], 'call_1');
    expect(messages[2]['content'][1], {'type': 'text', 'text': '顺便展示'});
    expect(
      AgentClient.requestBody(
        model: AgentModel.fromJson({
          ...model.toJson(),
          'max_output_tokens': 20000,
        }),
        thinkingId: null,
        messages: [],
        tools: _tools,
      )['max_tokens'],
      20000,
    );
  });

  test('summary requests flatten tool records for both new protocols', () {
    for (final protocol in [AgentProtocol.responses, AgentProtocol.messages]) {
      final model = _model(protocol);
      final body = AgentClient.requestBody(
        model: model,
        thinkingId: null,
        messages: [
          ..._wire(model),
          {'role': 'user', 'content': '请总结'},
        ],
        tools: const [],
      );
      final encoded = jsonEncode(body);
      expect(body.containsKey('tools'), false, reason: protocol.id);
      expect(encoded.contains('function_call'), false, reason: protocol.id);
      expect(encoded.contains('tool_use'), false, reason: protocol.id);
      expect(encoded, contains('fav_add'));
    }
  });

  test('a compacted summary becomes Messages system context', () {
    final model = _model(AgentProtocol.messages);
    final body = AgentClient.requestBody(
      model: model,
      thinkingId: null,
      messages: [
        {'role': 'system', 'content': '系统'},
        {'role': 'assistant', 'content': '<conversation_summary>'},
        {'role': 'user', 'content': '继续'},
      ],
      tools: _tools,
    );
    expect(body['system'], '系统\n\n<conversation_summary>');
    expect(body['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '继续'},
        ],
      },
    ]);
  });

  test(
    'Responses streams text, reasoning, calls, usage and replay items',
    () async {
      final deltas = <String>[];
      final result = await AgentClient.readResponse(
        _bytes(
          _sse([
            {'type': 'response.created', 'response': {}},
            {
              'type': 'response.output_item.added',
              'output_index': 0,
              'item': {'type': 'reasoning', 'id': 'rs_1'},
            },
            {
              'type': 'response.reasoning_summary_part.added',
              'output_index': 0,
            },
            {
              'type': 'response.reasoning_summary_text.delta',
              'output_index': 0,
              'delta': '先查',
            },
            {
              'type': 'response.reasoning_summary_part.added',
              'output_index': 0,
            },
            {
              'type': 'response.reasoning_summary_text.delta',
              'output_index': 0,
              'delta': '再加',
            },
            {
              'type': 'response.output_item.done',
              'output_index': 0,
              'item': {
                'type': 'reasoning',
                'id': 'rs_1',
                'summary': [
                  {'type': 'summary_text', 'text': '先查'},
                ],
                'encrypted_content': 'SECRET',
              },
            },
            {
              'type': 'response.output_text.delta',
              'output_index': 1,
              'delta': '好的',
            },
            {
              'type': 'response.output_item.done',
              'output_index': 1,
              'item': {
                'type': 'message',
                'id': 'msg_1',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '好的'},
                ],
              },
            },
            {
              'type': 'response.output_item.added',
              'output_index': 2,
              'item': {
                'type': 'function_call',
                'call_id': 'call_9',
                'name': 'fav_add',
                'arguments': '',
              },
            },
            {
              'type': 'response.function_call_arguments.delta',
              'output_index': 2,
              'delta': '{"folder":',
            },
            {
              'type': 'response.function_call_arguments.delta',
              'output_index': 2,
              'delta': '"默认"}',
            },
            {
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'usage': {
                  'input_tokens': 100,
                  'input_tokens_details': {'cached_tokens': 40},
                  'output_tokens': 20,
                  'total_tokens': 120,
                },
              },
            },
          ]),
        ),
        AgentRun(),
        (type, text) => deltas.add('$type:$text'),
        protocol: AgentProtocol.responses,
      );
      expect(deltas, [
        'reasoning:先查',
        'reasoning:\n\n',
        'reasoning:再加',
        'text:好的',
      ]);
      expect(result.text, '好的');
      expect(result.tools.single.id, 'call_9');
      expect(jsonDecode(result.tools.single.arguments), {'folder': '默认'});
      expect(result.usage!.inputTokens, 100);
      expect(result.usage!.cachedTokens, 40);
      expect(result.usage!.totalTokens, 120);
      expect(result.providerState!['items'], [
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'summary': [
            {'type': 'summary_text', 'text': '先查'},
          ],
          'encrypted_content': 'SECRET',
        },
        {'role': 'assistant', 'content': '好的'},
      ]);

      // Replay uses the stored items for the same model, then the call results.
      final model = _model(AgentProtocol.responses, reasoning: true);
      final provider = {...result.providerState!, 'model': model.id};
      final replay =
          AgentClient.requestBody(
                model: model,
                thinkingId: null,
                messages: _wire(model, provider: provider),
                tools: _tools,
              )['input']
              as List;
      expect(replay[1]['type'], 'reasoning');
      expect(replay[1]['encrypted_content'], 'SECRET');
      expect(replay[2], {'role': 'assistant', 'content': '好的'});
      expect(replay[3]['type'], 'function_call_output');
      // Another model cannot receive encrypted reasoning it did not produce.
      final other = AgentModel.fromJson({...model.toJson(), 'id': 'other'});
      expect(
        jsonEncode(
          AgentClient.requestBody(
            model: other,
            thinkingId: null,
            messages: _wire(other, provider: provider),
            tools: _tools,
          ),
        ),
        isNot(contains('SECRET')),
      );
    },
  );

  test('Responses incomplete, failed and non-stream bodies', () async {
    Future<AgentResponse> read(String body) => AgentClient.readResponse(
      _bytes(body),
      AgentRun(),
      (_, _) {},
      protocol: AgentProtocol.responses,
    );
    await expectLater(
      read(
        _sse([
          {
            'type': 'response.incomplete',
            'response': {
              'status': 'incomplete',
              'incomplete_details': {'reason': 'max_output_tokens'},
            },
          },
        ]),
      ),
      throwsA(
        isA<AgentException>()
            .having((e) => e.code, 'code', 'INCOMPLETE_RESPONSE')
            .having((e) => e.message, 'message', contains('输出上限')),
      ),
    );
    await expectLater(
      read(
        _sse([
          {
            'type': 'response.failed',
            'response': {
              'status': 'failed',
              'error': {'message': 'model overloaded'},
            },
          },
        ]),
      ),
      throwsA(
        isA<AgentException>().having(
          (e) => e.message,
          'message',
          contains('model overloaded'),
        ),
      ),
    );
    final full = await read(
      jsonEncode({
        'status': 'completed',
        'error': null,
        'output': [
          {
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': '总结'},
            ],
          },
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': '完成'},
            ],
          },
          {
            'type': 'function_call',
            'call_id': 'c1',
            'name': 'later_list',
            'arguments': '{}',
          },
        ],
        'usage': {'input_tokens': 5, 'output_tokens': 2, 'total_tokens': 7},
      }),
    );
    expect(full.text, '完成');
    expect(full.reasoning, '总结');
    expect(full.tools.single.name, 'later_list');
    expect(full.usage!.totalTokens, 7);
  });

  test('Messages streams blocks, signatures, tool input and usage', () async {
    final deltas = <String>[];
    final result = await AgentClient.readResponse(
      _bytes(
        _sse([
          {
            'type': 'message_start',
            'message': {
              'usage': {
                'input_tokens': 10,
                'cache_read_input_tokens': 90,
                'cache_creation_input_tokens': 5,
                'output_tokens': 1,
              },
            },
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking', 'thinking': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': '需要收藏'},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'SIG'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {'type': 'ping'},
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {'type': 'text', 'text': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': '马上'},
          },
          {'type': 'content_block_stop', 'index': 1},
          {
            'type': 'content_block_start',
            'index': 2,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'fav_add',
              'input': {},
            },
          },
          {
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"fol'},
          },
          {
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'input_json_delta', 'partial_json': 'der":"A"}'},
          },
          {'type': 'content_block_stop', 'index': 2},
          {
            'type': 'content_block_start',
            'index': 3,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_2',
              'name': 'later_list',
              'input': {},
            },
          },
          {'type': 'content_block_stop', 'index': 3},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 30},
          },
          {'type': 'message_stop'},
        ]),
      ),
      AgentRun(),
      (type, text) => deltas.add('$type:$text'),
      protocol: AgentProtocol.messages,
    );
    expect(deltas, ['reasoning:需要收藏', 'text:马上']);
    expect(result.tools.map((t) => t.id), ['toolu_1', 'toolu_2']);
    expect(jsonDecode(result.tools.first.arguments), {'folder': 'A'});
    expect(jsonDecode(result.tools.last.arguments), <String, dynamic>{});
    // Cache reads and writes are separate from input_tokens in this layout.
    expect(result.usage!.inputTokens, 105);
    expect(result.usage!.cachedTokens, 90);
    expect(result.usage!.outputTokens, 30);
    expect(result.usage!.totalTokens, 135);
    final content = result.providerState!['content'] as List;
    expect(content.first, {
      'type': 'thinking',
      'thinking': '需要收藏',
      'signature': 'SIG',
    });
    expect(content.map((b) => b['type']), [
      'thinking',
      'text',
      'tool_use',
      'tool_use',
    ]);

    final model = _model(AgentProtocol.messages);
    final provider = {...result.providerState!, 'model': model.id};
    final messages =
        AgentClient.requestBody(
              model: model,
              thinkingId: null,
              messages: _wire(model, provider: provider),
              tools: _tools,
            )['messages']
            as List;
    expect(messages[1]['content'], content);
  });

  test(
    'Messages stop reasons, refusals, errors and non-stream bodies',
    () async {
      Future<AgentResponse> read(String body) => AgentClient.readResponse(
        _bytes(body),
        AgentRun(),
        (_, _) {},
        protocol: AgentProtocol.messages,
      );
      String stopped(String reason) => _sse([
        {
          'type': 'message_start',
          'message': {'usage': <String, dynamic>{}},
        },
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': '部分'},
        },
        {'type': 'content_block_stop', 'index': 0},
        {
          'type': 'message_delta',
          'delta': {'stop_reason': reason},
        },
        {'type': 'message_stop'},
      ]);
      expect((await read(stopped('end_turn'))).text, '部分');
      expect((await read(stopped('refusal'))).text, '部分');
      await expectLater(
        read(stopped('max_tokens')),
        throwsA(
          isA<AgentException>().having(
            (e) => e.message,
            'message',
            contains('输出上限'),
          ),
        ),
      );
      await expectLater(
        read(
          _sse([
            {
              'type': 'error',
              'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
            },
          ]),
        ),
        throwsA(
          isA<AgentException>().having(
            (e) => e.message,
            'message',
            contains('Overloaded'),
          ),
        ),
      );
      final full = await read(
        jsonEncode({
          'type': 'message',
          'content': [
            {'type': 'thinking', 'thinking': '想', 'signature': 's'},
            {'type': 'text', 'text': '好'},
            {
              'type': 'tool_use',
              'id': 'toolu_x',
              'name': 'later_list',
              'input': {'page': 2},
            },
          ],
          'stop_reason': 'tool_use',
          'usage': {'input_tokens': 3, 'output_tokens': 4},
        }),
      );
      expect(full.reasoning, '想');
      expect(full.text, '好');
      expect(jsonDecode(full.tools.single.arguments), {'page': 2});
      expect(full.usage!.totalTokens, 7);
      expect(full.providerState, isNotNull);
    },
  );

  test(
    'HTTP errors include a bounded provider message without the key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? key;
      String? version;
      final subscription = server.listen((request) async {
        key = request.headers.value('x-api-key');
        version = request.headers.value('anthropic-version');
        await utf8.decoder.bind(request).join();
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'type': 'error',
            'error': {
              'type': 'invalid_request_error',
              'message': 'max_tokens: bad value for key local-test-secret',
            },
          }),
        );
        await request.response.close();
      });
      final client = AgentClient(dio: Dio());
      try {
        await expectLater(
          client.complete(
            model: AgentModel(
              id: 'm',
              name: 'test',
              baseUrl: 'http://127.0.0.1:${server.port}/v1',
              model: 'test',
              protocol: AgentProtocol.messages,
            ),
            apiKey: 'local-test-secret',
            thinkingId: null,
            messages: [
              {'role': 'user', 'content': 'test'},
            ],
            tools: const [],
            run: AgentRun(),
            onDelta: (_, _) {},
          ),
          throwsA(
            isA<AgentException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('HTTP 400'),
                contains('max_tokens: bad value for key ***'),
                isNot(contains('local-test-secret')),
              ),
            ),
          ),
        );
        expect(key, 'local-test-secret');
        expect(version, '2023-06-01');
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
