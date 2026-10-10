import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';

/// Keeps widget tests independent of cover downloads and open image files.
class ComicImageFixture {
  ComicImageFixture() {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    _image = picture.toImageSync(1, 1);
    picture.dispose();
  }

  late final ui.Image _image;

  void cache(Iterable<Comic> comics, {Size? thumbnailSize}) {
    for (final comic in comics) {
      final ImageProvider provider = comic is History
          ? HistoryImageProvider(comic)
          : CachedImageProvider(
              comic.cover,
              sourceKey: comic.sourceKey,
              cid: comic.id,
            );
      cacheProvider(provider);
      if (thumbnailSize != null) {
        cacheProvider(
          ResizeImage(
            provider,
            width: thumbnailSize.width.toInt(),
            height: thumbnailSize.height.toInt(),
            policy: ResizeImagePolicy.fit,
          ),
        );
      }
    }
  }

  void cacheProvider(ImageProvider provider, {Future<void>? ready}) {
    provider.obtainKey(ImageConfiguration.empty).then((key) {
      PaintingBinding.instance.imageCache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(
          ready == null
              ? Future.value(ImageInfo(image: _image.clone()))
              : ready.then((_) => ImageInfo(image: _image.clone())),
        ),
      );
    });
  }

  void dispose() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _image.dispose();
  }
}
