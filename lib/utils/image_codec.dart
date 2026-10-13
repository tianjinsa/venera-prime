import 'dart:async';
import 'dart:isolate';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:avif_native/avif_native.dart';
import 'package:flutter/painting.dart'
    show ImageDecoderCallback, PaintingBinding;
import 'package:venera/utils/file_type.dart';

/// Keep Flutter's normal codec/cache sizing for other formats. AVIF needs a
/// bundled decoder: Flutter's platform fallback is not available on all OSes.
Future<ui.Codec> decodeImageBytes(
  Uint8List bytes, {
  ImageDecoderCallback decode = ui.instantiateImageCodecWithSize,
  ui.TargetImageSizeCallback? getTargetSize,
}) async {
  if (detectFileType(bytes).mime != 'image/avif') {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // The Flutter callback owns and disposes this encoded buffer.
    return decode(buffer, getTargetSize: getTargetSize);
  }

  // ResizeImage and other wrappers express their sizing through this callback.
  // Preserve it with a lossless PNG frame only for custom callbacks; ordinary
  // providers use raw pixels without a PNG encode/decode round trip.
  final customDecode =
      decode != ui.instantiateImageCodecWithSize &&
      decode != PaintingBinding.instance.instantiateImageCodecWithSize;
  final worker = await _AvifWorker.open(bytes, encodePng: customDecode);
  try {
    final target = customDecode
        ? null
        : getTargetSize?.call(worker.width, worker.height);
    Future<ui.Codec> frameCodec(_DecodedFrame frame) async {
      if (!customDecode) return _rawCodec(frame, target);
      final buffer = await ui.ImmutableBuffer.fromUint8List(frame.bytes);
      return decode(buffer, getTargetSize: getTargetSize);
    }

    if (worker.frameCount == 1) {
      // A still image must not retain a worker/isolate while in ImageCache.
      final frame = await worker.next();
      worker.dispose();
      return frameCodec(frame);
    }
    return _AnimatedAvifCodec(worker, frameCodec);
  } catch (_) {
    worker.dispose();
    rethrow;
  }
}

