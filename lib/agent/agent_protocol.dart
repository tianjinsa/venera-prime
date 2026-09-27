import 'dart:convert';
import 'agent_context.dart';
import 'agent_models.dart';

typedef AgentDelta = void Function(String type, String text);

class AgentToolCall {
  final String id;
  final String name;
  final String arguments;
  const AgentToolCall(this.id, this.name, this.arguments);
}

class AgentResponse {
  final String text;
  final String reasoning;
  final List<AgentToolCall> tools;
  final AgentUsage? usage;

  /// Provider-specific output that must be replayed verbatim in later
  /// requests, such as signed thinking blocks or encrypted reasoning items.
  final AgentJson? providerState;
  const AgentResponse(
    this.text,
    this.reasoning,
    this.tools, {
    this.usage,
    this.providerState,
  });
}

/// History messages are kept in the Chat Completions shape produced by
/// agentWire. Each protocol converts that shape into its own request body.
/// A `_provider` entry on an assistant message holds replay data for the
/// protocol that produced it and is never sent as a Chat field.
abstract final class AgentProtocolCodec {
  static const providerKey = '_provider';

  static AgentJson requestBody({
    required AgentModel model,
    required String? thinkingId,
    required List<AgentJson> messages,
    required List<AgentJson> tools,
  }) => switch (model.protocol) {
    AgentProtocol.chat => _chatBody(model, thinkingId, messages, tools),
    AgentProtocol.responses => _responsesBody(
      model,
      thinkingId,
      messages,
      tools,
    ),
    AgentProtocol.messages => _messagesBody(model, thinkingId, messages, tools),
  };

  static Map<String, String> headers(AgentModel model, String apiKey) => {
    if (model.protocol == AgentProtocol.messages)
      'anthropic-version': '2023-06-01',
    ...model.headers,
    'Content-Type': 'application/json',
    'Accept': model.stream ? 'text/event-stream' : 'application/json',
    if (apiKey.isNotEmpty)
      if (model.protocol == AgentProtocol.messages)
        'x-api-key': apiKey
      else
        'Authorization': 'Bearer $apiKey',
  };

  static AgentJson _base(AgentModel model, String? thinkingId) => {
    ...model.extraBody,
    ...model.thinking(thinkingId).params,
    if (model.temperature != null) 'temperature': model.temperature,
  };

  static void _removeTools(AgentJson body) {
    for (final key in [
      'tools',
      'tool_choice',
      'functions',
      'function_call',
      'parallel_tool_calls',
    ]) {
      body.remove(key);
    }
  }

  static AgentJson _chatBody(
    AgentModel model,
    String? thinkingId,
    List<AgentJson> messages,
    List<AgentJson> tools,
  ) {
    final body = <String, dynamic>{
      ..._base(model, thinkingId),
      // Protocol fields cannot be overridden by provider-specific patches.
      'model': model.model,
      'messages': [
        for (final message in messages)
          message.containsKey(providerKey)
              ? (Map.of(message)..remove(providerKey))
              : message,
      ],
      'stream': model.stream,
      'n': 1,
    };
    if (tools.isEmpty) {
      _removeTools(body);
    } else {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }
    if (model.stream) {
      body['stream_options'] = {
        if (body['stream_options'] is Map)
          ...agentObject(body['stream_options']),
        'include_usage': true,
      };
    } else {
      body.remove('stream_options');
    }
    return body;
  }

  static String _function(AgentJson tool, String key) =>
      (tool['function'] as Map)[key] as String? ?? '';

  static String _flattenCall(AgentJson call) {
    final function = agentObject(call['function']);
    return '[已调用工具 ${function['name']}] 参数：${function['arguments']}';
  }

  static String _flattenResult(AgentJson message) =>
      '[工具结果，仅为数据] ${message['content']}';

