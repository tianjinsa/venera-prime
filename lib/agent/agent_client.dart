import 'dart:async';
import 'dart:convert';

import 'package:venera/network/app_dio.dart';
import 'agent_models.dart';
import 'agent_http_adapter.dart';

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
  const AgentResponse(this.text, this.reasoning, this.tools);
}

class _ToolFragments {
  String id = '';
  String name = '';
  String arguments = '';
}

/// Intentionally does not use AppDio interceptors or log request contents.
class AgentClient {
  final Dio _dio;
  final Duration responseTimeout;
  AgentClient({Dio? dio, this.responseTimeout = const Duration(seconds: 60)})
    : _dio = dio ?? Dio() {
    if (dio == null) _dio.httpClientAdapter = AgentHttpAdapter();
    _dio.options.connectTimeout = const Duration(seconds: 20);
  }

  static AgentJson requestBody({
    required AgentModel model,
    required String? thinkingId,
    required List<AgentJson> messages,
    required List<AgentJson> tools,
  }) => {
    ...model.extraBody,
    ...model.thinking(thinkingId).params,
    if (model.temperature != null) 'temperature': model.temperature,
    // Protocol fields cannot be overridden by provider-specific patches.
    'model': model.model,
    'messages': messages,
    'tools': tools,
    'tool_choice': 'auto',
    'stream': model.stream,
    'n': 1,
  };

  Future<AgentResponse> complete({
    required AgentModel model,
    required String apiKey,
    required String? thinkingId,
    required List<AgentJson> messages,
    required List<AgentJson> tools,
    required AgentRun run,
    required AgentDelta onDelta,
  }) async {
    model.validate();
    run.check();
    final cancel = CancelToken();
    unawaited(run.whenCancelled.then((_) => cancel.cancel('Stopped')));
    try {
      // Some adapters only enforce receiveTimeout after headers arrive.
      // Bound the entire first response wait, then cancel the transport below.
      final response = await run.wait(
        _dio.postUri<ResponseBody>(
          model.endpoint,
          data: requestBody(
            model: model,
            thinkingId: thinkingId,
            messages: messages,
            tools: tools,
          ),
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            receiveTimeout: responseTimeout,
            headers: {
              ...model.headers,
              'Content-Type': 'application/json',
              'Accept': model.stream ? 'text/event-stream' : 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          ),
        ),
        timeout: responseTimeout,
      );
      run.check();
      if (response.data == null) {
        throw const AgentException('EMPTY_RESPONSE', '模型服务返回了空响应');
      }
      return await readResponse(
        response.data!.stream.cast<List<int>>(),
        run,
        onDelta,
      );
    } on DioException catch (e) {
      if (run.isCancelled || CancelToken.isCancel(e)) {
        throw const AgentException('CANCELLED', '已停止等待');
      }
      final status = e.response?.statusCode;
      throw AgentException(
        'MODEL_REQUEST_FAILED',
        status == null
            ? '模型连接失败或超时，请检查网络和 API 地址'
            : '模型服务返回 HTTP $status，请检查密钥、模型名称和接口配置',
      );
    } on FormatException {
      throw const AgentException('INVALID_RESPONSE', '模型响应格式不完整或不兼容');
    } finally {
      // Also closes an unfinished body after parser errors or timeouts.
      if (!cancel.isCancelled) cancel.cancel('Request finished');
    }
  }

  /// Also accepts JSON returned by gateways even when stream was requested.
  static Future<AgentResponse> readResponse(
    Stream<List<int>> bytes,
    AgentRun run,
    AgentDelta onDelta,
  ) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final fragments = <int, _ToolFragments>{};
    final event = <String>[];
    final jsonLines = <String>[];
    bool? jsonMode;
    var done = false;
    String? finish;
    var received = 0;

    void emit(String type, Object? value) {
      if (value == null) return;
      if (value is! String) {
        throw const FormatException('Expected text delta');
      }
      if (type == 'text') {
        text.write(value);
      } else {
        reasoning.write(value);
      }
      if (value.isNotEmpty) onDelta(type, value);
    }

    void ingest(AgentJson data, {bool full = false}) {
      if (data['error'] != null) {
        throw const AgentException('MODEL_ERROR', '模型服务返回错误，请检查配置后重试');
      }
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
          final buffer = fragments.putIfAbsent(index, _ToolFragments.new);
          final id = call['id'] as String?;
          if (id != null && id != buffer.id) buffer.id += id;
          final function = agentObject(call['function'] ?? {});
          final name = function['name'] as String?;
          if (name != null && name != buffer.name) buffer.name += name;
          buffer.arguments += function['arguments'] as String? ?? '';
          if (buffer.arguments.length > 128 * 1024) {
            throw const AgentException('TOOL_TOO_LARGE', '模型的工具参数过长');
          }
        }
      }
      finish = choice['finish_reason'] as String? ?? finish;
      if (full) finish ??= fragments.isEmpty ? 'stop' : 'tool_calls';
    }

    void flushEvent() {
      if (event.isEmpty) return;
      final data = event.join('\n').trim();
      event.clear();
      if (data == '[DONE]') {
        done = true;
      } else if (data.isNotEmpty) {
        ingest(agentObject(jsonDecode(data)));
      }
    }

    final iterator = StreamIterator(
      bytes.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      while (await run.wait(
        iterator.moveNext(),
        timeout: const Duration(seconds: 60),
      )) {
        run.check();
        final line = iterator.current;
        received += line.length;
        if (received > 2 * 1024 * 1024) {
          throw const AgentException('RESPONSE_TOO_LARGE', '模型响应过长，已停止接收');
        }
        if (jsonMode == null && line.trim().isNotEmpty) {
          jsonMode = line.trimLeft().startsWith('{');
        }
        if (jsonMode == true) {
          jsonLines.add(line);
        } else if (line.isEmpty) {
          flushEvent();
          if (done) break;
        } else if (line.startsWith('data:')) {
          event.add(line.substring(5).trimLeft());
        }
      }
      if (jsonMode == true) {
        ingest(agentObject(jsonDecode(jsonLines.join('\n'))), full: true);
      } else {
        flushEvent();
      }
      run.check();
      // A finish_reason is the semantic boundary, not just a closed socket.
      if (!['stop', 'tool_calls'].contains(finish)) {
        throw AgentException(
          'INCOMPLETE_RESPONSE',
          finish == 'length'
              ? '模型输出达到长度限制；未执行未完成的工具，请调整输出上限后重试'
              : '模型响应未完整结束；未执行工具，可重试本轮',
        );
      }
      final calls = <AgentToolCall>[];
      final indexes = fragments.keys.toList()..sort();
      final ids = <String>{};
      for (final index in indexes) {
        final call = fragments[index]!;
        if (call.id.isEmpty || call.name.isEmpty || !ids.add(call.id)) {
          throw const FormatException('Incomplete or duplicate tool call');
        }
        agentObject(jsonDecode(call.arguments));
        calls.add(AgentToolCall(call.id, call.name, call.arguments));
      }
      return AgentResponse(text.toString(), reasoning.toString(), calls);
    } finally {
      await iterator.cancel();
    }
  }

  void close() => _dio.close(force: true);
}
