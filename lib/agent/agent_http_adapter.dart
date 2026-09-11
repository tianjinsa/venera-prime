import 'dart:async';
import 'dart:typed_data';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/app_dio.dart';

/// Reuses the application's network preferences, without its interceptors.
/// RHttpAdapter does not forward Dio cancellation, so bridge it here.
class AgentHttpAdapter implements HttpClientAdapter {
  final _active = <rhttp.CancelToken>{};
  bool _closed = false;

  void _cancel(rhttp.CancelToken token) {
    unawaited(token.cancel().catchError((Object _) {}));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Agent HTTP client is closed');
    final preferences = await RHttpAdapter().settings;
    if (_closed) throw StateError('Agent HTTP client is closed');
    final token = rhttp.CancelToken();
    _active.add(token);
    if (cancelFuture != null) {
      unawaited(cancelFuture.then((_) => _cancel(token)));
    }
    try {
      final response = await rhttp.Rhttp.request(
        method: rhttp.HttpMethod(options.method),
        url: options.uri.toString(),
        headers: rhttp.HttpHeaders.rawMap(
          options.headers.map((key, value) => MapEntry(key, value.toString())),
        ),
        body: requestStream == null
            ? null
            : rhttp.HttpBody.stream(requestStream),
        expectBody: rhttp.HttpExpectBody.stream,
        cancelToken: token,
        settings: preferences.copyWith(
          redirectSettings: const rhttp.RedirectSettings.none(),
          timeoutSettings: rhttp.TimeoutSettings(
            connectTimeout: options.connectTimeout,
            keepAliveTimeout: const Duration(seconds: 60),
            keepAlivePing: const Duration(seconds: 30),
          ),
        ),
      );
      if (response is! rhttp.HttpStreamResponse) {
        throw StateError('Expected HTTP stream');
      }
      final headers = <String, List<String>>{};
      for (final header in response.headers) {
        (headers[header.$1.toLowerCase()] ??= []).add(header.$2);
      }
      Stream<Uint8List> body() async* {
        try {
          yield* response.body;
        } finally {
          _active.remove(token);
          _cancel(token);
        }
      }

      return ResponseBody(body(), response.statusCode, headers: headers);
    } catch (_) {
      _active.remove(token);
      _cancel(token);
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final token in _active) {
      _cancel(token);
    }
    _active.clear();
  }
}
