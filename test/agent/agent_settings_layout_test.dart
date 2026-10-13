import 'dart:io';
import 'dart:ui' as ui;

import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_model_header.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_store.dart';

import 'agent_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontPath = Platform.environment['AGENT_UI_PREVIEW_FONT'];
  final outputPath = Platform.environment['AGENT_UI_PREVIEW_DIR'];
  final boundaryKey = GlobalKey();
  late Directory root;
  late AgentStore store;
  const model = AgentModel(
    id: 'primary',
    name: '通用推理模型',
    baseUrl: 'https://gateway.example.org/v1',
    model: 'reasoning-model',
    protocol: AgentProtocol.messages,
    nativeWebSearch: true,
    thinkingLevels: [
      AgentThinkingLevel(id: 'low', label: '低'),
      AgentThinkingLevel(id: 'medium', label: '中'),
      AgentThinkingLevel(id: 'high', label: '高'),
    ],
    defaultThinking: 'high',
  );

  setUpAll(() async {
    if (fontPath != null) {
      final loader = FontLoader('AgentUITestFont')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-settings-layout-');
    configureAgentTestPaths(root.path);
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(
      const AgentSettings(
        models: [
          model,
          AgentModel(
            id: 'fast',
            name: '快速助手',
            baseUrl: 'https://gateway.example.org/v1',
            model: 'fast-model',
          ),
        ],
        defaultModelId: 'primary',
        webSearch: AgentWebSearchSettings(bing: true),
      ),
      const {},
    );
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  ThemeData theme(Brightness brightness) => ThemeData(
    colorScheme: SeedColorScheme.fromSeeds(
      primaryKey: const Color(0xffaabbff),
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    ),
    fontFamily: fontPath == null ? null : 'AgentUITestFont',
  );

  Future<void> capture(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    if (outputPath == null) return;
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(outputPath).create(recursive: true);
        await File(
          '$outputPath/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  for (final (width, height, scale, brightness) in [
    (400.0, 889.0, 1.0, Brightness.dark),
    (320.0, 780.0, 2.0, Brightness.dark),
    (900.0, 600.0, 1.6, Brightness.light),
  ]) {
    testWidgets(
      'settings remain navigable at $width x $height with text scale $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, height);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: AgentSettingsPage(store: store),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final suffix = '${width.toInt()}-$scale';
        expect(find.byType(TextFormField), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
        await capture(tester, 'settings-$suffix');
        await tapAgentSetting(tester, 'agent-settings-search');
        expect(find.byType(SwitchListTile), findsNothing);
        await capture(tester, 'search-$suffix');
        await tapAgentSetting(tester, 'agent-search-provider-tavily');
        expect(
          find.byKey(const ValueKey('agent-tavily-key-input')),
          findsNothing,
        );
        await capture(tester, 'provider-disabled-$suffix');
        await tapAgentSetting(tester, 'agent-search-tavily');
        final apiKey = find.byKey(const ValueKey('agent-tavily-key-input'));
        await tester.ensureVisible(apiKey);
        await capture(tester, 'provider-enabled-$suffix');
        await tester.tap(find.byKey(const ValueKey('agent-tavily-save-key')));
        await tester.pumpAndSettle();
        expect(find.text('请填写此项'), findsOneWidget);
        expect(store.settings.webSearch.tavily, false);
        await back(tester);
        expect(store.settings.webSearch.tavily, false);
        await back(tester);
        await tapAgentSetting(tester, 'agent-source-backups', settle: false);
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (i >= 2 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        await capture(tester, 'backups-$suffix');
        expect(find.byType(ExpansionTile), findsNothing);
        await back(tester);
        await tapAgentSetting(tester, 'agent-settings-models');
        await capture(tester, 'models-$suffix');
        await tapAgentSetting(tester, 'agent-managed-model-primary');
        await capture(tester, 'model-editor-$suffix');
        await tapAgentSetting(tester, 'agent-model-capabilities');
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('agent-model-native-search')),
              )
              .value,
          true,
        );
        expect(find.textContaining('DeepSeek'), findsNothing);
        await capture(tester, 'model-capabilities-$suffix');
        await back(tester);
        await tapAgentSetting(tester, 'agent-model-advanced');
        final field = find.byKey(const ValueKey('agent-model-body'));
        final label = find.text('额外请求体');
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(label).bottom,
          lessThan(tester.getRect(field).top),
        );
        await capture(tester, 'model-advanced-$suffix');
        await tester.enterText(field, '{"provider_option":true}');
        await back(tester);
        await tapAgentSetting(tester, 'agent-model-advanced');
        expect(
          tester.widget<TextFormField>(field).controller!.text,
          '{"provider_option":true}',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('model picker fits large text, keyboard and a long model list', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 889);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final textScale = ValueNotifier(1.0);
    addTearDown(textScale.dispose);
    final controller = AgentController(store);
    final bridge = AgentModelHeaderBridge()..bind(controller);
    addTearDown(() {
      bridge.dispose();
      controller.dispose();
    });
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.dark),
          builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: textScale,
            builder: (context, scale, _) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: Scaffold(
            appBar: AppBar(
              title: SizedBox(
                width: 220,
                child: AgentModelHeader(bridge: bridge),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapAgentSetting(tester, 'agent-model-header');
    await capture(tester, 'model-picker');
    final fast = store.settings.models.last;
    await tester.runAsync(
      () => store.saveSettings(
        store.settings.copyWith(
          models: [
            model,
            for (var i = 0; i < 20; i++)
              AgentModel(
                id: 'extra-$i',
                name: '备用模型 $i：较长的用途与版本说明',
                baseUrl: model.baseUrl,
                model: 'example-model-$i',
              ),
            fast,
          ],
        ),
        {},
      ),
    );
    controller.reload();
    textScale.value = 2;
    tester.view.physicalSize = const Size(320, 780);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-model-search')),
      'fast',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    await tapAgentSetting(tester, 'agent-picker-model-fast');
    expect(controller.model!.id, 'fast');
    expect(tester.takeException(), isNull);
  });
}
