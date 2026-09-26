import 'dart:async';
import 'dart:convert';

import 'package:venera/network/app_dio.dart';
import 'agent_models.dart';
import 'agent_http_adapter.dart';
import 'agent_protocol.dart';

export 'agent_protocol.dart'
    show AgentDelta, AgentResponse, AgentToolCall;

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
  }) => AgentProtocolCodec.requestBody(
    model: model,
    thinkingId: thinkingId,
    messages: messages,
    tools: tools,
  );

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
            headers: AgentProtocolCodec.headers(model, apiKey),
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
        protocol: model.protocol,
      );
    } on DioException catch (e) {
      if (run.isCancelled || CancelToken.isCancel(e)) {
        throw const AgentException('CANCELLED', '已停止等待');
      }
      final status = e.response?.statusCode;
      if (status == null) {
        throw const AgentException(
          'MODEL_REQUEST_FAILED',
          '模型连接失败或超时，请检查网络和 API 地址',
        );
      }
      final detail = await _errorDetail(e.response?.data, apiKey);
      throw AgentException(
        'MODEL_REQUEST_FAILED',
        '模型服务返回 HTTP $status，请检查密钥、模型名称、接口协议和配置'
            '${detail == null ? '' : '：$detail'}',
      );
    } on FormatException {
      throw const AgentException('INVALID_RESPONSE', '模型响应格式不完整或不兼容');
    } finally {
      // Also closes an unfinished body after parser errors or timeouts.
      if (!cancel.isCancelled) cancel.cancel('Request finished');
    }
  }

  /// A short provider message helps fix configuration errors. The body is
  /// bounded, and the configured key is removed if a service echoes it.
  static Future<String?> _errorDetail(Object? data, String apiKey) async {
    if (data is! ResponseBody) return null;
    try {
      final bytes = <int>[];
      await for (final chunk in data.stream.timeout(
        const Duration(seconds: 5),
      )) {
        bytes.addAll(chunk);
        if (bytes.length >= 8192) break;
      }
      var text = utf8.decode(bytes, allowMalformed: true).trim();
      try {
        final json = jsonDecode(text);
        final error = json is Map ? json['error'] ?? json : null;
        final message = error is Map ? error['message'] : error;
        if (message is String) text = message;
      } on FormatException {
        // Plain text errors are shown as they are.
      }
      if (apiKey.isNotEmpty) text = text.replaceAll(apiKey, '***');
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return text.isEmpty ? null : agentClip(text, 300);
    } catch (_) {
      return null;
    }
  }

  /// Also accepts JSON returned by gateways even when stream was requested.
  static Future<AgentResponse> readResponse(
    Stream<List<int>> bytes,
    AgentRun run,
    AgentDelta onDelta, {
    AgentProtocol protocol = AgentProtocol.chat,
  }) async {
    final state = AgentProtocolCodec.stream(protocol, onDelta);
    final event = <String>[];
    final jsonLines = <String>[];
    bool? jsonMode;

    void flushEvent() {
      if (event.isEmpty) return;
      final data = event.join('\n').trim();
      event.clear();
      if (data.isNotEmpty) state.event(data);
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
        if (jsonMode == null && line.trim().isNotEmpty) {
          jsonMode = line.trimLeft().startsWith('{');
        }
        if (jsonMode == true) {
          jsonLines.add(line);
        } else if (line.isEmpty) {
          flushEvent();
          if (state.done) break;
        } else if (line.startsWith('data:')) {
          event.add(line.substring(5).trimLeft());
        }
      }
      if (jsonMode == true) {
        state.full(agentObject(jsonDecode(jsonLines.join('\n'))));
      } else {
        flushEvent();
      }
      run.check();
      final finish = state.finish;
      // A finish reason is the semantic boundary, not just a closed socket.
      if (!['stop', 'tool_calls'].contains(finish)) {
        throw AgentException(
          'INCOMPLETE_RESPONSE',
          finish == 'length'
              ? '服务商在输出上限处结束了生成，收到的内容已保留；未执行不完整工具。可调整模型输出参数后继续'
              : '模型响应未完整结束；未执行工具，可重试本轮',
        );
      }
      return state.result();
    } finally {
      await iterator.cancel();
    }
  }

  void close() => _dio.close(force: true);
}
