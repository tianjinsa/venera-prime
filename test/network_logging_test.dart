import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  test('network interceptor supplies timeouts only when unspecified', () {
    final options = RequestOptions(path: 'https://example.test');
    MyLogInterceptor().onRequest(options, RequestInterceptorHandler());
    expect(options.connectTimeout, const Duration(seconds: 15));
    expect(options.receiveTimeout, const Duration(seconds: 15));
    expect(options.sendTimeout, const Duration(seconds: 15));
  });

  test(
    'network interceptor preserves explicit download and disabled timeouts',
    () {
      final options = RequestOptions(
        path: 'https://example.test/app.apk',
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 2),
        sendTimeout: Duration.zero,
      );
      MyLogInterceptor().onRequest(options, RequestInterceptorHandler());
      expect(options.connectTimeout, const Duration(seconds: 30));
      expect(options.receiveTimeout, const Duration(minutes: 2));
      expect(options.sendTimeout, Duration.zero);
    },
  );

  test('network log URLs redact credentials and authentication parameters', () {
    final safe = MyLogInterceptor.safeUrl(
      'https://user:password@example.test/path?token=abc&x-auth-signature=def&query=visible',
    );

    expect(safe, contains('https://example.test/path'));
    expect(safe, contains('token=%2A'));
    expect(safe, contains('x-auth-signature=%2A'));
    expect(safe, contains('query=visible'));
    expect(safe, isNot(contains('user')));
    expect(safe, isNot(contains('password')));
    expect(safe, isNot(contains('abc')));
    expect(safe, isNot(contains('def')));
  });
}
