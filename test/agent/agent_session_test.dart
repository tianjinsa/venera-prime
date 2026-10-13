import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_integration.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_notice.dart';
import 'package:venera/agent/agent_session.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';
import 'agent_test_support.dart';

class _StreamingClient extends AgentClient {
  int requestCount = 0;
  late AgentDelta _onDelta;
  late Completer<AgentResponse> _response;

  void emit(String text) => _onDelta('text', text);
  void finish(AgentResponse response) => _response.complete(response);

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
    requestCount++;
    _onDelta = onDelta;
    _response = Completer();
    return run.wait(_response.future);
  }
}

class _RecordingTools extends AgentTools {
  final calls = <String>[];
  _RecordingTools(super.store);

  @override
  Future<AgentJson> execute(
    String name,
    AgentJson args,
    AgentToolContext context,
  ) async {
    calls.add(name);
    return {
      'ok': true,
      'data': {'added': 1},
    };
  }
}

class _TabHost extends StatefulWidget {
  const _TabHost();

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  final _observer = NaviObserver();
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NaviPane(
    initialPage: 1,
    observer: _observer,
    navigatorKey: _navigator,
    paneItems: [
      PaneItemEntry(
        label: '首页',
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
      ),
      agentPaneItem,
    ],
    paneActions: const [],
    // Like the app's main page, each tab builds a fresh page widget.
    pageBuilder: (tab) => tab == 1
        ? const AgentPage()
        : const Scaffold(body: Center(child: Text('其他页面'))),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previewFont = Platform.environment['AGENT_UI_PREVIEW_FONT'];
  final previewDirectory = Platform.environment['AGENT_UI_PREVIEW_DIR'];
  final previewBoundary = GlobalKey();
  const model = AgentModel(
    id: 'streaming',
    name: '流式模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test',
  );
  final input = find.byKey(const ValueKey('agent-input'));
  final send = find.byKey(const ValueKey('agent-send'));
  final homeTab = find.byIcon(Icons.home_outlined).hitTestable();
  // The model picker also uses the sparkle icon; scope this to navigation.
  final agentTab = find
      .descendant(
        of: find.byType(AgentTabBadge),
        matching: find.byIcon(Icons.auto_awesome_outlined),
      )
      .hitTestable();
  // The side and bottom navigation are both built; only one is on screen.
  final running = find.byKey(const ValueKey('agent-tab-running')).hitTestable();
  final unread = find.byKey(const ValueKey('agent-tab-unread')).hitTestable();
  final waiting = find.byKey(const ValueKey('agent-tab-confirm')).hitTestable();
  final notice = find.byKey(const ValueKey('agent-confirm-notice'));
  late Directory root;
  late _StreamingClient client;
  late _RecordingTools tools;
  late AgentController controller;

  Future<void> useSettings(AgentSettings settings) =>
      controller.store.saveSettings(settings, const {});

  setUpAll(() async {
    await AppTranslation.init();
    if (previewFont == null) return;
    await (FontLoader('AgentSessionPreview')
          ..addFont(File(previewFont).readAsBytes().then(ByteData.sublistView)))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-session-');
    configureAgentTestPaths(root.path);
    client = _StreamingClient();
    AgentSession.createController = (store) {
      tools = _RecordingTools(store);
      return AgentController(store, client: client, tools: tools);
    };
    // Opened outside the fake clock; the page then reuses the same session.
    controller = await AgentSession.open();
    await useSettings(
      const AgentSettings(models: [model], defaultModelId: 'streaming'),
    );
  });

  tearDown(() async {
    await AgentSession.reset();
    await root.delete(recursive: true);
  });

  /// The running indicators animate, so frames are pumped for a fixed time
  /// instead of settling.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The badge follows a page leaving the tree on the next frame.
    await tester.pump();
  }

