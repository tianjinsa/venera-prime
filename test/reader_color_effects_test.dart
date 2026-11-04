import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/reader_appearance.dart';

const _comicId = 'color-effects-comic';
const _sourceKey = 'color-effects-source';
const _boundaryKey = ValueKey('color-effects-pixels');
const _colors = [
  Colors.white,
  Colors.black,
  Color(0xff808080),
  Color(0xff3c64b4),
];

Future<void> _showSamples(
  WidgetTester tester, {
  bool enhanceLines = true,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _boundaryKey,
          child: ReaderColorEffects(
            comicId: _comicId,
            sourceKey: _sourceKey,
            enhanceLines: enhanceLines,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final color in _colors)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ColoredBox(color: color),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<List<List<int>>> _pixels(WidgetTester tester) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final pixels = [
      for (var i = 0; i < _colors.length; i++)
        [
          for (var channel = 0; channel < 4; channel++)
            data.getUint8((20 * image.width + i * 40 + 20) * 4 + channel),
        ],
    ];
    image.dispose();
    return pixels;
  }))!;
}

void _expectNoBrighter(List<List<int>> actual, List<List<int>> previous) {
  for (var i = 0; i < actual.length; i++) {
    for (var channel = 0; channel < 3; channel++) {
      expect(actual[i][channel], lessThanOrEqualTo(previous[i][channel]));
    }
    expect(actual[i][3], 255);
  }
}

void main() {
  final settings = appdata.settings;
  late Map<String, dynamic> previous;
  setUp(() {
    final defaults = <String, dynamic>{
      'readerLineEnhancement': false,
      'readerLineEnhancementStrength': 0.5,
      'readerNightMode': 'none',
      'readerNightModeIntensity': 0.25,
      'deviceId': 'color-effects-device',
      'deviceSpecificSettings': <String, dynamic>{},
      'comicSpecificSettings': <String, dynamic>{},
    };
    previous = {for (final key in defaults.keys) key: settings[key]};
    for (final entry in defaults.entries) {
      settings[entry.key] = entry.value;
    }
  });
  tearDown(() {
    for (final entry in previous.entries) {
      settings[entry.key] = entry.value;
    }
  });

  testWidgets('enhancement deepens ink without brightening paper or colors', (
    tester,
  ) async {
    await _showSamples(tester);
    final original = await _pixels(tester);
    settings['readerLineEnhancement'] = true;
    final enhanced = await _pixels(tester);
    expect(enhanced[0], original[0]);
    expect(enhanced[1], [0, 0, 0, 255]);
    expect(enhanced[2][0], lessThan(original[2][0]));
    _expectNoBrighter(enhanced, original);

    settings['readerLineEnhancementStrength'] = 1.0;
    final stronger = await _pixels(tester);
    _expectNoBrighter(stronger, enhanced);
    expect(stronger[2][0], lessThan(enhanced[2][0]));
    settings['readerLineEnhancementStrength'] = 0.0;
    expect(await _pixels(tester), original);

    settings['readerLineEnhancementStrength'] = 0.5;
    settings['readerNightMode'] = 'warm';
    _expectNoBrighter(await _pixels(tester), enhanced);
  });

  testWidgets('night modes dim every channel, preserve black and reduce blue', (
    tester,
  ) async {
    await _showSamples(tester);
    final original = await _pixels(tester);
    for (final mode in ['dark', 'warm', 'red']) {
      settings['readerNightMode'] = mode;
      settings['readerNightModeIntensity'] = 0.0;
      expect(await _pixels(tester), original);
      var last = original;
      for (final intensity in [0.25, 0.5, 0.8]) {
        settings['readerNightModeIntensity'] = intensity;
        final dimmed = await _pixels(tester);
        _expectNoBrighter(dimmed, last);
        expect(dimmed[1], [0, 0, 0, 255]);
        expect(dimmed[0][0], lessThan(last[0][0]));
        expect(dimmed[0][2], lessThan(dimmed[0][1]));
        expect(dimmed[0][1], lessThan(dimmed[0][0]));
        last = dimmed;
      }
    }
  });

  testWidgets('live effects follow device and comic setting priority', (
    tester,
  ) async {
    await _showSamples(tester);
    final original = await _pixels(tester);
    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting('readerLineEnhancement', true);
    final enhanced = await _pixels(tester);
    expect(enhanced[2][0], lessThan(original[2][0]));
    settings.setEnabledComicSpecificSettings(_comicId, _sourceKey, true);
    settings.setReaderSetting(
      _comicId,
      _sourceKey,
      'readerLineEnhancement',
      false,
    );
    expect(await _pixels(tester), original);
    settings.resetComicReaderSettings('$_comicId@$_sourceKey');
    expect(await _pixels(tester), enhanced);
    settings.resetDeviceReaderSettings();
    expect(await _pixels(tester), original);
  });

  testWidgets('comments can skip enhancement while retaining night dimming', (
    tester,
  ) async {
    await _showSamples(tester, enhanceLines: false);
    final original = await _pixels(tester);
    settings['readerLineEnhancement'] = true;
    expect(await _pixels(tester), original);
    settings['readerNightMode'] = 'red';
    final dimmed = await _pixels(tester);
    _expectNoBrighter(dimmed, original);
    expect(dimmed[0][0], lessThan(original[0][0]));
  });

  testWidgets(
    'toggling effects preserves scroll state and removes idle layers',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ReaderColorEffects(
            comicId: _comicId,
            sourceKey: _sourceKey,
            child: ListView(
              controller: controller,
              children: List.generate(30, (_) => const SizedBox(height: 100)),
            ),
          ),
        ),
      );
      controller.jumpTo(150);
      await tester.pump();
      final state = tester.state(find.byType(Scrollable));
      expect(tester.layers.whereType<ColorFilterLayer>(), isEmpty);
      for (final enabled in [true, false, true, false]) {
        settings['readerLineEnhancement'] = enabled;
        await tester.pump();
        expect(tester.state(find.byType(Scrollable)), same(state));
        expect(controller.offset, 150);
        expect(
          tester.layers.whereType<ColorFilterLayer>(),
          hasLength(enabled ? 1 : 0),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('invalid and out-of-range strengths are safely normalized', () {
    expect(readerColorMatrix(), isNull);
    expect(readerColorMatrix(nightMode: 'unknown'), isNull);
    expect(
      readerColorMatrix(enhanceLines: true, lineStrength: double.nan),
      readerColorMatrix(enhanceLines: true),
    );
    expect(
      readerColorMatrix(nightMode: 'warm', nightIntensity: double.infinity),
      readerColorMatrix(nightMode: 'warm'),
    );
    expect(
      readerColorMatrix(enhanceLines: true, lineStrength: 10),
      readerColorMatrix(enhanceLines: true, lineStrength: 1),
    );
    expect(readerColorMatrix(nightMode: 'dark', nightIntensity: -1), isNull);
  });
}
