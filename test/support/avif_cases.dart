import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/utils/image_codec.dart';
import 'package:venera/utils/image.dart' as processing;

import 'avif_fixtures.dart';

class _AvifProvider extends BaseImageProvider<_AvifProvider> {
  _AvifProvider(this.bytes);
  final Uint8List bytes;
  @override
  String get key => 'avif-test-${bytes.hashCode}';
  @override
  Future<_AvifProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async => bytes;
}

void registerAvifTests({bool device = false}) {
  void run(String name, Future<void> Function() body) {
    if (device) {
      testWidgets(name, (tester) async => tester.runAsync(body));
    } else {
      test(name, body);
    }
  }

  run(
    'static AVIF decodes with target dimensions and releases codec',
    () async {
      final codec = await decodeImageBytes(
        opaqueAvif(),
        getTargetSize: (width, height) {
          expect((width, height), (48, 32));
          return const ui.TargetImageSize(width: 24);
        },
      );
      try {
        expect(codec.frameCount, 1);
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), (24, 16));
        final bytes = (await frame.image.toByteData())!.buffer.asUint8List();
        expect(bytes.take(4), [220, 40, 20, 255]);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    },
  );

  run('transparent AVIF uses premultiplied pixels', () async {
    final codec = await decodeImageBytes(alphaAvif());
    try {
      final frame = await codec.getNextFrame();
      final bytes = (await frame.image.toByteData())!.buffer.asUint8List();
      expect(bytes.take(4), [100, 50, 20, 128]);
      expect(bytes.sublist(8, 12), [0, 0, 0, 0]);
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  });

  run('animated AVIF decodes lazily, loops, and serializes requests', () async {
    final codec = await decodeImageBytes(animatedAvif());
    try {
      expect(codec.frameCount, 2);
      expect(codec.repetitionCount, 2);
      final frames = await Future.wait([
        codec.getNextFrame(),
        codec.getNextFrame(),
        codec.getNextFrame(),
      ]);
      final colors = <List<int>>[];
      for (final frame in frames) {
        expect(frame.duration, const Duration(milliseconds: 100));
        colors.add(
          (await frame.image.toByteData())!.buffer
              .asUint8List()
              .take(4)
              .toList(),
        );
        frame.image.dispose();
      }
      expect(colors, [
        [220, 40, 20, 255],
        [20, 220, 40, 255],
        [220, 40, 20, 255],
      ]);
    } finally {
      codec.dispose();
    }
    await expectLater(codec.getNextFrame(), throwsStateError);
  });

  run(
    'unspecified animation repetitions still allow a complete cycle',
    () async {
      final bytes = animatedAvif();
      // Ignore the optional edit list to create a legal sequence with unknown
      // repetition count (-2 in libavif, which is not a Flutter loop value).
      final signature = 'edts'.codeUnits;
      var found = false;
      for (var i = 0; i <= bytes.length - 4; i++) {
        if (listEquals(bytes.sublist(i, i + 4), signature)) {
          bytes.setRange(i, i + 4, 'free'.codeUnits);
          found = true;
          break;
        }
      }
      expect(found, isTrue);
      final codec = await decodeImageBytes(bytes);
      try {
        expect(codec.frameCount, 2);
        expect(codec.repetitionCount, 0);
        for (var i = 0; i < codec.frameCount; i++) {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    },
  );

  run('AVIF codec can be disposed before a queued frame starts', () async {
    final codec = await decodeImageBytes(animatedAvif());
    final frame = codec.getNextFrame();
    codec.dispose();
    await expectLater(frame, throwsStateError);
  });

  run('malformed AVIF fails without hanging the worker', () async {
    final data = opaqueAvif();
    await expectLater(
      decodeImageBytes(
        Uint8List.sublistView(data, 0, 40),
      ).timeout(const Duration(seconds: 10)),
      throwsA(isA<FormatException>()),
    );
    final corrupt = Uint8List.fromList(data);
    corrupt.fillRange(40, corrupt.length, 0);
    await expectLater(
      decodeImageBytes(corrupt).timeout(const Duration(seconds: 10)),
      throwsA(isA<FormatException>()),
    );
  });

  for (final width in <int?>[null, 12]) {
    run('AVIF provider respects cache width $width', () async {
      final ImageProvider provider = width == null
          ? _AvifProvider(opaqueAvif())
          : ResizeImage(_AvifProvider(opaqueAvif()), width: width);
      final stream = provider.resolve(ImageConfiguration.empty);
      final complete = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (info, synchronous) => complete.complete(info),
        onError: (Object error, StackTrace? stack) =>
            complete.completeError(error, stack),
      );
      stream.addListener(listener);
      try {
        final image = await complete.future.timeout(
          const Duration(seconds: 10),
        );
        expect((
          image.image.width,
          image.image.height,
        ), width == null ? (48, 32) : (12, 8));
        image.dispose();
      } finally {
        stream.removeListener(listener);
        await provider.evict();
      }
    });
  }

  run('custom image processing can decode AVIF bytes', () async {
    final image = await processing.Image.decodeImage(opaqueAvif());
    expect((image.width, image.height), (48, 32));
    final pixel = image.getPixel(0, 0);
    expect([pixel.r, pixel.g, pixel.b, pixel.a], [220, 40, 20, 255]);
  });

  run(
    'custom callback preserves animation dimensions and frame durations',
    () async {
      var calls = 0;
      final codec = await decodeImageBytes(
        animatedAvif(),
        decode: (buffer, {getTargetSize}) {
          calls++;
          return ui.instantiateImageCodecWithSize(
            buffer,
            getTargetSize: (_, _) => const ui.TargetImageSize(width: 12),
          );
        },
      );
      try {
        for (var i = 0; i < 2; i++) {
          final frame = await codec.getNextFrame();
          expect((frame.image.width, frame.image.height), (12, 8));
          expect(frame.duration, const Duration(milliseconds: 100));
          frame.image.dispose();
        }
        expect(calls, 2);
      } finally {
        codec.dispose();
      }
    },
  );

  run('non-AVIF bytes still use the supplied decoder', () async {
    var called = false;
    final png = Uint8List.fromList([137, 80, 78, 71]);
    await expectLater(
      decodeImageBytes(
        png,
        decode: (buffer, {getTargetSize}) async {
          called = true;
          buffer.dispose();
          throw const FormatException('sentinel');
        },
      ),
      throwsFormatException,
    );
    expect(called, isTrue);
  });
}
