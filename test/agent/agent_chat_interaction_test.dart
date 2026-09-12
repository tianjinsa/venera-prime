import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_integration.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/components/components.dart';
import 'agent_images_resources_test.dart' show resourceImage;
import 'agent_test_support.dart';

class _StreamingClient extends AgentClient {
  late AgentDelta _onDelta;
  final _response = Completer<AgentResponse>();

  void emit(String text) => _onDelta('text', text);

  @override
  Future<AgentResponse> complete({
    required AgentModel model,
    required String apiKey,
    required String? thinkingId,
    required List<AgentJson> messages,
    required List<AgentJson> tools,
    required AgentRun run,
    required AgentDelta onDelta,
  }) {
    _onDelta = onDelta;
    return run.wait(_response.future);
  }
}

void main() {
  const model = AgentModel(
    id: 'streaming',
    name: '流式模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
    supportsVision: true,
  );
  final input = find.byKey(const ValueKey('agent-input'));
  final send = find.byKey(const ValueKey('agent-send'));
  final pause = find.byKey(const ValueKey('agent-stop'));
  final messages = find.byKey(const ValueKey('agent-messages'));
  late Directory root;
  late AgentStore store;
  late AgentController controller;
  late _StreamingClient client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-chat-interaction-');
    configureAgentTestPaths(root.path);
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(const AgentSettings(models: [model]), {});
    client = _StreamingClient();
    controller = AgentController(store, client: client);
  });

  tearDown(() async {
    controller.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpAgent(
    WidgetTester tester, {
    bool withNavigation = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final page = AgentPage(
      controller: controller,
      imagePicker: () async => [resourceImage('draft')],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: withNavigation
            ? NaviPane(
                initialPage: 1,
                paneItems: [
                  PaneItemEntry(
                    label: '首页',
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home,
                  ),
                  agentPaneItem,
                ],
                paneActions: const [],
                pageBuilder: (_) => page,
                observer: NaviObserver(),
                navigatorKey: GlobalKey<NavigatorState>(),
              )
            : page,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> emit(WidgetTester tester, String text) async {
    client.emit(text);
    await tester.pump(const Duration(milliseconds: 100));
    // Follow both content layout and any lazy-list scroll extent correction.
    await tester.pump();
    await tester.pump();
  }

  Future<ScrollPosition> startLongReply(WidgetTester tester) async {
    await pumpAgent(tester);
    await tester.enterText(input, '列出漫画');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    await emit(
      tester,
      List.generate(60, (i) => '第 $i 行 **漫画介绍**。').join('\n\n'),
    );
    final position = tester.widget<ListView>(messages).controller!.position;
    expect(position.maxScrollExtent, greaterThan(1000));
    expect(position.extentAfter, lessThan(1));
    return position;
  }

  Future<TestGesture> startDrag(WidgetTester tester, double delta) async {
    final rect = tester.getRect(messages);
    // Exercise the outer list here; Markdown glyph gestures have their own test.
    final gesture = await tester.startGesture(
      Offset(rect.left + 4, rect.center.dy),
    );
    await gesture.moveBy(Offset(0, delta));
    await tester.pump();
    return gesture;
  }

  Future<void> endDrag(WidgetTester tester, TestGesture gesture) async {
    // Release without a fling, so the final direction and distance are explicit.
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('keyboard consumes no extra bottom navigation height', (
    tester,
  ) async {
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpAgent(tester, withNavigation: true);
    await tester.enterText(input, '键盘布局');
    for (final keyboardHeight in [0.0, 300.0, 370.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      tester.view.padding = FakeViewPadding(
        top: 24,
        bottom: keyboardHeight == 0 ? 24 : 0,
      );
      await tester.pumpAndSettle();
      final bottomBar = keyboardHeight == 0 ? 58 + 24 : 0;
      expect(
        tester.getBottomLeft(input).dy,
        closeTo(900 - keyboardHeight - bottomBar - 12, 1),
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one running action switches between insert and pause', (
    tester,
  ) async {
    await pumpAgent(tester);
    await tester.enterText(input, '开始任务');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    expect(controller.busy, isTrue);
    expect(pause, findsOneWidget);
    expect(send, findsNothing);

    await tester.enterText(input, '补充要求');
    await tester.pump();
    expect(send, findsOneWidget);
    expect(pause, findsNothing);
    expect(find.byTooltip('插入消息（Ctrl+Enter）'), findsOneWidget);
    await tester.enterText(input, ' \n ');
    await tester.pump();
    expect(pause, findsOneWidget);
    expect(send, findsNothing);

    // Text-controller updates (including restoring drafts) also switch actions.
    tester.widget<TextField>(input).controller!.text = '改为只整理收藏';
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    expect(controller.messages.last.text, '改为只整理收藏');
    expect(controller.messages.last.state, 'queued');
    expect(pause, findsOneWidget);
    expect(send, findsNothing);

    // An image-only follow-up remains sendable with the same single action.
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pump();
    expect(send, findsOneWidget);
    expect(pause, findsNothing);
    await tester.tap(send);
    await tester.pump();
    expect(controller.messages.last.images.single.id, 'draft');
    expect(pause, findsOneWidget);
    expect(send, findsNothing);
    await tester.tap(pause);
    await tester.pumpAndSettle();
    expect(controller.busy, isFalse);
    expect(pause, findsNothing);
    expect(send, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stream yields to drags and resumes only toward the nearby end', (
    tester,
  ) async {
    final position = await startLongReply(tester);

    // A notification may already have queued a follow before the finger moves.
    controller.searchHistory('');
    final away = await startDrag(tester, 65);
    expect(position.extentAfter, inExclusiveRange(0, 160));
    final draggedOffset = position.pixels;
    await emit(tester, '\n\n拖动期间的新内容。');
    expect(position.pixels, closeTo(draggedOffset, 1));
    await endDrag(tester, away);
    await emit(tester, '\n\n离开底部后继续输出。');
    expect(position.pixels, closeTo(draggedOffset, 1));

    final toward = await startDrag(tester, -70);
    final heldOffset = position.pixels;
    expect(position.extentAfter, lessThan(160));
    await emit(tester, '\n\n上滑期间也不抢占位置。');
    expect(position.pixels, closeTo(heldOffset, 1));
    await toward.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(position.extentAfter, lessThan(160));
    await endDrag(tester, toward);
    expect(position.extentAfter, lessThan(1));
    await emit(tester, '\n\n恢复自动跟随。');
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'scrolling toward newer content far from the end stays detached',
    (tester) async {
      final position = await startLongReply(tester);
      await endDrag(tester, await startDrag(tester, 450));
      expect(position.extentAfter, greaterThan(300));
      await endDrag(tester, await startDrag(tester, -70));
      expect(position.extentAfter, greaterThan(160));
      final offset = position.pixels;
      await emit(tester, '\n\n仍在浏览历史时新增的内容。');
      expect(position.pixels, closeTo(offset, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('holding rendered text at the bottom prevents streaming jumps', (
    tester,
  ) async {
    final position = await startLongReply(tester);
    final rect = tester.getRect(messages);
    Offset? holdOrigin;
    final text = find.descendant(of: messages, matching: find.byType(RichText));
    for (final element in text.evaluate()) {
      final render = element.renderObject;
      if (render is! RenderParagraph) continue;
      final boxes = render.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 1),
      );
      if (boxes.isEmpty) continue;
      final point = render.localToGlobal(boxes.first.toRect().center);
      if (rect.deflate(8).contains(point)) {
        holdOrigin = point;
        break;
      }
    }
    expect(holdOrigin, isNotNull);
    final hold = await tester.startGesture(holdOrigin!);
    await tester.pump();
    expect(position.isScrollingNotifier.value, isFalse);
    final offset = position.pixels;
    await emit(tester, '\n\n按住列表时到达的新内容。');
    expect(position.pixels, closeTo(offset, 1));
    await hold.up();
    await tester.pump();
    await tester.pump();
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('streaming waits for a user fling to finish before following', (
    tester,
  ) async {
    final position = await startLongReply(tester);
    await endDrag(tester, await startDrag(tester, 350));
    final rect = tester.getRect(messages);
    await tester.flingFrom(
      Offset(rect.left + 4, rect.center.dy),
      const Offset(0, -90),
      1000,
    );
    for (var frame = 0; frame < 30 && position.extentAfter > 150; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.extentAfter, inExclusiveRange(0, 160));
    expect(position.isScrollingNotifier.value, isTrue);
    client.emit('\n\n惯性滚动期间到达的新内容。');
    controller.searchHistory('');
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.isScrollingNotifier.value, isTrue);
    expect(position.extentAfter, greaterThan(1));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
