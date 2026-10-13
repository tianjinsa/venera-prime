import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('dragging without a label does not schedule duplicate builds', (
    tester,
  ) async {
    final controller = ScrollController();
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is AppScrollBar) builds++;
    };
    addTearDown(() {
      debugOnRebuildDirtyWidget = previous;
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppScrollBar(
            controller: controller,
            child: ListView.builder(
              controller: controller,
              itemExtent: 100,
              itemCount: 100,
              itemBuilder: (_, index) => Text('Item $index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final thumb = find
        .ancestor(
          of: find.byIcon(Icons.arrow_drop_up),
          matching: find.byType(CustomPaint),
        )
        .first;
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pumpAndSettle();
    final offsetBefore = controller.offset;
    builds = 0;
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 5));
      await tester.pump();
      await tester.pump();
    }
    expect(controller.offset, greaterThan(offsetBefore));
    expect(builds, 20);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