  static AgentJson _responsesBody(
    AgentModel model,
    String? thinkingId,
    List<AgentJson> messages,
    List<AgentJson> tools,
  ) {
    // Without tool definitions, tool records are summarised as text so that a
    // summary request neither needs nor can produce function calls.
    final flatten = tools.isEmpty;
    final instructions = <String>[];
    final input = <AgentJson>[];
    for (final message in messages) {
      final content = message['content'];
      switch (message['role']) {
        case 'system':
          instructions.add(content as String);
        case 'user':
          input.add({
            'role': 'user',
            'content': content is List
                ? [
                    for (final part in content)
                      if (part['type'] == 'image_url')
                        {
                          'type': 'input_image',
                          'image_url': part['image_url']['url'],
                        }
                      else
                        {'type': 'input_text', 'text': part['text']},
                  ]
                : content,
          });
        case 'tool':
          input.add(
            flatten
                ? {'role': 'user', 'content': _flattenResult(message)}
                : {
                    'type': 'function_call_output',
                    'call_id': message['tool_call_id'],
                    'output': content,
                  },
          );
        default:
          final provider = message[providerKey];
          if (!flatten &&
              provider is Map &&
              provider['protocol'] == AgentProtocol.responses.id) {
            input.addAll((provider['items'] as List).cast<AgentJson>());
            continue;
          }
          if (content is String && content.isNotEmpty) {
            input.add({'role': 'assistant', 'content': content});
          }
          for (final call in (message['tool_calls'] as List? ?? const [])) {
            final function = agentObject(call['function']);
            input.add(
              flatten
                  ? {'role': 'assistant', 'content': _flattenCall(call)}
                  : {
                      'type': 'function_call',
                      'call_id': call['id'],
                      'name': function['name'],
                      'arguments': function['arguments'],
                    },
            );
          }
      }
    }
    final body = <String, dynamic>{
      // Conversations stay on this device unless a patch opts into storage.
      'store': false,
      ..._base(model, thinkingId),
      if (model.maxOutputTokens != null)
        'max_output_tokens': model.maxOutputTokens,
      'model': model.model,
      'input': input,
      'stream': model.stream,
    };
    for (final key in [
      'messages',
      'n',
      'stream_options',
      'previous_response_id',
    ]) {
      body.remove(key);
    }
    if (instructions.isEmpty) {
      body.remove('instructions');
    } else {
      body['instructions'] = instructions.join('\n\n');
    }
    if (model.includeReasoning && body['store'] == false) {
      // Encrypted reasoning lets a stateless conversation continue a
      // reasoning model's chain of thought across tool calls.
      body['include'] = {
        ...(body['include'] as List? ?? const []),
        'reasoning.encrypted_content',
      }.toList();
    }
    if (tools.isEmpty) {
      _removeTools(body);
    } else {
      body['tools'] = [
        for (final tool in tools)
          {
            'type': 'function',
            'name': _function(tool, 'name'),
            'description': _function(tool, 'description'),
            'parameters': (tool['function'] as Map)['parameters'],
          },
      ];
      body['tool_choice'] = 'auto';
    }
    return body;
  }

