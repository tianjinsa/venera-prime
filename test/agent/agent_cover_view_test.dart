import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_message_view.dart';
import 'package:venera/agent/agent_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = File('assets/app_icon.png').readAsBytesSync();

  AgentMessage coverMessage() => AgentMessage(
    id: 'cover',
    conversationId: 'conversation',
    role: 'assistant',
    createdAt: 1,
    parts: [
      {
        'type': 'tool_call',
        'id': 'call',
        'name': 'comic_cover',
        'arguments': {'source_key': 'jm', 'comic_id': '7'},
        'state': 'done',
        'images': [
          {
            'type': 'image',
            'id': 'cover-image',
            'name': '测试漫画.png',
            'mime_type': 'image/png',
            'byte_length': png.length,
          },
        ],
        'result': {
          'ok': true,
          'data': {
            'url': 'https://example.invalid/cover',
            'source_key': 'jm',
            'comic_id': '7',
            'title': '测试漫画',
          },
        },
      },
      {'type': 'text', 'text': '封面是蓝色调的。'},
    ],
  );

  testWidgets('a cover read by a tool is shown with its receipt', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentMessageParts(
              message: coverMessage(),
              indices: const [0, 1],
              busy: false,
              imageLoader: (_, image) => image.id == 'cover-image' ? png : null,
              canRetry: (_) => false,
              onRetry: (_) {},
              onShowcase: (_) {},
              hasUndo: (_) => false,
              onUndo: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The label above the strip says what these images are.
    expect(find.text('工具读取的图片（1）'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-cover-image')), findsOneWidget);
    // Collapsed by default, but the caption already names the comic.
    expect(find.text('查看漫画封面'), findsOneWidget);
    expect(find.text('《测试漫画》'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toggle-tool-cover-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"tool": "comic_cover"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a message without tool images shows no strip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMessageParts(
            message: AgentMessage(
              id: 'plain',
              conversationId: 'conversation',
              role: 'assistant',
              createdAt: 1,
              parts: [
                {'type': 'text', 'text': '没有图片'},
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
    await tester.pumpAndSettle();
    expect(find.textContaining('工具读取的图片'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
