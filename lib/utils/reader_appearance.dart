import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';

/// Fraction of the viewport reserved on each side, before pinch zoom.
/// Continuous readers apply it across their scrolling axis so pages still join.
double readerPageMargin(String comicId, String sourceKey) {
  if (appdata.settings.getReaderSetting(
        comicId,
        sourceKey,
        'readerPageMarginEnabled',
      ) !=
      true) {
    return 0;
  }
  final value = appdata.settings.getReaderSetting(
    comicId,
    sourceKey,
    'readerPageMarginPercent',
  );
  final percent = value is num && value.isFinite ? value.toDouble() : 19.3;
  return percent.clamp(0.0, 40.0) / 100;
}

Color readerBackgroundColor(
  BuildContext context,
  String comicId,
  String sourceKey,
) {
  final key = appdata.settings.getReaderSetting(
    comicId,
    sourceKey,
    'readerBackground',
  );
  return switch (key) {
    'white' => Colors.white,
    'gray' => const Color(0xffd0d0d0),
    'black' => Colors.black,
    'sepia' => const Color(0xfff1e4c3),
    _ => Theme.of(context).colorScheme.surface,
  };
}