  /// Anthropic tool IDs only allow letters, digits, underscores and hyphens.
  static String _toolId(Object? id) =>
      (id as String? ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  static AgentJson _messagesBody(
    AgentModel model,
    String? thinkingId,
    List<AgentJson> messages,
    List<AgentJson> tools,
  ) {
    final flatten = tools.isEmpty;
    final system = <String>[];
    final output = <AgentJson>[];
    void add(String role, List<AgentJson> blocks) {
      if (blocks.isEmpty) return;
      if (output.isEmpty && role == 'assistant') {
        // The first message must come from the user. A leading assistant
        // message is the compacted history record, which belongs in system.
        system.addAll(
          blocks.where((b) => b['type'] == 'text').map((b) => b['text']),
        );
        return;
      }
      if (output.isNotEmpty && output.last['role'] == role) {
        (output.last['content'] as List).addAll(blocks);
      } else {
        output.add({'role': role, 'content': blocks});
      }
    }

    AgentJson text(String value) => {'type': 'text', 'text': value};

    for (final message in messages) {
      final content = message['content'];
      switch (message['role']) {
        case 'system':
          system.add(content as String);
        case 'user':
          add('user', [
            if (content is String && content.isNotEmpty) text(content),
            if (content is List)
              for (final part in content)
                if (part['type'] == 'image_url')
                  _anthropicImage(part['image_url']['url'] as String)
                else if ((part['text'] as String? ?? '').isNotEmpty)
                  text(part['text'] as String),
          ]);
        case 'tool':
          add('user', [
            flatten
                ? text(_flattenResult(message))
                : {
                    'type': 'tool_result',
                    'tool_use_id': _toolId(message['tool_call_id']),
                    'content': content,
                  },
          ]);
        default:
          final provider = message[providerKey];
          if (!flatten &&
              provider is Map &&
              provider['protocol'] == AgentProtocol.messages.id) {
            add('assistant', [
              for (final block in provider['content'] as List)
                agentObject(block),
            ]);
            continue;
          }
          add('assistant', [
            if (content is String && content.isNotEmpty) text(content),
            for (final call in (message['tool_calls'] as List? ?? const []))
              flatten
                  ? text(_flattenCall(call))
                  : {
                      'type': 'tool_use',
                      'id': _toolId(call['id']),
                      'name': call['function']['name'],
                      'input': jsonDecode(
                        call['function']['arguments'] as String,
                      ),
                    },
          ]);
      }
    }
    final body = <String, dynamic>{
      ..._base(model, thinkingId),
      'model': model.model,
      'messages': output,
      'stream': model.stream,
    };
    for (final key in ['n', 'stream_options', 'input']) {
      body.remove(key);
    }
    if (system.isEmpty) {
      body.remove('system');
    } else {
      body['system'] = system.join('\n\n');
    }
    // Required by the protocol; thinking and the answer share this limit.
    body['max_tokens'] =
        model.maxOutputTokens ?? body['max_tokens'] ?? agentDefaultMaxTokens;
    if (tools.isEmpty) {
      _removeTools(body);
    } else {
      body['tools'] = [
        for (final tool in tools)
          {
            'name': _function(tool, 'name'),
            'description': _function(tool, 'description'),
            'input_schema': (tool['function'] as Map)['parameters'],
          },
      ];
      body['tool_choice'] = {'type': 'auto'};
    }
    return body;
  }

  static AgentJson _anthropicImage(String dataUrl) {
    final match = RegExp(r'^data:([^;,]+);base64,(.*)$').firstMatch(dataUrl);
    if (match == null) {
      return {
        'type': 'image',
        'source': {'type': 'url', 'url': dataUrl},
      };
    }
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': match.group(1),
        'data': match.group(2),
      },
    };
  }

  static AgentStreamState stream(AgentProtocol protocol, AgentDelta onDelta) =>
      switch (protocol) {
        AgentProtocol.chat => _ChatStream(onDelta),
        AgentProtocol.responses => _ResponsesStream(onDelta),
        AgentProtocol.messages => _MessagesStream(onDelta),
      };
}

/// Accumulates one model response from stream events or a complete body.
abstract class AgentStreamState {
  final AgentDelta onDelta;
  final _text = StringBuffer();
  final _reasoning = StringBuffer();
  AgentUsage? usage;
  AgentStreamState(this.onDelta);

  /// True once a terminal event was received and the stream can be closed.
  bool get done;

  void emit(String type, Object? value) {
    if (value == null) return;
    if (value is! String) {
      throw const FormatException('Expected text delta');
    }
    (type == 'text' ? _text : _reasoning).write(value);
    if (value.isNotEmpty) onDelta(type, value);
  }

  /// A raw SSE data payload. Chat Completions ends with a literal [DONE].
  void event(String data);

  /// A complete non-streaming response body.
  void full(AgentJson data);

  /// The semantic end of the response: 'stop', 'tool_calls', 'length' or null.
  String? get finish;
  List<AgentToolCall> calls();
  AgentJson? get providerState => null;

  AgentResponse result() => AgentResponse(
    _text.toString(),
    _reasoning.toString(),
    calls(),
    usage: usage,
    providerState: providerState,
  );

  static Never providerError(Object? error) {
    final message = error is Map
        ? error['message']
        : error is String
        ? error
        : null;
    throw AgentException(
      'MODEL_ERROR',
      message is String && message.trim().isNotEmpty
          ? '模型服务返回错误：${agentClip(message.trim(), 300)}'
          : '模型服务返回错误，请检查配置后重试',
    );
  }
}

String agentClip(String value, int length) =>
    value.length <= length ? value : '${value.substring(0, length)}…';

