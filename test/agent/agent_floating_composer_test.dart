import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_floating_composer.dart';

class _LayoutCounter extends SingleChildRenderObjectWidget {
  const _LayoutCounter({required this.onLayout, required super.child});
  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLayoutCounter(onLayout);
}

class _RenderLayoutCounter extends RenderProxyBox {
  _RenderLayoutCounter(this.onLayout);
  final VoidCallback onLayout;

  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

void main() {
  testWidgets(
    'floating input animates without relayout and remains clickable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var layouts = 0;
      var taps = 0;
      final inset = ValueNotifier(0.0);
      addTearDown(inset.dispose);
      const fieldKey = ValueKey('floating-field');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: ValueListenableBuilder<double>(
              valueListenable: inset,
              builder: (context, value, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(viewInsets: EdgeInsets.only(bottom: value)),
                child: child!,
              ),
              child: Column(
                children: [
                  const Expanded(child: SizedBox.expand()),
                  AgentFloatingComposer(
                    child: _LayoutCounter(
                      onLayout: () => layouts++,
                      child: Material(
                        child: Row(
                          children: [
                            const Expanded(child: TextField(key: fieldKey)),
                            IconButton(
                              onPressed: () => taps++,
                              icon: const Icon(Icons.send),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 82),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialLayouts = layouts;
      final initial = tester.getBottomLeft(find.byKey(fieldKey)).dy;
      inset.value = 300;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      final intermediate = tester.getBottomLeft(find.byKey(fieldKey)).dy;
      expect(intermediate, lessThan(initial));
      expect(intermediate, greaterThan(600));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byKey(fieldKey)).dy, closeTo(600, 1));
      expect(layouts, initialLayouts);
      await tester.tap(find.byIcon(Icons.send));
      expect(taps, 1);
      await tester.tap(find.byKey(fieldKey));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);

      inset.value = 0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      inset.value = 370;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byKey(fieldKey)).dy, closeTo(530, 1));
      expect(tester.takeException(), isNull);
    },
  );
}
