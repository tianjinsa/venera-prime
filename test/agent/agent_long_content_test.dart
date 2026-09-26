import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_text_view.dart';

String _longReply(int paragraphs) => [
  for (var i = 0; i < paragraphs; i++)
    '## 第 $i 节\n\n${'这一段介绍漫画的剧情与人物。' * 12}\n\n'
        '- 要点 A$i\n- 要点 B$i\n\n'
        '```\ncode $i\n\nstill code $i\n```',
].join('\n\n');

Widget _message(String text) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: AgentMessageParts(
        message: AgentMessage(
          id: 'long',
          conversationId: 'c',
          role: 'assistant',
          createdAt: 1,
          parts: [
            {'type': 'text', 'text': text},
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
    ),
  ),
);

void main() {
  test('markdown chunks reassemble exactly and respect block structure', () {
    final text = _longReply(30);
    final chunks = agentMarkdownChunks(text);
    expect(chunks.length, greaterThan(3));
    expect(chunks.join(), text);
    for (final chunk in chunks.skip(1)) {
      // Never split before a list item or indented content.
      expect(chunk, isNot(matches(RegExp(r'^(\s|[-*+] |\d+\. )'))));
    }
    // Never split inside a fence: each chunk opens and closes its fences.
    for (final chunk in chunks) {
      expect('```'.allMatches(chunk).length.isEven, true);
    }
    expect(agentMarkdownChunks('short'), ['short']);
  });

  test('streaming only changes the last markdown chunk', () {
    final text = _longReply(20);
    var previous = agentMarkdownChunks(text.substring(0, 2000));
    for (var end = 2100; end <= text.length; end += 97) {
      final chunks = agentMarkdownChunks(text.substring(0, end));
      // Every completed chunk is kept unchanged as more text arrives.
      for (var i = 0; i < previous.length - 1; i++) {
        expect(chunks[i], previous[i]);
      }
      previous = chunks;
    }
  });

  test('plain text chunks keep every character and line break', () {
    final text = List.generate(400, (i) => '第$i行\r\n').join();
    final chunks = agentTextChunks(text);
    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), text);
    expect(chunks.every((c) => c.length <= 2048), true);
  });

  testWidgets('long replies parse only the changed chunk while streaming', (
    tester,
  ) async {
    final text = _longReply(12);
    await tester.pumpWidget(_message(text));
    final bodies = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .toList();
    expect(bodies.length, agentMarkdownChunks(text).length);
    expect(bodies.map((b) => b.data).join('\n\n').length, greaterThan(0));

    await tester.pumpWidget(_message('$text\n\n追加的新段落'));
    final updated = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .toList();
    // Unchanged chunks reuse their widget, so Flutter skips their subtree.
    for (var i = 0; i < bodies.length - 1; i++) {
      expect(identical(updated[i], bodies[i]), true, reason: 'chunk $i');
    }
    expect(updated.last.data, endsWith('追加的新段落'));
    expect(find.textContaining('追加的新段落', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