class _ToolFragments {
  String id = '';
  String name = '';
  String arguments = '';
}

List<AgentToolCall> _collectCalls(Map<int, _ToolFragments> fragments) {
  final calls = <AgentToolCall>[];
  final indexes = fragments.keys.toList()..sort();
  final ids = <String>{};
  for (final index in indexes) {
    final call = fragments[index]!;
    if (call.id.isEmpty || call.name.isEmpty || !ids.add(call.id)) {
      throw const FormatException('Incomplete or duplicate tool call');
    }
    final arguments = call.arguments.trim().isEmpty ? '{}' : call.arguments;
    agentObject(jsonDecode(arguments));
    calls.add(AgentToolCall(call.id, call.name, arguments));
  }
  return calls;
}

class _ChatStream extends AgentStreamState {
  final _fragments = <int, _ToolFragments>{};
  bool _done = false;
  String? _finish;
  _ChatStream(super.onDelta);

  @override
  bool get done => _done;
  @override
  String? get finish => _finish;

  @override
  void event(String data) {
    if (data == '[DONE]') {
      _done = true;
    } else {
      _ingest(agentObject(jsonDecode(data)));
    }
  }

  @override
  void full(AgentJson data) => _ingest(data, full: true);

  void _ingest(AgentJson data, {bool full = false}) {
    if (data['error'] != null) AgentStreamState.providerError(data['error']);
    // The final SSE usage event normally has no choices.
    usage = AgentUsage.fromResponse(data['usage']) ?? usage;
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return;
    final matching = choices.where(
      (c) => c is Map && (c['index'] == 0 || c['index'] == null),
    );
    if (matching.isEmpty) return;
    final choice = agentObject(matching.first);
    final delta = agentObject(choice[full ? 'message' : 'delta'] ?? {});
    emit('text', delta['content']);
    emit('reasoning', delta['reasoning_content'] ?? delta['reasoning']);
    if (delta['refusal'] is String) emit('text', delta['refusal']);
    final calls = delta['tool_calls'];
    if (calls is List) {
      for (var i = 0; i < calls.length; i++) {
        final call = agentObject(calls[i]);
        final index = full ? i : call['index'];
        if (index is! int || index < 0 || index >= 32) {
          throw const FormatException('Invalid tool index');
        }
        final buffer = _fragments.putIfAbsent(index, _ToolFragments.new);
        final id = call['id'] as String?;
        if (id != null && id != buffer.id) buffer.id += id;
        final function = agentObject(call['function'] ?? {});
        final name = function['name'] as String?;
        if (name != null && name != buffer.name) buffer.name += name;
        buffer.arguments += function['arguments'] as String? ?? '';
      }
    }
    _finish = choice['finish_reason'] as String? ?? _finish;
    if (full) _finish ??= _fragments.isEmpty ? 'stop' : 'tool_calls';
  }

  @override
  List<AgentToolCall> calls() => _collectCalls(_fragments);
}

/// OpenAI Responses: typed events, output items and function_call items.
class _ResponsesStream extends AgentStreamState {
  final _fragments = <int, _ToolFragments>{};
  final _items = <int, AgentJson>{};
  String? _status;
  String? _incomplete;
  int _summaryParts = 0;
  _ResponsesStream(super.onDelta);

  @override
  bool get done => _status != null;

  @override
  String? get finish => switch (_status) {
    'completed' => _fragments.isEmpty ? 'stop' : 'tool_calls',
    'incomplete' when _incomplete == 'max_output_tokens' => 'length',
    _ => null,
  };

