import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/network/proxy.dart';

void main() {
  test('downloaded comics have a stable key without an installed source', () {
    expect(const ComicType(987654321).sourceKey, 'Unknown:987654321');
    expect(ComicType.local.sourceKey, 'local');
  });

  test(
    'manual proxy accepts UI host:port values and changes immediately',
    () async {
      final previous = appdata.settings['proxy'];
      addTearDown(() => appdata.settings['proxy'] = previous);
      for (final address in [
        '127.0.0.1:7890',
        'localhost:7890',
        'user:password@localhost:7890',
        '[::1]:7890',
        'http://localhost:7890',
      ]) {
        appdata.settings['proxy'] = address;
        expect(
          await getProxy(),
          address.startsWith('http://') ? address : 'http://$address',
        );
      }
      for (final address in ['direct', '', 'localhost:0', 'localhost:99999']) {
        appdata.settings['proxy'] = address;
        expect(await getProxy(), isNull);
      }
    },
  );

  for (final reversed in [false, true]) {
    testWidgets('slider follows horizontal scrubbing (reversed=$reversed)', (
      tester,
    ) async {
      var value = 50.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return CustomSlider(
                      min: 1,
                      max: 100,
                      value: value,
                      divisions: 99,
                      focusNode: null,
                      reversed: reversed,
                      onChanged: (next) => setState(() => value = next),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(CustomSlider));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(value, reversed ? lessThan(30) : greaterThan(70));
      await gesture.moveBy(const Offset(-260, 0));
      await tester.pump();
      expect(value, reversed ? greaterThan(70) : lessThan(30));
      await gesture.moveBy(const Offset(-500, 0));
      await tester.pump();
      expect(value, reversed ? 100 : 1);
      await gesture.up();
      expect(tester.takeException(), isNull);
    });
  }
}