  /// A page built on the fake clock waits for the session opened in setUp
  /// on the real event loop.
  Future<void> showAgentTab(WidgetTester tester) async {
    await tester.tap(agentTab);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    if (previewDirectory == null) return;
    await tester.runAsync(() async {
      final boundary =
          previewBoundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(previewDirectory).create(recursive: true);
        await File(
          '$previewDirectory/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> startTask(
    WidgetTester tester, {
    bool actualMainPage = false,
    String prompt = '推荐漫画',
    String streamedText = '第一段。',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: App.rootNavigatorKey,
          theme: ThemeData(
            colorScheme: SeedColorScheme.fromSeeds(
              primaryKey: const Color(0xffaabbff),
              brightness: Brightness.dark,
              tones: FlexTones.vividBackground(Brightness.dark),
            ),
            fontFamily: previewFont == null ? null : 'AgentSessionPreview',
          ),
          builder: (_, child) => OverlayWidget(child!),
          home: actualMainPage ? const MainPage() : const _TabHost(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    if (actualMainPage) await showAgentTab(tester);
    await tester.enterText(input, prompt);
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    client.emit(streamedText);
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.busy, isTrue);
    // The page in view already shows the progress.
    expect(running, findsNothing);
  }

  Future<void> finish(WidgetTester tester) async {
    controller.stop();
    await settle(tester);
    expect(controller.busy, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('a running task continues while another tab is shown', (
    tester,
  ) async {
    await startTask(tester);

    await tester.tap(homeTab);
    await settle(tester);
    expect(find.byType(AgentPage), findsNothing);
    expect(find.text('其他页面'), findsOneWidget);
    expect(running, findsOneWidget);

    // Output streamed while the page is gone still reaches the task.
    client.emit('第二段。');
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.busy, isTrue);
    expect(controller.error, isNull);
    expect(controller.messages.last.text, '第一段。第二段。');

    await showAgentTab(tester);
    expect(await tester.runAsync(AgentSession.open), same(controller));
    expect(find.textContaining('第一段。第二段。', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-stop')), findsOneWidget);
    expect(running, findsNothing);
    await finish(tester);
  });

  testWidgets('a reply finished in the background stays unread until seen', (
    tester,
  ) async {
    await startTask(tester);
    await tester.tap(homeTab);
    await settle(tester);

    client.finish(const AgentResponse('推荐完成。', '', []));
    await settle(tester);
    expect(controller.busy, isFalse);
    expect(running, findsNothing);
    expect(unread, findsOneWidget);

    await showAgentTab(tester);
    expect(unread, findsNothing);
    await tester.tap(homeTab);
    await settle(tester);
    // Seen results do not mark the tab again.
    expect(unread, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a background confirmation opens the agent on its own route', (
    tester,
  ) async {
    await tester.runAsync(
      () => useSettings(
        const AgentSettings(
          models: [model],
          defaultModelId: 'streaming',
          confirmPolicy: 'all',
        ),
      ),
    );
    await startTask(tester);
    await tester.tap(homeTab);
    await settle(tester);

    client.finish(
      const AgentResponse('', '', [
        AgentToolCall('add', 'later_add', '{"comics":["jm:123"]}'),
      ]),
    );
    await settle(tester);
    expect(controller.confirmation?.name, 'later_add');
    expect(waiting, findsOneWidget);
    expect(notice, findsOneWidget);
    expect(find.text('Agent 需要确认：允许加入稍后再看？'), findsOneWidget);

    await tester.tap(find.text('查看'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
    expect(notice, findsNothing);
    final page = tester.widget<AgentPage>(find.byType(AgentPage));
    expect(page.standalone, isTrue);
    // Covers the navigation bars and their actions.
    expect(homeTab, findsNothing);
    expect(agentTab, findsNothing);
    expect(find.byType(AgentTabBadge).hitTestable(), findsNothing);
    expect(find.text('允许加入稍后再看？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-back')));
    await settle(tester);
    expect(find.byType(AgentPage), findsNothing);
    expect(find.text('其他页面'), findsOneWidget);
    // Still waiting, but the request was seen and is not announced again.
    expect(waiting, findsOneWidget);
    expect(notice, findsNothing);
    await finish(tester);
  });

  for (final allow in [false, true]) {
    testWidgets(
      'the actual app handles ${allow ? 'allow' : 'deny'} on a standalone confirmation and returns to the previous page',
      (tester) async {
        final previousLanguage = appdata.settings['language'];
        final previousInitialPage = appdata.settings['initialPage'];
        appdata.settings['language'] = 'zh-CN';
        appdata.settings['initialPage'] = '3';
        addTearDown(() {
          appdata.settings['language'] = previousLanguage;
          appdata.settings['initialPage'] = previousInitialPage;
          App.mainNavigatorKey = null;
        });
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.runAsync(
          () => useSettings(
            const AgentSettings(
              models: [model],
              defaultModelId: 'streaming',
              confirmPolicy: 'all',
            ),
          ),
        );
        await startTask(
          tester,
          actualMainPage: true,
          prompt: '把这本漫画加入稍后再看',
          streamedText: '我会将这本漫画加入稍后再看，操作前需要你的确认。',
        );
        await tester.tap(find.byIcon(Icons.category_outlined).hitTestable());
        await settle(tester);
        final previousPane = tester.state<NaviPaneState>(find.byType(NaviPane));
        expect(previousPane.currentPage, 4);
        expect(find.byType(CategoriesPage), findsOneWidget);
        await tester.tap(find.byIcon(Icons.settings).hitTestable());
        await settle(tester);
        final previousSettings = tester.widget<SettingsPage>(
          find.byType(SettingsPage),
        );
        final previousRoute = ModalRoute.of(
          tester.element(find.byType(SettingsPage)),
        );

        client.finish(
          const AgentResponse('', '', [
            AgentToolCall('add', 'later_add', '{"comics":["example:123"]}'),
          ]),
        );
        await settle(tester);
        expect(controller.confirmation?.name, 'later_add');
        expect(tools.calls, isEmpty);
        expect(notice, findsOneWidget);
        expect(AgentSession.status.value, AgentTabStatus.confirm);
        if (allow) await capture(tester, 'permission-01-background');

        await tester.tap(notice);
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await settle(tester);
        expect(await tester.runAsync(AgentSession.open), same(controller));
        expect(
          tester.widget<AgentPage>(find.byType(AgentPage)).standalone,
          true,
        );
        expect(find.byType(AgentTabBadge).hitTestable(), findsNothing);
        expect(
          find.byIcon(Icons.handyman_outlined).hitTestable(),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('agent-back')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('允许加入稍后再看？'), findsOneWidget);
        expect(notice, findsNothing);
        if (allow) await capture(tester, 'permission-02-standalone');

        await tester.tap(find.text(allow ? '允许' : '拒绝'));
        await settle(tester);
        expect(controller.confirmation, isNull);
        expect(tools.calls, allow ? ['later_add'] : isEmpty);
        expect(client.requestCount, 2);
        final toolResult =
            controller.messages
                    .expand((message) => message.parts)
                    .where((part) => part['type'] == 'tool_call')
                    .single['result']
                as Map;
        expect(toolResult['ok'], allow);
        if (!allow) expect((toolResult['error'] as Map)['code'], 'USER_DENIED');
        client.finish(AgentResponse(allow ? '已加入稍后再看。' : '已拒绝，未执行操作。', '', []));
        await settle(tester);
        expect(controller.busy, false);

        await tester.tap(find.byKey(const ValueKey('agent-back')));
        await settle(tester);
        expect(find.byType(AgentPage), findsNothing);
        expect(
          tester.widget<SettingsPage>(find.byType(SettingsPage)),
          same(previousSettings),
        );
        expect(
          ModalRoute.of(tester.element(find.byType(SettingsPage))),
          same(previousRoute),
        );
        expect(
          tester.state<NaviPaneState>(find.byType(NaviPane)),
          same(previousPane),
        );
        expect(previousPane.currentPage, 4);
        expect(agentTab, findsNothing);
        expect(waiting, findsNothing);
        expect(notice, findsNothing);
        if (allow) await capture(tester, 'permission-03-returned');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
