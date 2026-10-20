import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'agent_http_adapter.dart';
import 'agent_models.dart';
import 'agent_protocol.dart';

/// Asks a service which models it currently serves, so a model is added by
/// choosing one of its identifiers instead of typing it exactly.
///
/// The request reuses the configured address, protocol and key, and takes the
/// same transport as model requests so proxy, DNS and TLS settings apply.
class AgentModelCatalogClient {
  static const maxResponseBytes = 4 * 1024 * 1024;
  static const maxModels = 1000;
  static const _maxPages = 10;

  final Dio Function() createDio;
  final Duration timeout;
  const AgentModelCatalogClient({
    this.createDio = _defaultDio,
    this.timeout = const Duration(seconds: 20),
  });

  static Dio _defaultDio() => Dio()..httpClientAdapter = AgentHttpAdapter();

  /// `{base}/models`, and when the base is not versioned, the same path under
  /// `/v1`. Some gateways only implement one of the two.
  static List<Uri> endpoints(String baseUrl, AgentProtocol protocol) {
    final base = AgentModel.baseEndpoint(baseUrl, protocol);
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    final primary = base.replace(path: '$path/models');
    if (path.endsWith('/v1')) return [primary];
    return [primary, base.replace(path: '$path/v1/models')];
  }

  Future<List<String>> listModels({
    required String baseUrl,
    required AgentProtocol protocol,
    String apiKey = '',
    Map<String, String> headers = const {},
  }) async {
    final candidates = endpoints(baseUrl, protocol);
    final dio = createDio();
    dio.options.connectTimeout = timeout;
    try {
      AgentException? unsupported;
      for (final url in candidates) {
        try {
          return await _read(dio, url, protocol, apiKey, headers);
        } on AgentException catch (e) {
          if (e.code != 'MODEL_LIST_UNSUPPORTED') rethrow;
          unsupported = e;
        }
      }
      throw unsupported!;
    } finally {
      dio.close(force: true);
    }
  }

  Future<List<String>> _read(
    Dio dio,
    Uri url,
    AgentProtocol protocol,
    String apiKey,
    Map<String, String> custom,
  ) async {
    final ids = <String>[];
    var next = url;
    for (var page = 0; page < _maxPages; page++) {
      final data = await _request(dio, next, protocol, apiKey, custom);
      final parsed = parseModels(data);
      if (page == 0 && parsed.isEmpty) {
        throw const AgentException('MODEL_LIST_INVALID', '模型服务没有返回可识别的模型列表');
      }
      ids.addAll(parsed);
      if (ids.length >= maxModels) break;
      // Anthropic lists a page at a time and reports how to continue.
      final last = data is Map ? data['last_id'] : null;
      if (data is! Map || data['has_more'] != true || last is! String) break;
      if (last.isEmpty || last.length > 512) break;
      next = url.replace(
        queryParameters: {
          ...url.queryParameters,
          'limit': '100',
          'after_id': last,
        },
      );
    }
    return {for (final id in ids) id}.take(maxModels).toList();
  }

  Future<Object?> _request(
    Dio dio,
    Uri url,
    AgentProtocol protocol,
    String apiKey,
    Map<String, String> custom,
  ) async {
    final Response<ResponseBody> response;
    try {
      response = await dio.getUri<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          headers: {
            ...AgentProtocolCodec.authHeaders(protocol, apiKey),
            ...custom,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );
    } on DioException {
      // Never echo the request options: they carry the key.
      throw const AgentException(
        'MODEL_LIST_FAILED',
        '无法连接模型服务，请检查 API 地址、网络或代理设置',
      );
    }
    final body = response.data;
    final status = response.statusCode ?? 0;
    if (body == null) {
      throw const AgentException('MODEL_LIST_FAILED', '模型服务返回了空响应');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const AgentException('MODEL_LIST_TOO_LARGE', '模型列表过大，无法完整读取');
      }
      bytes.add(chunk);
    }
    if (status == 401 || status == 403) {
      throw const AgentException(
        'MODEL_LIST_AUTH_FAILED',
        '模型服务拒绝了请求，请检查 API Key 和接口协议',
      );
    }
    if ([404, 405, 501].contains(status)) {
      throw const AgentException(
        'MODEL_LIST_UNSUPPORTED',
        '该服务没有提供模型列表接口，请手动填写模型 ID',
      );
    }
    if (status == 429) {
      throw const AgentException(
        'MODEL_LIST_RATE_LIMITED',
        '请求过于频繁或额度不足，请稍后再试',
      );
    }
    if (status < 200 || status >= 300) {
      throw AgentException('MODEL_LIST_FAILED', '模型服务返回 HTTP $status，无法读取模型列表');
    }
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const AgentException(
        'MODEL_LIST_INVALID',
        '模型服务返回的内容不是有效的 JSON 列表',
      );
    }
  }

  /// Accepts the shapes used by OpenAI-compatible services, Anthropic and a
  /// few common gateways: a list of identifiers, a list of objects, or an
  /// object wrapping either under `data`, `models`, `result`, `items` or
  /// `list`.
  static List<String> parseModels(Object? data) {
    final ids = <String>[];
    void add(Object? value) {
      if (value is! String) return;
      final id = value.trim();
      if (id.isEmpty ||
          id.length > 512 ||
          id.codeUnits.any((unit) => unit < 32 || unit == 127)) {
        return;
      }
      ids.add(id);
    }

    void visit(Object? value) {
      if (value is String) {
        add(value);
        return;
      }
      if (value is List) {
        for (final item in value) {
          visit(item);
        }
        return;
      }
      if (value is Map) {
        var nested = false;
        for (final key in const ['data', 'models', 'result', 'items', 'list']) {
          if (value.containsKey(key)) {
            nested = true;
            visit(value[key]);
          }
        }
        if (nested) return;
        for (final key in const ['id', 'model', 'name']) {
          final candidate = value[key];
          if (candidate is String) {
            add(candidate);
            return;
          }
        }
      }
    }

    visit(data);
    // A service can list the same identifier twice; the picker shows it once.
    return {for (final id in ids) id}.toList();
  }
}
