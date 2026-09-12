import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_integration.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/components/components.dart';
import 'agent_test_support.dart';

class _HeaderHost extends StatefulWidget {
  final AgentModelHeaderBridge bridge;
  final List<AgentController> controllers;
  const _HeaderHost({required this.bridge, required this.controllers});

  @override
  State<_HeaderHost> createState() => _HeaderHostState();
}

class _HeaderHostState extends State<_HeaderHost> {
  final _observer = NaviObserver();
  final _navigatorKey = GlobalKey<NavigatorState>();
  int _tab = 1;
  int _generation = 0;

  @override
  Widget build(BuildContext context) => NaviPane(
    initialPage: _tab,
    navigatorKey: _navigatorKey,
    observer: _observer,
    paneItems: [
      PaneItemEntry(
        label: '首页',
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
      ),
      agentPaneItem,
    ],
    paneActions: [
      PaneActionEntry(label: '搜索', icon: Icons.search, onTap: () {}),
      PaneActionEntry(label: '设置', icon: Icons.settings, onTap: () {}),
    ],
    mobileTitleAccessory: _tab == 1
        ? AgentModelHeader(bridge: widget.bridge)
        : null,
    onPageChanged: (tab) => setState(() {
      if (tab == 1 && _generation + 1 < widget.controllers.length) {
        _generation++;
      }
      _tab = tab;
    }),
    pageBuilder: (tab) => tab == 1
        ? AgentPage(
            key: ValueKey('page-$_generation'),
            controller: widget.controllers[_generation],
            modelHeaderBridge: widget.bridge,
          )
        : const Scaffold(body: Center(child: Text('其他页面'))),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const firstModel = AgentModel(
    id: 'first',
    name: '名称很长的主模型，包含提供商、版本与用途说明',
    baseUrl: 'https://example.invalid/v1',
    model: 'first-model',
    thinkingLevels: [
      AgentThinkingLevel(id: 'normal', label: '默认思考深度'),
      AgentThinkingLevel(id: 'deep', label: '深入思考与分析'),
    ],
    defaultThinking: 'normal',
  );
  const secondModel = AgentModel(
    id: 'second',
    name: '备用模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'second-model',
    thinkingLevels: [
      AgentThinkingLevel(id: 'fast', label: '快速'),
      AgentThinkingLevel(id: 'deep', label: '深入'),
    ],
    defaultThinking: 'fast',
  );
  final header = find.byKey(const ValueKey('agent-model-header'));
  final panel = find.byKey(const ValueKey('agent-model-selection-panel'));
  final modelSelector = find.byKey(
    const ValueKey('agent-header-model-selector'),
  );
  final thinkingSelector = find.byKey(
    const ValueKey('agent-header-thinking-selector'),
  );
  late Directory directory;
  late AgentModelHeaderBridge bridge;
  final controllers = <AgentController>[];

  Future<AgentController> makeController() async {
    final store = await AgentStore.open(
      '${directory.path}/agent-${controllers.length}',
    );
    await store.saveSettings(
      const AgentSettings(
        models: [firstModel, secondModel],
        defaultModelId: 'first',
      ),
      const {},
    );
    final controller = AgentController(store);
    controllers.add(controller);
    return controller;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-model-header-');
    configureAgentTestPaths(directory.path);
    bridge = AgentModelHeaderBridge();
    await makeController();
  });

  tearDown(() async {
    bridge.dispose();
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await directory.delete(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester, {double width = 400}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: _HeaderHost(bridge: bridge, controllers: controllers),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 400.0]) {
    testWidgets('compact header fits long model names at width $width', (
      tester,
    ) async {
      await pumpHost(tester, width: width);
      expect(header, findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
      final rect = tester.getRect(header);
      final search = tester.getRect(find.byTooltip('搜索').hitTestable());
      expect(rect.left, greaterThan(16));
      expect(rect.right, lessThanOrEqualTo(search.left));
      expect(rect.height, lessThanOrEqualTo(48));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-header-model-name')))
            .data,
        firstModel.name,
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(modelSelector, findsOneWidget);
      expect(thinkingSelector, findsOneWidget);
      // The first tap expands the panel, not a popup list of model options.
      expect(find.text(secondModel.name), findsNothing);
      expect(tester.getSize(panel).width, greaterThan(rect.width));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'expanded selectors update the conversation and compact display',
    (tester) async {
      await pumpHost(tester, width: 320);
      await tester.tap(header);
      await tester.pumpAndSettle();
      await tester.tap(modelSelector);
      await tester.pumpAndSettle();
      await tester.tap(find.text(secondModel.name).last);
      await tester.pumpAndSettle();
      expect(controllers.first.model?.id, secondModel.id);
      expect(controllers.first.thinkingId, 'fast');
      expect(panel, findsOneWidget);
      await tester.tap(thinkingSelector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('深入').last);
      await tester.pumpAndSettle();
      expect(controllers.first.thinkingId, 'deep');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-header-model-name')))
            .data,
        secondModel.name,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('agent-header-thinking-name')),
            )
            .data,
        '深入',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'running disables both selectors, including an already open panel',
    (tester) async {
      await pumpHost(tester);
      await tester.tap(header);
      await tester.pumpAndSettle();
      controllers.first.busy = true;
      controllers.first.reload();
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButton<String>>(modelSelector).onChanged,
        isNull,
      );
      expect(
        tester.widget<DropdownButton<String>>(thinkingSelector).onChanged,
        isNull,
      );
      expect(find.text('运行中，暂时不能切换模型或思考深度。'), findsOneWidget);
      controllers.first.busy = false;
      controllers.first.reload();
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButton<String>>(modelSelector).onChanged,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide layouts retain the existing model selectors', (
    tester,
  ) async {
    await pumpHost(tester, width: 1000);
    expect(header, findsNothing);
    expect(find.byType(DropdownButton<String>), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tab changes detach old controllers without clearing a new binding',
    (tester) async {
      final second = (await tester.runAsync(makeController))!;
      second.selectModel(secondModel.id);
      await pumpHost(tester);
      final pane = tester.state<NaviPaneState>(find.byType(NaviPane));
      pane.updatePage(0);
      await tester.pump();
      expect(header, findsNothing);
      pane.updatePage(1);
      await tester.pumpAndSettle();
      expect(bridge.controller, same(second));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-header-model-name')))
            .data,
        secondModel.name,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(bridge.controller, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'binding defers notifications and ignores unrelated conversation updates',
    (tester) async {
      var notifications = 0;
      bridge.addListener(() => notifications++);
      bridge.bind(controllers.first);
      expect(notifications, 0);
      await tester.pump();
      expect(notifications, 1);
      controllers.first.reload();
      await tester.pump();
      expect(notifications, 1);
      bridge.unbind(controllers.first);
      expect(notifications, 1);
      await tester.pump();
      expect(notifications, 2);
      expect(bridge.controller, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
