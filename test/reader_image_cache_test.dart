import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/reader_image_cache.dart';

void main() {
  testWidgets('late memory estimates cannot resize a closed reader cache', (
    tester,
  ) async {
    final estimate = Completer<int?>();
    final cache = ImageCache();
    final session = ReaderImageCache(
      cache: cache,
      availableMemory: () => estimate.future,
    );
    final configuring = session.configure();
    session.dispose();
    estimate.complete(8 << 30);
    await configuring;
    expect(cache.maximumSizeBytes, 100 << 20);
    await tester.pump(const Duration(seconds: 2));
    expect(cache.maximumSizeBytes, 100 << 20);
  });

  testWidgets('memory pressure wins over an outstanding memory estimate', (
    tester,
  ) async {
    final estimate = Completer<int?>();
    final cache = ImageCache();
    final session = ReaderImageCache(
      cache: cache,
      availableMemory: () => estimate.future,
    );
    final configuring = session.configure();
    session.handleMemoryPressure();
    estimate.complete(8 << 30);
    await configuring;
    expect(cache.maximumSizeBytes, 32 << 20);
    expect(session.allowPrecache, isFalse);
    session.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(cache.maximumSizeBytes, 32 << 20);
  });

  testWidgets('quick reentry keeps pages and cancels the previous reset', (
    tester,
  ) async {
    final cache = ImageCache();
    final first = ReaderImageCache(
      cache: cache,
      availableMemory: () async => 8 << 30,
    );
    await first.configure();
    expect(cache.maximumSizeBytes, 192 << 20);
    first.dispose();
    expect(cache.maximumSizeBytes, 192 << 20);
    final next = ReaderImageCache(
      cache: cache,
      availableMemory: () async => 8 << 30,
    );
    await next.configure();
    await tester.pump(const Duration(seconds: 2));
    expect(cache.maximumSizeBytes, 192 << 20);
    expect(next.allowPrecache, isTrue);
    next.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(cache.maximumSizeBytes, 100 << 20);
  });

  testWidgets('an older reader cannot change the newer session budget', (
    tester,
  ) async {
    final cache = ImageCache();
    final oldEstimate = Completer<int?>();
    final old = ReaderImageCache(
      cache: cache,
      availableMemory: () => oldEstimate.future,
    );
    final pending = old.configure();
    final current = ReaderImageCache(
      cache: cache,
      availableMemory: () async => 1 << 30,
    );
    await current.configure();
    oldEstimate.complete(8 << 30);
    await pending;
    old.handleMemoryPressure();
    old.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(cache.maximumSizeBytes, 64 << 20);
    current.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('low memory suppresses speculative page decoding', (
    tester,
  ) async {
    final cache = ImageCache();
    final session = ReaderImageCache(
      cache: cache,
      availableMemory: () async => 256 << 20,
    );
    await session.configure();
    expect(cache.maximumSizeBytes, 32 << 20);
    expect(session.allowPrecache, isFalse);
    session.dispose();
    await tester.pump(const Duration(seconds: 2));
  });
}
