import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:venera/utils/image_codec.dart';

Future<void> writeImageToClipboard(Uint8List imageBytes) async {
  const channel = MethodChannel("venera/clipboard");
  if (Platform.isWindows || Platform.isLinux) {
    final codec = await decodeImageBytes(imageBytes);
    FrameInfo? frame;
    try {
      frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ImageByteFormat.rawRgba,
      );
      await channel.invokeMethod("writeImageToClipboard", {
        "width": frame.image.width,
        "height": frame.image.height,
        "data": Uint8List.view(data!.buffer),
      });
    } finally {
      frame?.image.dispose();
      codec.dispose();
    }
  } else if (Platform.isMacOS) {
    await channel.invokeMethod("writeImageToClipboard", {"data": imageBytes});
  } else {
    throw UnsupportedError("Clipboard image is not supported on this platform");
  }
}