Future<ui.Codec> _rawCodec(
  _DecodedFrame frame,
  ui.TargetImageSize? size,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(frame.bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec(
      targetWidth: size?.width,
      targetHeight: size?.height,
    );
    try {
      // Raw descriptors must stay alive until the pixels have been consumed.
      final frame = await codec.getNextFrame();
      return _StillAvifCodec(frame.image);
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _DecodedFrame {
  _DecodedFrame(List<dynamic> message)
    : bytes = (message[0] as TransferableTypedData).materialize().asUint8List(),
      width = message[1] as int,
      height = message[2] as int,
      duration = Duration(microseconds: message[3] as int);

  final Uint8List bytes;
  final int width;
  final int height;
  final Duration duration;
}

class _AvifWorker {
  _AvifWorker(List<dynamic> info)
    : commands = info[0] as SendPort,
      width = info[1] as int,
      height = info[2] as int,
      frameCount = info[3] as int,
      repetitionCount = info[4] as int;

  final SendPort commands;
  final int width;
  final int height;
  final int frameCount;
  final int repetitionCount;
  bool _disposed = false;

  static Future<_AvifWorker> open(
    Uint8List bytes, {
    required bool encodePng,
  }) async {
    final reply = ReceivePort();
    try {
      await Isolate.spawn(
        _decodeAvif,
        (TransferableTypedData.fromList([bytes]), reply.sendPort, encodePng),
        onError: reply.sendPort,
        debugName: 'AVIF decoder',
      );
      return _AvifWorker(_response(await reply.first));
    } finally {
      reply.close();
    }
  }

  static List<dynamic> _response(dynamic value) {
    if (value is! List || value.isEmpty || value.first is String) {
      throw FormatException('AVIF decoding failed: $value');
    }
    return value;
  }

  Future<_DecodedFrame> next() async {
    if (_disposed) throw StateError('AVIF codec has been disposed');
    final reply = ReceivePort();
    try {
      commands.send(('next', reply.sendPort));
      return _DecodedFrame(_response(await reply.first));
    } finally {
      reply.close();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Let an in-flight native decode finish and free its resources normally.
    commands.send(('dispose', null));
  }
}

void _decodeAvif((TransferableTypedData, SendPort, bool) request) async {
  AvifDecoder? decoder;
  ReceivePort? commands;
  try {
    decoder = AvifDecoder(request.$1.materialize().asUint8List());
    commands = ReceivePort();
    request.$2.send([
      commands.sendPort,
      decoder.width,
      decoder.height,
      decoder.frameCount,
      decoder.repetitionCount < -1 ? 0 : decoder.repetitionCount,
    ]);
    var index = 0;
    await for (final message in commands) {
      final (command, reply) = message as (String, SendPort?);
      if (command == 'dispose') break;
      try {
        if (index == decoder.frameCount) {
          decoder.reset();
          index = 0;
        }
        final frame = decoder.getNextFrame();
        index++;
        // libavif returns straight RGBA; Flutter raw rgba8888 is premultiplied.
        final rgba = frame.rgba;
        for (var i = 0; !request.$3 && i < rgba.length; i += 4) {
          final alpha = rgba[i + 3];
          if (alpha == 255) continue;
          for (var channel = 0; channel < 3; channel++) {
            rgba[i + channel] = (rgba[i + channel] * alpha + 127) ~/ 255;
          }
        }
        reply!.send([
          TransferableTypedData.fromList([
            request.$3 ? _encodePng(rgba, frame.width, frame.height) : rgba,
          ]),
          frame.width,
          frame.height,
          frame.duration.inMicroseconds,
        ]);
        if (decoder.frameCount == 1) break;
      } catch (error, stack) {
        reply!.send([error.toString(), stack.toString()]);
        break;
      }
    }
  } catch (error, stack) {
    request.$2.send([error.toString(), stack.toString()]);
  } finally {
    decoder?.dispose();
    commands?.close();
  }
}

class _AnimatedAvifCodec implements ui.Codec {
  _AnimatedAvifCodec(this._worker, this._frameCodec);
  final _AvifWorker _worker;
  final Future<ui.Codec> Function(_DecodedFrame) _frameCodec;
  Future<void> _pending = Future.value();
  bool _disposed = false;

  @override
  int get frameCount => _worker.frameCount;
  @override
  int get repetitionCount => _worker.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    final result = _pending.then((_) => _next());
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ui.FrameInfo> _next() async {
    if (_disposed) throw StateError('AVIF codec has been disposed');
    try {
      final decoded = await _worker.next();
      if (_disposed) throw StateError('AVIF codec has been disposed');
      final codec = await _frameCodec(decoded);
      try {
        final frame = await codec.getNextFrame();
        if (_disposed) {
          frame.image.dispose();
          throw StateError('AVIF codec has been disposed');
        }
        return _AvifFrameInfo(frame.image, decoded.duration);
      } finally {
        codec.dispose();
      }
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _worker.dispose();
  }
}

class _AvifFrameInfo implements ui.FrameInfo {
  _AvifFrameInfo(this.image, this.duration);
  @override
  final ui.Image image;
  @override
  final Duration duration;
}

// Simple lossless RGBA PNG for the ImageDecoderCallback contract. Runs in the
// decoder isolate; ordinary (unwrapped) image providers never use this path.
Uint8List _encodePng(Uint8List rgba, int width, int height) {
  final result = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final typeBytes = type.codeUnits;
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, getCrc32(data, getCrc32(typeBytes)));
    result
      ..add(length.buffer.asUint8List())
      ..add(typeBytes)
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  final stride = width * 4;
  final scanlines = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    scanlines.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      rgba,
      y * stride,
    );
  }
  chunk('IDAT', ZLibEncoder().convert(scanlines));
  chunk('IEND', const []);
  return result.takeBytes();
}

class _StillAvifCodec implements ui.Codec {
  _StillAvifCodec(this._image);
  ui.Image? _image;
  @override
  int get frameCount => 1;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final image = _image;
    if (image == null) throw StateError('AVIF codec has been disposed');
    return _AvifFrameInfo(image.clone(), Duration.zero);
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
