import 'dart:async';
import 'dart:convert';
import 'package:venera/network/app_dio.dart';
import 'agent_http_adapter.dart';
import 'agent_models.dart';
import 'agent_protocol.dart';

class AgentProviderModel {
  final String id;
  final String? name;
  const AgentProviderModel(this.id, [this.name]);
}

/// Uses the same transport and authentication as chat, without request logging.
class AgentModelDiscovery {
  final Dio _dio;
  final Duration timeout;
  AgentModelDiscovery({Dio? dio, this.timeout = const Duration(seconds: 30)})
    : _dio = dio ?? Dio() {
    if (dio == null) _dio.httpClientAdapter = AgentHttpAdapter();
    _dio.options.connectTimeout = const Duration(seconds: 20);
  }

  static Uri endpoint(AgentModel connection) {
    final uri = connection.endpoint;
    return uri.replace(
      path:
          '${uri.path.substring(0, uri.path.length - connection.protocol.path.length)}/models',
    );
  }

  static List<AgentProviderModel> parse(Object? value) {
    Object? rows = value;
    for (var depth = 0; depth < 4 && rows is Map; depth++) {
      rows = rows['data'] ?? rows['models'] ?? rows['items'] ?? rows['results'];
    }
    if (rows is! List) {
      throw const AgentException(
        'INVALID_MODEL_LIST',
        '服务返回的模型列表格式不兼容，可手动填写模型 ID',
      );
    }
    final models = <String, AgentProviderModel>{};
    for (final row in rows) {
      final id = row is String
          ? row
          : row is Map
          ? row['id'] ?? row['model'] ?? row['name']
          : null;
      if (id is! String || id.trim().isEmpty) continue;
      final name = row is Map ? row['display_name'] ?? row['name'] : null;
      models.putIfAbsent(
        id,
        () =>
            AgentProviderModel(id, name is String && name != id ? name : null),
      );
    }
    if (rows.isNotEmpty && models.isEmpty) {
      throw const AgentException('INVALID_MODEL_LIST', '模型列表未包含有效的模型 ID，可手动填写');
    }
    return models.values.toList();
  }

  Future<List<AgentProviderModel>> fetch({
    required AgentModel connection,
    required String apiKey,
    required AgentRun run,
  }) async {
    connection.validate();
    final uri = endpoint(connection);
    final models = <String, AgentProviderModel>{};
    final cursors = <String>{};
    String? after;
    final cancel = CancelToken();
    unawaited(run.whenCancelled.then((_) => cancel.cancel()));
    try {
      for (var page = 0; page < 100; page++) {
        run.check();
        final decoded = await run.wait(() async {
          final response = await _dio.getUri<ResponseBody>(
            uri.replace(
              queryParameters: connection.protocol == AgentProtocol.messages
                  ? {'limit': '100', if (after != null) 'after_id': after}
                  : null,
            ),
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              receiveTimeout: timeout,
              headers: {
                ...AgentProtocolCodec.headers(connection, apiKey),
                'Accept': 'application/json',
              },
            ),
          );
          final bytes = <int>[];
          final body = response.data;
          if (body == null) throw const FormatException();
          await for (final chunk in body.stream) {
            run.check();
            if (bytes.length + chunk.length > 4 * 1024 * 1024) {
              throw const AgentException(
                'MODEL_LIST_TOO_LARGE',
                '服务返回的模型列表过大，请手动填写模型 ID',
              );
            }
            bytes.addAll(chunk);
          }
          return jsonDecode(utf8.decode(bytes));
        }(), timeout: timeout);
        final items = parse(decoded);
        for (final item in items) {
          models.putIfAbsent(item.id, () => item);
        }
        if (models.length > 10000) break;
        if (connection.protocol != AgentProtocol.messages ||
            decoded is! Map ||
            decoded['has_more'] != true) {
          final result = models.values.toList();
          result.sort(
            (a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()),
          );
          return result;
        }
        final cursor =
            decoded['last_id'] ?? (items.isEmpty ? null : items.last.id);
        if (cursor is! String || cursor.isEmpty || !cursors.add(cursor)) {
          throw const AgentException(
            'INVALID_MODEL_LIST',
            '服务返回了无效的分页游标，请手动填写模型 ID',
          );
        }
        after = cursor;
      }
      throw const AgentException('MODEL_LIST_TOO_LARGE', '模型列表分页过多，请手动填写模型 ID');
    } on DioException catch (e) {
      if (run.isCancelled || CancelToken.isCancel(e)) {
        throw const AgentException('CANCELLED', '已取消获取模型列表');
      }
      final status = e.response?.statusCode;
      if ([404, 405, 501].contains(status)) {
        throw const AgentException(
          'MODELS_UNSUPPORTED',
          '服务商未提供 /models 接口，请手动填写模型 ID',
        );
      }
      throw AgentException(
        'MODEL_LIST_FAILED',
        status == null
            ? '获取模型列表失败，请检查网络与 API 地址；也可手动填写模型 ID'
            : '获取模型列表失败（HTTP $status），请检查密钥、协议与请求头；也可手动填写模型 ID',
      );
    } on FormatException {
      throw const AgentException(
        'INVALID_MODEL_LIST',
        '服务返回的模型列表不是有效 JSON，请手动填写模型 ID',
      );
    } finally {
      cancel.cancel();
    }
  }

  void close() => _dio.close(force: true);
}