  @override
  void event(String data) {
    if (data == '[DONE]') return;
    final event = agentObject(jsonDecode(data));
    final index = event['output_index'];
    switch (event['type']) {
      case 'response.output_text.delta' || 'response.refusal.delta':
        emit('text', event['delta']);
      case 'response.reasoning_summary_text.delta' ||
          'response.reasoning_text.delta':
        emit('reasoning', event['delta']);
      case 'response.reasoning_summary_part.added':
        if (_summaryParts++ > 0) emit('reasoning', '\n\n');
      case 'response.output_item.added':
        final item = agentObject(event['item']);
        if (item['type'] == 'function_call' && index is int) {
          _fragments[index] = _ToolFragments()
            ..id = item['call_id'] as String? ?? ''
            ..name = item['name'] as String? ?? ''
            ..arguments = item['arguments'] as String? ?? '';
        }
      case 'response.function_call_arguments.delta':
        if (index is int) {
          _fragments.putIfAbsent(index, _ToolFragments.new).arguments +=
              event['delta'] as String? ?? '';
        }
      case 'response.output_item.done':
        if (index is int) _item(index, agentObject(event['item']));
      case 'response.completed' || 'response.incomplete':
        _response(agentObject(event['response']));
      case 'response.failed':
        final response = event['response'];
        AgentStreamState.providerError(
          response is Map ? response['error'] : null,
        );
      case 'error':
        AgentStreamState.providerError(event['error'] ?? event);
    }
  }

  void _item(int index, AgentJson item) {
    _items[index] = item;
    if (item['type'] == 'function_call') {
      // The completed item is authoritative over streamed fragments.
      _fragments[index] = _ToolFragments()
        ..id = item['call_id'] as String? ?? ''
        ..name = item['name'] as String? ?? ''
        ..arguments = item['arguments'] as String? ?? '';
    }
  }

  void _response(AgentJson response) {
    if (response['error'] != null) {
      AgentStreamState.providerError(response['error']);
    }
    usage = AgentUsage.fromResponse(response['usage']) ?? usage;
    final output = response['output'];
    if (output is List && _items.isEmpty) {
      for (var i = 0; i < output.length; i++) {
        _item(i, agentObject(output[i]));
      }
    }
    _status = response['status'] as String? ?? 'completed';
    final details = response['incomplete_details'];
    _incomplete = details is Map ? details['reason'] as String? : null;
  }

  @override
  void full(AgentJson data) {
    final output = data['output'];
    if (output is List) {
      for (final raw in output) {
        final item = agentObject(raw);
        switch (item['type']) {
          case 'message':
            for (final part in item['content'] as List? ?? const []) {
              if (part is Map) emit('text', part['text'] ?? part['refusal']);
            }
          case 'reasoning':
            final summary = [
              for (final part in item['summary'] as List? ?? const [])
                if (part is Map && part['text'] is String) part['text'],
            ];
            emit('reasoning', summary.join('\n\n'));
        }
      }
    }
    _response(data);
  }

  @override
  List<AgentToolCall> calls() => _collectCalls(_fragments);

  @override
  AgentJson? get providerState {
    final indexes = _items.keys.toList()..sort();
    final items = [for (final i in indexes) _items[i]!];
    // Replay only matters when encrypted reasoning must accompany the calls.
    if (!items.any(
      (item) =>
          item['type'] == 'reasoning' && item['encrypted_content'] is String,
    )) {
      return null;
    }
    return {
      'protocol': AgentProtocol.responses.id,
      'items': [
        for (final item in items)
          switch (item['type']) {
            'reasoning' => {
              'type': 'reasoning',
              'id': item['id'],
              'summary': item['summary'] ?? const [],
              'encrypted_content': item['encrypted_content'],
            },
            'function_call' => {
              'type': 'function_call',
              'call_id': item['call_id'],
              'name': item['name'],
              'arguments': item['arguments'],
            },
            'message' => {
              'role': 'assistant',
              'content': [
                for (final part in item['content'] as List? ?? const [])
                  if (part is Map && part['text'] is String) part['text'],
              ].join(),
            },
            _ => null,
          },
      ].whereType<AgentJson>().toList(),
    };
  }
}

/// Anthropic Messages: indexed content blocks with typed deltas.
class _MessagesStream extends AgentStreamState {
  final _blocks = <int, AgentJson>{};
  final _json = <int, StringBuffer>{};
  final _usage = <String, dynamic>{};
  String? _stop;
  bool _done = false;
  _MessagesStream(super.onDelta);

  @override
  bool get done => _done;

  @override
  String? get finish => switch (_stop) {
    'end_turn' || 'stop_sequence' || 'refusal' =>
      _blocks.values.any((b) => b['type'] == 'tool_use')
          ? 'tool_calls'
          : 'stop',
    'tool_use' => 'tool_calls',
    'max_tokens' => 'length',
    _ => null,
  };

