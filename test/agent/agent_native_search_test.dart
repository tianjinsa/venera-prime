import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_protocol.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_wire.dart';

import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_test_support.dart';
import 'agent_web_search_fixtures.dart';

const _tools = <AgentJson>[
  {
    'type': 'function',
    'function': {
      'name': 'list_sources',
      'description': 'Sources',
      'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
    },
  },
];

AgentModel _model(AgentProtocol protocol, {bool native = true}) => AgentModel(
  id: protocol.id,
  name: '测试模型',
  baseUrl: 'https://example.org/v1',
  model: 'compatible-model',
  protocol: protocol,
  nativeWebSearch: native,
);

Future<AgentResponse> _response(
  AgentProtocol protocol,
  Object payload, {
  AgentDelta? delta,
}) => AgentClient.readResponse(
  Stream.value(utf8.encode(payload is String ? payload : jsonEncode(payload))),
  AgentRun(),
  delta ?? (_, _) {},
  protocol: protocol,
);

String _sse(List<AgentJson> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

const _openAiSearch = <String, dynamic>{
  'type': 'web_search_call',
  'id': 'ws1',
  'status': 'completed',
  'action': {
    'type': 'search',
    'queries': ['Prime'],
  },
};
const _openAiMessage = <String, dynamic>{
  'type': 'message',
  'id': 'm1',
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {
      'type': 'output_text',
      'text': '中文🙂事实。',
      'annotations': [
        {
          'type': 'url_citation',
          'start_index': 0,
          'end_index': 6,
          'url': 'https://example.org/prime',
          'title': 'Venera Prime',
        },
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final protocol in [AgentProtocol.responses, AgentProtocol.messages]) {
    test(
      '${protocol.id} native search coexists with functions and is absent from compaction',
      () {
        AgentJson body(bool enabled, List<AgentJson> tools) =>
            AgentClient.requestBody(
              model: _model(protocol, native: enabled),
              thinkingId: null,
              messages: const [
                {'role': 'user', 'content': 'Search'},
              ],
              tools: tools,
            );
        final enabled = body(true, _tools);
        final tools = enabled['tools'] as List;
        expect(tools, hasLength(2));
        expect(
          tools.first['type'],
          protocol == AgentProtocol.responses
              ? 'web_search'
              : 'web_search_20250305',
        );
        expect((body(false, _tools)['tools'] as List), hasLength(1));
        expect(body(true, const []), isNot(contains('tools')));
        expect(body(true, const []), isNot(contains('tool_choice')));
        if (protocol == AgentProtocol.responses) {
          expect(enabled['include'], contains('reasoning.encrypted_content'));
        } else {
          expect(tools.first['name'], 'web_search');
          expect(tools.first['max_uses'], 5);
        }
        final roundTrip = AgentModel.fromJson(_model(protocol).toJson());
        expect(roundTrip.protocol.supportsNativeWebSearch, true);
        expect(roundTrip.validate, returnsNormally);
        expect(roundTrip.nativeWebSearch, true);
      },
    );
  }

  test('Chat Completions cannot enable native search', () {
    expect(AgentProtocol.chat.supportsNativeWebSearch, false);
    expect(_model(AgentProtocol.chat).validate, throwsFormatException);
    expect(_model(AgentProtocol.chat, native: false).validate, returnsNormally);
  });

  test('explicit unversioned and DeepSeek Messages endpoints remain exact', () {
    expect(
      const AgentModel(
        id: 'r',
        name: 'r',
        baseUrl: 'https://example.org/responses',
        model: 'm',
        protocol: AgentProtocol.responses,
      ).endpoint.toString(),
      'https://example.org/responses',
    );
    expect(
      const AgentWebSearchSettings().deepseekSearchModel.endpoint.toString(),
      'https://api.deepseek.com/anthropic/v1/messages',
    );
  });

  test(
    'Responses native calls are not client tools and Unicode citations are inline',
    () async {
      final response = await _response(AgentProtocol.responses, {
        'status': 'completed',
        'output': [_openAiSearch, _openAiMessage],
      });
      expect(response.text, '中文🙂事实。');
      expect(
        response.displayText,
        '中文🙂事实。 [Venera Prime](<https://example.org/prime>)',
      );
      expect(response.tools, isEmpty);
      expect(response.nativeSearches.single['state'], 'done');
      expect(response.providerState!['items'], contains(equals(_openAiSearch)));
      expect(
        response.providerState!['items'],
        contains(equals(_openAiMessage)),
      );
    },
  );

  test(
    'Responses terminal output supplies authoritative citations after streaming',
    () async {
      final states = <String>[];
      final response = await _response(
        AgentProtocol.responses,
        _sse([
          {
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': _openAiSearch,
          },
          {
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': _openAiSearch,
          },
          {
            'type': 'response.output_text.delta',
            'output_index': 1,
            'delta': '中文🙂事实。',
          },
          {
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [_openAiSearch, _openAiMessage],
            },
          },
        ]),
        delta: (type, _) => states.add(type),
      );
      expect(states, contains('native_search'));
      expect(response.text, '中文🙂事实。');
      expect(response.displayText, contains('https://example.org/prime'));
      expect(response.nativeSearches, hasLength(1));
    },
  );

  test('Responses handles gateways emitting only terminal output', () async {
    final response = await _response(
      AgentProtocol.responses,
      _sse([
        {
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'output': [_openAiSearch, _openAiMessage],
          },
        },
      ]),
    );
    expect(response.text, '中文🙂事实。');
    expect(response.displayText, contains('https://example.org/prime'));
  });

  test(
    'Responses preserves native state together with ordinary function calls',
    () async {
      final response = await _response(AgentProtocol.responses, {
        'status': 'completed',
        'output': [
          _openAiSearch,
          _openAiMessage,
          {
            'type': 'function_call',
            'call_id': 'client1',
            'name': 'list_sources',
            'arguments': '{}',
          },
        ],
      });
      expect(response.tools.single.name, 'list_sources');
      final body = AgentClient.requestBody(
        model: _model(AgentProtocol.responses),
        thinkingId: null,
        tools: _tools,
        messages: [
          {'role': 'user', 'content': 'Search'},
          {
            'role': 'assistant',
            'content': response.text,
            AgentProtocolCodec.providerKey: response.providerState,
          },
          {'role': 'tool', 'tool_call_id': 'client1', 'content': '[]'},
        ],
      );
      expect(body['input'], contains(equals(_openAiSearch)));
      expect(
        (body['input'] as List).where((i) => i['type'] == 'function_call'),
        hasLength(1),
      );
    },
  );

  test(
    'Messages preserves encrypted results and citations without enabling reasoning',
    () async {
      final response = await _response(
        AgentProtocol.messages,
        deepseekSearchReply,
      );
      expect(response.tools, isEmpty);
      expect(
        response.providerState!['content'],
        deepseekSearchReply['content'],
      );
      expect(
        response.displayText,
        '找到漫画阅读器。 [Venera Prime](<https://example.org/prime>)',
      );
      final body = AgentClient.requestBody(
        model: _model(AgentProtocol.messages),
        thinkingId: null,
        tools: _tools,
        messages: [
          {'role': 'user', 'content': 'Search'},
          {
            'role': 'assistant',
            'content': response.text,
            AgentProtocolCodec.providerKey: response.providerState,
          },
          {'role': 'user', 'content': 'Continue'},
        ],
      );
      expect(
        (body['messages'] as List)[1]['content'],
        deepseekSearchReply['content'],
      );
    },
  );

  test(
    'Messages stream collects server tool input and citations_delta without client execution',
    () async {
      final response = await _response(
        AgentProtocol.messages,
        _sse([
          {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 10},
            },
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'server_tool_use',
              'id': 'srv_search',
              'name': 'web_search',
              'input': <String, dynamic>{},
            },
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"query":"Venera Prime"}',
            },
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': nativeSearchResult,
          },
          {'type': 'content_block_stop', 'index': 1},
          {
            'type': 'content_block_start',
            'index': 2,
            'content_block': {'type': 'text', 'text': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'text_delta', 'text': nativeCitedText['text']},
          },
          {
            'type': 'content_block_delta',
            'index': 2,
            'delta': {
              'type': 'citations_delta',
              'citation': (nativeCitedText['citations'] as List).single,
            },
          },
          {'type': 'content_block_stop', 'index': 2},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          },
          {'type': 'message_stop'},
        ]),
      );
      expect(response.tools, isEmpty);
      expect(response.providerState!['content'], [
        nativeSearchUse,
        nativeSearchResult,
        nativeCitedText,
      ]);
      expect(response.nativeSearches.single['state'], 'done');
      expect(response.displayText, contains('https://example.org/prime'));
    },
  );

  test('unsafe citation URLs are not turned into links', () async {
    final response = await _response(
      AgentProtocol.messages,
      deepseekReplyWith([
        {
          'type': 'text',
          'text': 'Answer',
          'citations': [
            {
              'type': 'web_search_result_location',
              'url': 'javascript:alert(1)',
              'title': 'Bad',
            },
            {
              'type': 'web_search_result_location',
              'url': 'https://user:pass@example.org/',
              'title': 'Bad',
            },
          ],
        },
      ]),
    );
    expect(response.displayText, isNull);
  });

  test(
    'native server errors stay visible and are never executed as app functions',
    () async {
      final response = await _response(
        AgentProtocol.messages,
        deepseekReplyWith([
          nativeSearchUse,
          {
            'type': 'web_search_tool_result',
            'tool_use_id': 'srv_search',
            'content': {
              'type': 'web_search_tool_result_error',
              'error_code': 'too_many_requests',
            },
          },
          {'type': 'text', 'text': 'Search failed.'},
        ]),
      );
      expect(response.tools, isEmpty);
      expect(response.nativeSearches.single['state'], 'failed');
    },
  );

  test(
    'controller continues a native-only pause and persists usable citations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'agent-native-search-',
      );
      configureAgentTestPaths(root.path);
      final store = await AgentStore.open('${root.path}/agent');
      final model = _model(AgentProtocol.messages);
      await store.saveSettings(AgentSettings(models: [model]), {});
      var round = 0;
      final client = ScriptedClient((_, messages, _, delta) async {
        if (round++ == 0) {
          return _response(
            AgentProtocol.messages,
            deepseekReplyWith([nativeSearchUse], stop: 'pause_turn'),
            delta: delta,
          );
        }
        final assistant = messages.singleWhere((m) => m['role'] == 'assistant');
        expect(assistant[AgentProtocolCodec.providerKey]['content'], [
          nativeSearchUse,
        ]);
        return _response(
          AgentProtocol.messages,
          deepseekReplyWith([nativeSearchResult, nativeCitedText]),
          delta: delta,
        );
      });
      final controller = AgentController(
        store,
        client: client,
        tools: AgentTools(store),
      );
      try {
        await controller.send('Search');
        expect(controller.error, isNull);
        expect(round, 2);
        expect(controller.messages.last.state, 'done');
        final saved = store.messages(controller.conversation.id);
        expect(saved.last.displayText, contains('https://example.org/prime'));
        expect(
          saved
              .expand((m) => m.parts)
              .where((p) => p['type'] == 'native_search')
              .single['state'],
          'done',
        );
        final wire = agentWire(saved, model);
        final raw = wire.last[AgentProtocolCodec.providerKey];
        expect(raw['content'], [nativeSearchResult, nativeCitedText]);
        final other = agentWire(saved, _model(AgentProtocol.responses));
        expect(other.last['content'], contains('https://example.org/prime'));
        expect(other.last.containsKey(AgentProtocolCodec.providerKey), false);
      } finally {
        controller.dispose();
        store.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'a stopped native pause resumes after restart without duplicate cards or compaction',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'agent-native-resume-',
      );
      configureAgentTestPaths(root.path);
      var store = await AgentStore.open('${root.path}/agent');
      final model = AgentModel.fromJson({
        ..._model(AgentProtocol.messages).toJson(),
        'context_window_tokens': 100,
      });
      await store.saveSettings(AgentSettings(models: [model]), {});
      var round = 0;
      final waiting = Completer<void>();
      final client = ScriptedClient((_, _, run, delta) async {
        if (round++ == 0) {
          return _response(AgentProtocol.messages, {
            ...deepseekReplyWith([nativeSearchUse], stop: 'pause_turn'),
            'usage': {'input_tokens': 95, 'output_tokens': 2},
          }, delta: delta);
        }
        waiting.complete();
        return run.wait(Completer<AgentResponse>().future);
      });
      var controller = AgentController(
        store,
        client: client,
        tools: AgentTools(store),
      );
      try {
        final task = controller.send('Search');
        await waiting.future;
        await controller.stopAndWait();
        await task;
        expect(
          controller.messages
              .expand((m) => m.parts)
              .where((p) => p['type'] == 'native_search')
              .single['state'],
          'interrupted',
        );
        controller.dispose();
        store = await AgentStore.open('${root.path}/agent');
        final resumed = ScriptedClient((_, messages, _, delta) async {
          expect(
            messages
                .where((m) => m.containsKey(AgentProtocolCodec.providerKey))
                .single[AgentProtocolCodec.providerKey]['content'],
            [nativeSearchUse],
          );
          return _response(
            AgentProtocol.messages,
            deepseekReplyWith([nativeSearchResult, nativeCitedText]),
            delta: delta,
          );
        });
        controller = AgentController(
          store,
          client: resumed,
          tools: AgentTools(store),
        );
        await controller.resume();
        expect(controller.error, isNull);
        expect(resumed.toolRequests, hasLength(1));
        expect(resumed.toolRequests.single, isNotEmpty);
        final searches = store
            .messages(controller.conversation.id)
            .expand((m) => m.parts)
            .where((p) => p['type'] == 'native_search');
        expect(searches, hasLength(1));
        expect(searches.single['state'], 'done');
      } finally {
        controller.dispose();
        store.close();
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'citation markup is rendered as a clickable source and provider state stays hidden',
    (tester) async {
      final response = (await tester.runAsync(
        () => _response(AgentProtocol.messages, deepseekSearchReply),
      ))!;
      final message = AgentMessage(
        id: 'm',
        conversationId: 'c',
        role: 'assistant',
        createdAt: 1,
        parts: [
          {
            'type': 'text',
            'text': response.text,
            'display_text': response.displayText,
          },
          {'type': 'provider_state', ...response.providerState!},
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentMessageParts(
              message: message,
              indices: const [0, 1],
              busy: false,
              canRetry: (_) => false,
              onRetry: (_) {},
              onShowcase: (_) {},
              hasUndo: (_) => false,
              onUndo: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(
        markdown.data,
        contains('[Venera Prime](<https://example.org/prime>)'),
      );
      expect(markdown.onTapLink, isNotNull);
      expect(find.textContaining('opaque-search'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
