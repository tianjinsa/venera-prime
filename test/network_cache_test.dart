import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cache.dart';

void main() {
  test('cache validation keeps authorization and token headers distinct', () {
    expect(
      NetworkCacheManager.compareHeaders(
        {'authorization': 'Bearer first-account'},
        {'authorization': 'Bearer second-account'},
      ),
      isFalse,
    );
    expect(
      NetworkCacheManager.compareHeaders(
        {'token': 'first-account'},
        {'token': 'second-account'},
      ),
      isFalse,
    );
  });

  test('cache size limit accounts for the entry being inserted', () {
    final manager = NetworkCacheManager();
    manager.clear();
    try {
      for (var i = 0; i < 2; i++) {
        manager.setCache(
          NetworkCache(
            uri: Uri.parse('https://example.test/$i'),
            requestHeaders: const {},
            responseHeaders: const {},
            data: null,
            time: DateTime.now(),
            size: 6 * 1024 * 1024,
          ),
        );
      }
      expect(manager.size, 6 * 1024 * 1024);
    } finally {
      manager.clear();
    }
  });

  test('replacing an entry removes its old size before eviction', () {
    final manager = NetworkCacheManager();
    manager.clear();
    final firstUri = Uri.parse('https://example.test/first');
    final secondUri = Uri.parse('https://example.test/second');
    NetworkCache entry(Uri uri, int size) => NetworkCache(
      uri: uri,
      requestHeaders: const {},
      responseHeaders: const {},
      data: null,
      time: DateTime.now(),
      size: size,
    );

    try {
      manager.setCache(entry(firstUri, 6 * 1024 * 1024));
      manager.setCache(entry(secondUri, 3 * 1024 * 1024));
      manager.setCache(entry(firstUri, 8 * 1024 * 1024));

      expect(manager.getCache(firstUri)?.size, 8 * 1024 * 1024);
      expect(manager.getCache(secondUri), isNull);
      expect(manager.size, 8 * 1024 * 1024);
    } finally {
      manager.clear();
    }
  });

  test('oversized entries are not retained or counted', () {
    final manager = NetworkCacheManager();
    manager.clear();
    final uri = Uri.parse('https://example.test/oversized');

    try {
      manager.setCache(
        NetworkCache(
          uri: uri,
          requestHeaders: const {},
          responseHeaders: const {},
          data: null,
          time: DateTime.now(),
          size: 11 * 1024 * 1024,
        ),
      );

      expect(manager.getCache(uri), isNull);
      expect(manager.size, 0);
    } finally {
      manager.clear();
    }
  });
}