  void _mergeUsage(Object? value) {
    if (value is! Map) return;
    value.forEach((key, v) {
      if (v != null) _usage[key as String] = v;
    });
    usage = AgentUsage.fromResponse(_usage) ?? usage;
  }

  void _start(int index, AgentJson block) {
    final copy = Map<String, dynamic>.of(block);
    _blocks[index] = copy;
    switch (copy['type']) {
      case 'text':
        emit('text', copy['text']);
      case 'thinking':
        emit('reasoning', copy['thinking']);
      case 'tool_use':
        _json[index] = StringBuffer();
    }
  }

  @override
  void event(String data) {
    final event = agentObject(jsonDecode(data));
    final index = event['index'];
    switch (event['type']) {
      case 'message_start':
        _mergeUsage(agentObject(event['message'])['usage']);
      case 'content_block_start':
        if (index is int) _start(index, agentObject(event['content_block']));
      case 'content_block_delta':
        final block = index is int ? _blocks[index] : null;
        if (block == null) throw const FormatException('Unknown block');
        final delta = agentObject(event['delta']);
        switch (delta['type']) {
          case 'text_delta':
            block['text'] = '${block['text'] ?? ''}${delta['text']}';
            emit('text', delta['text']);
          case 'thinking_delta':
            block['thinking'] =
                '${block['thinking'] ?? ''}${delta['thinking']}';
            emit('reasoning', delta['thinking']);
          case 'signature_delta':
            block['signature'] =
                '${block['signature'] ?? ''}${delta['signature']}';
          case 'input_json_delta':
            _json[index]?.write(delta['partial_json'] as String? ?? '');
        }
      case 'content_block_stop':
        final block = index is int ? _blocks[index] : null;
        final json = index is int ? _json[index] : null;
        if (block != null && json != null) {
          final raw = json.toString().trim();
          block['input'] = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
        }
      case 'message_delta':
        _stop = agentObject(event['delta'])['stop_reason'] as String? ?? _stop;
        _mergeUsage(event['usage']);
      case 'message_stop':
        _done = true;
      case 'error':
        AgentStreamState.providerError(event['error']);
    }
  }

  @override
  void full(AgentJson data) {
    if (data['type'] == 'error') AgentStreamState.providerError(data['error']);
    final content = data['content'] as List? ?? const [];
    for (var i = 0; i < content.length; i++) {
      _start(i, agentObject(content[i]));
      _json.remove(i);
    }
    _stop = data['stop_reason'] as String?;
    _mergeUsage(data['usage']);
    _done = true;
  }

  List<AgentJson> get _ordered {
    final indexes = _blocks.keys.toList()..sort();
    return [for (final i in indexes) _blocks[i]!];
  }

  @override
  List<AgentToolCall> calls() {
    final fragments = <int, _ToolFragments>{};
    final blocks = _ordered;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block['type'] != 'tool_use') continue;
      fragments[i] = _ToolFragments()
        ..id = block['id'] as String? ?? ''
        ..name = block['name'] as String? ?? ''
        ..arguments = jsonEncode(block['input'] ?? const {});
    }
    return _collectCalls(fragments);
  }

  @override
  AgentJson? get providerState {
    final blocks = _ordered;
    // Signed thinking must be returned unchanged while tools are in use.
    if (!blocks.any(
      (b) => b['type'] == 'thinking' || b['type'] == 'redacted_thinking',
    )) {
      return null;
    }
    return {
      'protocol': AgentProtocol.messages.id,
      'content': [
        for (final block in blocks)
          switch (block['type']) {
            'thinking' => {
              'type': 'thinking',
              'thinking': block['thinking'] ?? '',
              'signature': block['signature'] ?? '',
            },
            'redacted_thinking' => {
              'type': 'redacted_thinking',
              'data': block['data'],
            },
            'text' when (block['text'] as String? ?? '').isNotEmpty => {
              'type': 'text',
              'text': block['text'],
            },
            'tool_use' => {
              'type': 'tool_use',
              'id': block['id'],
              'name': block['name'],
              'input': block['input'] ?? const {},
            },
            _ => null,
          },
      ].whereType<AgentJson>().toList(),
    };
  }
}
