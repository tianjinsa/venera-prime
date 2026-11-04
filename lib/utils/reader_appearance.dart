import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera/foundation/appdata.dart';

double _effectStrength(Object? value, double fallback, double max) =>
    (value is num && value.isFinite ? value.toDouble() : fallback).clamp(
      0,
      max,
    );

/// Darken ink relative to paper, then dim and attenuate cooler channels.
/// No positive offsets: black ink stays black even in warm/red night modes.
List<double>? readerColorMatrix({
  bool enhanceLines = false,
  double lineStrength = 0.5,
  String nightMode = 'none',
  double nightIntensity = 0.25,
}) {
  final strength = enhanceLines ? _effectStrength(lineStrength, 0.5, 1) : 0.0;
  final intensity = switch (nightMode) {
    'dark' || 'warm' || 'red' => _effectStrength(nightIntensity, 0.25, 0.8),
    _ => 0.0,
  };
  if (strength == 0 && intensity == 0) return null;

  final dim = 1 - intensity;
  final (greenAttenuation, blueAttenuation) = switch (nightMode) {
    'warm' => (0.22, 0.65),
    'red' => (0.70, 0.85),
    // A slight warm bias also reduces the cold cast in dark mode.
    _ => (0.10, 0.25),
  };
  final channels = [
    dim,
    dim * (1 - greenAttenuation * intensity),
    dim * (1 - blueAttenuation * intensity),
  ];
  // Anchor contrast at paper white so enhancement never brightens the page.
  final contrast = 1 + 0.8 * strength;
  final bias = -255 * (contrast - 1);
  return [
    for (var row = 0; row < 3; row++) ...[
      for (var column = 0; column < 3; column++)
        row == column ? channels[row] * contrast : 0.0,
      0.0,
      channels[row] * bias,
    ],
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
  ];
}

/// Keep the reading subtree mounted while appearance settings change live.
/// Controls and sidebars sit outside this widget and retain their normal colors.
class ReaderColorEffects extends StatelessWidget {
  const ReaderColorEffects({
    required this.comicId,
    required this.sourceKey,
    required this.child,
    this.enhanceLines = true,
    super.key,
  });

  final String comicId;
  final String sourceKey;
  final Widget child;
  final bool enhanceLines;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appdata.settings,
      child: child,
      builder: (context, child) {
        dynamic setting(String key) =>
            appdata.settings.getReaderSetting(comicId, sourceKey, key);
        final mode = setting('readerNightMode');
        final matrix = readerColorMatrix(
          enhanceLines:
              enhanceLines && setting('readerLineEnhancement') == true,
          lineStrength: _effectStrength(
            setting('readerLineEnhancementStrength'),
            0.5,
            1,
          ),
          nightMode: mode is String ? mode : 'none',
          nightIntensity: _effectStrength(
            setting('readerNightModeIntensity'),
            0.25,
            0.8,
          ),
        );
        return _OptionalColorFilter(
          colorFilter: matrix == null ? null : ColorFilter.matrix(matrix),
          child: child!,
        );
      },
    );
  }
}

class _OptionalColorFilter extends SingleChildRenderObjectWidget {
  const _OptionalColorFilter({required this.colorFilter, required super.child});

  final ColorFilter? colorFilter;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOptionalColorFilter(colorFilter);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderOptionalColorFilter renderObject,
  ) {
    renderObject.colorFilter = colorFilter;
  }
}

class _RenderOptionalColorFilter extends RenderProxyBox {
  _RenderOptionalColorFilter(this._colorFilter);

  ColorFilter? _colorFilter;

  set colorFilter(ColorFilter? value) {
    if (_colorFilter == value) return;
    final wasEnabled = _colorFilter != null;
    _colorFilter = value;
    if (wasEnabled != (value != null)) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _colorFilter != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _colorFilter == null) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    layer = context.pushColorFilter(
      offset,
      _colorFilter!,
      super.paint,
      oldLayer: layer as ColorFilterLayer?,
    );
  }
}

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
