import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';

const _phones = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});

Future<ScrollController> _pumpMessage(
  WidgetTester tester,
  String markdown,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 180),
            AgentMessageParts(
              message: AgentMessage(
                id: 'markdown',
                conversationId: 'conversation',
                role: 'assistant',
                createdAt: 1,
                parts: [
                  {'type': 'text', 'text': markdown},
                ],
              ),
              indices: const [0],
              busy: false,
              canRetry: (_) => false,
              onRetry: (_) {},
              onShowcase: (_) {},
              hasUndo: (_) => false,
              onUndo: (_) {},
            ),
            const SizedBox(height: 700),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return scroll;
}

// Hit an actual glyph, not Markdown padding or the space between paragraphs.
// Support both regular and editable text renderers.
Offset _glyphCenter(WidgetTester tester, String prefix, {int offset = 3}) {
  final editable = find.byWidgetPredicate(
    (widget) =>
        widget is EditableText && widget.controller.text.startsWith(prefix),
  );
  if (editable.evaluate().isNotEmpty) {
    final render = tester
        .state<EditableTextState>(editable.first)
        .renderEditable;
    return render.localToGlobal(
      render.getLocalRectForCaret(TextPosition(offset: offset)).center,
    );
  }
  final paragraph = find.byWidgetPredicate(
    (widget) =>
        widget is RichText && widget.text.toPlainText().startsWith(prefix),
  );
  final render = tester.renderObject<RenderParagraph>(paragraph.first);
  final box = render.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: offset + 1),
  );
  return render.localToGlobal(box.first.toRect().center);
}

void main() {
  testWidgets(
    'touch dragging rendered Markdown scrolls the surrounding conversation',
    (tester) async {
      final scroll = await _pumpMessage(
        tester,
        'Drag this **formatted paragraph** to read the conversation. '
        '${List.filled(60, 'More text continues in the same paragraph.').join(' ')}',
      );
      await tester.dragFrom(
        _glyphCenter(tester, 'Drag this'),
        const Offset(0, -140),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(scroll.offset, greaterThan(100));
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: _phones,
  );

  testWidgets(
    'diagonal touch dragging on Markdown scrolls the conversation',
    (tester) async {
      final scroll = await _pumpMessage(
        tester,
        'Drag this **formatted paragraph** to read the conversation. '
        '${List.filled(60, 'More text continues in the same paragraph.').join(' ')}',
      );
      await tester.dragFrom(
        _glyphCenter(tester, 'Drag this'),
        const Offset(35, -140),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(scroll.offset, greaterThan(100));
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: _phones,
  );

  testWidgets('Markdown still supports long press selection and copying', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    final scroll = await _pumpMessage(
      tester,
      'Select a **word** in this paragraph.\n\nAnother paragraph.',
    );
    await tester.longPressAt(_glyphCenter(tester, 'Select a'));
    await tester.pumpAndSettle();

    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copiedText, 'Select');
    expect(scroll.offset, 0);
    expect(tester.takeException(), isNull);
  }, variant: _phones);

  testWidgets('Markdown links remain tappable after a touch scroll', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
      }
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final scroll = await _pumpMessage(
      tester,
      '[Read the source](https://example.invalid/comic)',
    );
    await tester.dragFrom(
      _glyphCenter(tester, 'Read the source'),
      const Offset(0, -100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(60));
    expect(launched, isEmpty);

    await tester.tapAt(_glyphCenter(tester, 'Read the source'));
    await tester.pumpAndSettle();
    expect(launched, ['https://example.invalid/comic']);
    expect(tester.takeException(), isNull);
  }, variant: _phones);
}
