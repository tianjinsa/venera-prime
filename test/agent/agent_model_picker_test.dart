import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_model_discovery.dart';
import 'package:venera/agent/agent_model_picker.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_store.dart';
import 'agent_test_support.dart';

class RecordingDiscovery extends AgentModelDiscovery {
  final Future<List<AgentProviderModel>> Function() respond;
  AgentModel? connection;
  String? key;
  AgentRun? run;
  bool closed = false;
  RecordingDiscovery(this.respond) : super(dio: Dio());
  @override
  Future<List<AgentProviderModel>> fetch({
    required AgentModel connection,
    required String apiKey,
    required AgentRun run,
  }) {
    this.connection = connection;
    key = apiKey;
    this.run = run;
    return respond();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  const original = AgentModel(
    id: 'existing',
    name: '我的模型',
    baseUrl: 'https://old.invalid/v1',
    model: 'old',
  );
  late Directory root;
  late AgentStore store;
  late RecordingDiscovery discovery;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-picker-');
    configureAgentTestPaths(root.path);
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(const AgentSettings(models: [original]), {
      original.id: 'old-key',
    });
    discovery = RecordingDiscovery(
      () async => const [
        AgentProviderModel('provider-a', '模型甲'),
        AgentProviderModel('exact/b:latest', '模型乙'),
      ],
    );
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });
  Finder field(String key) => find.byKey(ValueKey('agent-model-$key'));

  Future<void> openEditor(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentModelsPage(store: store, discoveryFactory: () => discovery),
      ),
    );
    await tester.tap(find.text(original.name));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'uses unsaved connection fields, searches display names, fills exact ID and preserves name',
    (tester) async {
      await openEditor(tester);
      await tester.enterText(
        field('url'),
        'https://new.invalid/gateway/v1/messages',
      );
      await tester.enterText(field('key'), 'new-key');
      await tester.tap(find.byKey(const ValueKey('agent-model-protocol')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AgentProtocol.messages.label).last);
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-model-advanced');
      await tester.enterText(field('headers'), '{"X-Unsaved":"current"}');
      await tester.tap(find.text('完成配置'));
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-model-fetch-models');
      expect(
        discovery.connection!.baseUrl,
        'https://new.invalid/gateway/v1/messages',
      );
      expect(discovery.connection!.protocol, AgentProtocol.messages);
      expect(discovery.connection!.headers, {'X-Unsaved': 'current'});
      expect(discovery.key, 'new-key');
      expect(store.settings.models.single.model, 'old');
      await tester.enterText(
        find.byKey(const ValueKey('agent-model-list-search')),
        '模型乙',
      );
      await tester.pumpAndSettle();
      expect(find.text('模型甲'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, '模型乙'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('model')).controller!.text,
        'exact/b:latest',
      );
      expect(
        tester.widget<TextFormField>(field('name')).controller!.text,
        original.name,
      );
      expect(discovery.closed, true);
      await tester.runAsync(() async {
        await tester.tap(find.text('保存模型'));
        for (
          var i = 0;
          i < 100 && store.settings.models.single.model == 'old';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(store.settings.models.single.model, 'exact/b:latest');
      expect(store.secrets[original.id], 'new-key');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty draft can discover models, cancel without changing ID, and auto-fill a blank name',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AgentModelsPage(
            store: store,
            discoveryFactory: () => discovery,
          ),
        ),
      );
      await tapAgentSetting(tester, 'agent-add-model');
      await tapAgentSetting(tester, 'agent-model-fetch-models');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field('model')).controller!.text, '');
      discovery = RecordingDiscovery(
        () async => const [AgentProviderModel('exact-id', '显示名')],
      );
      await tapAgentSetting(tester, 'agent-model-fetch-models');
      await tester.tap(find.text('显示名'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('model')).controller!.text,
        'exact-id',
      );
      // Name may be above the viewport; field remains in the same settings group.
      expect(
        tester.widget<TextFormField>(field('name')).controller!.text,
        '显示名',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing loading dialog cancels request; late results cannot change the draft',
    (tester) async {
      final pending = Completer<List<AgentProviderModel>>();
      discovery = RecordingDiscovery(() => pending.future);
      await openEditor(tester);
      await tapAgentSetting(tester, 'agent-model-fetch-models', settle: false);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(discovery.run!.isCancelled, true);
      expect(discovery.closed, true);
      pending.complete(const [AgentProviderModel('late')]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('model')).controller!.text,
        'old',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unsupported service allows manual input and retry', (
    tester,
  ) async {
    discovery = RecordingDiscovery(
      () async => throw const AgentException(
        'MODELS_UNSUPPORTED',
        '服务商未提供 /models 接口，请手动填写模型 ID',
      ),
    );
    await openEditor(tester);
    await tapAgentSetting(tester, 'agent-model-fetch-models');
    expect(find.textContaining('请手动填写模型 ID'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.enterText(field('model'), 'manual-id');
    expect(
      tester.widget<TextFormField>(field('model')).controller!.text,
      'manual-id',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('picker fits phone with keyboard and long model IDs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    discovery = RecordingDiscovery(
      () async => [AgentProviderModel('long/' * 45, '很长的模型名称' * 10)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<AgentProviderModel>(
                context: context,
                builder: (_) => AgentModelPicker(
                  connection: original,
                  apiKey: '',
                  selectedId: '',
                  discoveryFactory: () => discovery,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-model-list-search')),
      'long',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'copy model starts an independent draft and preserves provider settings and key',
    (tester) async {
      await tester.pumpWidget(MaterialApp(home: AgentModelsPage(store: store)));
      await tester.tap(find.byTooltip('管理 ${original.name}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制模型配置'));
      await tester.pumpAndSettle();
      expect(find.text('添加模型'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('name')).controller!.text,
        '${original.name}（副本）',
      );
      expect(
        tester.widget<TextFormField>(field('key')).controller!.text,
        'old-key',
      );
      expect(store.settings.models, hasLength(1));
      await tester.enterText(field('model'), 'another-provider-model');
      await tester.runAsync(() async {
        await tester.tap(find.text('保存模型'));
        for (var i = 0; i < 100 && store.settings.models.length == 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(store.settings.models, hasLength(2));
      final copy = store.settings.models.last;
      expect(copy.id, isNot(original.id));
      expect(copy.model, 'another-provider-model');
      expect(copy.baseUrl, original.baseUrl);
      expect(store.secrets[copy.id], 'old-key');
      expect(store.settings.models.first.toJson(), original.toJson());
      expect(store.settings.defaultModel!.id, original.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
