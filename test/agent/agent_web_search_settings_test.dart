import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_client.dart';
import 'package:venera/agent/agent_controller.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_web_search.dart';

import 'agent_controller_test.dart' show ScriptedClient;
import 'agent_test_support.dart';
import 'agent_web_search_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const model = AgentModel(
    id: 'chat-model',
    name: '聊天模型',
    baseUrl: 'https://chat.example.org/v1',
    model: 'any-model',
  );
  late Directory root;
  late AgentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-search-settings-');
    configureAgentTestPaths(root.path);
    store = await AgentStore.open('${root.path}/agent');
    await store.saveSettings(
      const AgentSettings(models: [model], defaultModelId: 'chat-model'),
      {model.id: 'model-key'},
    );
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  test(
    'old config defaults searches off and model edits preserve all search settings',
    () async {
      final old = AgentSettings.fromJson({
        'models': [model.toJson()],
      });
      expect(old.webSearch.engines, isEmpty);
      expect(old.models.single.nativeWebSearch, false);
      final settings = old.copyWith(
        webSearch: const AgentWebSearchSettings(
          bing: true,
          google: true,
          tavily: true,
          deepseek: true,
          deepseekModel: 'chosen-search-model',
          deepseekBaseUrl: 'https://search.example.org/messages',
        ),
      );
      final changed = settings.copyWith(
        confirmPolicy: 'all',
        autoBackupLimit: 3,
        manualBackupLimit: 8,
        defaultModelId: null,
        models: const [],
      );
      await store.saveSettings(changed, {
        AgentWebSearchSettings.tavilySecretId: 'tavily-key',
        AgentWebSearchSettings.deepseekSecretId: 'deepseek-key',
      });
      final config = await File(
        '${store.directory.path}/config.json',
      ).readAsString();
      expect(config, isNot(contains('tavily-key')));
      expect(config, isNot(contains('deepseek-key')));
      store.close();
      store = await AgentStore.open('${root.path}/agent');
      expect(store.settings.webSearch.engines, AgentSearchEngine.values);
      expect(store.settings.webSearch.deepseekModel, 'chosen-search-model');
      expect(
        store.settings.webSearch.deepseekBaseUrl,
        'https://search.example.org/messages',
      );
      expect(store.secrets[model.id], 'model-key');
      expect(
        store.secrets[AgentWebSearchSettings.tavilySecretId],
        'tavily-key',
      );
      expect(
        store.secrets[AgentWebSearchSettings.deepseekSecretId],
        'deepseek-key',
      );
    },
  );

  test(
    'only enabled engines are offered and old calls cannot bypass the switches',
    () async {
      final adapter = SearchTestAdapter((_, _) => searchBody(searchRss));
      var sourceInitializations = 0;
      final tools = AgentTools(
        store,
        webSearch: AgentWebSearchClient(createDio: adapter.dio, loadPage: null),
        initializeSources: () async {
          sourceInitializations++;
        },
      );
      final conversation = store.createConversation();
      final context = AgentToolContext(conversation.id, AgentRun());
      expect(
        tools.availableSchemas.where(
          (s) => s['function']['name'] == 'search_web',
        ),
        isEmpty,
      );
      final disabled = await tools.execute('search_web', {
        'engine': 'bing',
        'query': 'Prime',
      }, context);
      expect(disabled['error']['code'], 'WEB_SEARCH_DISABLED');
      expect(adapter.requests, isEmpty);
      await store.saveSettings(
        store.settings.copyWith(
          webSearch: const AgentWebSearchSettings(bing: true),
        ),
        {},
      );
      final schema = tools.availableSchemas.singleWhere(
        (s) => s['function']['name'] == 'search_web',
      );
      expect(schema['function']['parameters']['properties']['engine']['enum'], [
        'bing',
      ]);
      final result = await tools.execute('search_web', {
        'engine': 'bing',
        'query': 'Prime',
      }, context);
      expect(result['ok'], true);
      expect(sourceInitializations, 0);
      await store.saveSettings(
        store.settings.copyWith(webSearch: const AgentWebSearchSettings()),
        {},
      );
      final retried = await tools.execute('search_web', {
        'engine': 'bing',
        'query': 'Prime',
      }, context);
      expect(retried['error']['code'], 'WEB_SEARCH_DISABLED');
      expect(adapter.requests, hasLength(1));
      expect(AgentTools.writeTools, isNot(contains('search_web')));
    },
  );

  test(
    'missing keys and invalid tool arguments give structured errors',
    () async {
      await store.saveSettings(
        store.settings.copyWith(
          webSearch: const AgentWebSearchSettings(tavily: true, deepseek: true),
        ),
        {},
      );
      final tools = AgentTools(store);
      final c = AgentToolContext(store.createConversation().id, AgentRun());
      for (final engine in ['tavily', 'deepseek']) {
        final result = await tools.execute('search_web', {
          'engine': engine,
          'query': 'Prime',
        }, c);
        expect(result['error']['code'], 'SEARCH_KEY_MISSING');
      }
      for (final args in [
        {'engine': 'unknown', 'query': 'Prime'},
        {'engine': 'deepseek', 'query': 'Prime', 'max_results': 0},
        {
          'engine': 'deepseek',
          'query': 'Prime',
          'url': 'https://arbitrary.example.org',
        },
      ]) {
        final result = await tools.execute('search_web', args, c);
        expect(result['error']['code'], 'INVALID_ARGUMENT');
      }
    },
  );

  test(
    'a non-DeepSeek chat model uses DeepSeek search without receiving its key',
    () async {
      await store.saveSettings(
        store.settings.copyWith(
          webSearch: const AgentWebSearchSettings(deepseek: true),
        ),
        {AgentWebSearchSettings.deepseekSecretId: 'separate-search-key'},
      );
      final adapter = SearchTestAdapter(
        (_, _) => searchBody(deepseekSearchReply),
      );
      var round = 0;
      final client = ScriptedClient((selected, messages, _, _) async {
        expect(selected.model, 'any-model');
        expect(jsonEncode(messages), isNot(contains('separate-search-key')));
        if (round++ == 0) {
          return const AgentResponse('', '', [
            AgentToolCall(
              'web1',
              'search_web',
              '{"engine":"deepseek","query":"Venera Prime"}',
            ),
          ]);
        }
        final result = jsonDecode(
          messages.singleWhere((m) => m['role'] == 'tool')['content'] as String,
        );
        expect(result['data']['engine'], 'deepseek');
        expect(result['data']['returned_count'], 1);
        return const AgentResponse(
          '来源：[Venera Prime](https://example.org/prime)',
          '',
          [],
        );
      });
      final controller = AgentController(
        store,
        client: client,
        tools: AgentTools(
          store,
          webSearch: AgentWebSearchClient(createDio: adapter.dio),
        ),
      );
      addTearDown(controller.dispose);
      await controller.send('搜索 Venera Prime');
      expect(controller.error, isNull);
      expect(
        adapter.requests.single.headers['x-api-key'],
        'separate-search-key',
      );
      expect((adapter.payloads.single as Map)['model'], 'deepseek-v4-flash');
      expect(
        client.toolRequests.first.any(
          (s) => s['function']['name'] == 'search_web',
        ),
        true,
      );
      expect(
        controller.messages.last.text,
        contains('https://example.org/prime'),
      );
      expect(
        jsonEncode(
          store
              .messages(controller.conversation.id)
              .map((m) => m.parts)
              .toList(),
        ),
        isNot(contains('separate-search-key')),
      );
    },
  );

  Future<void> openSettings(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(850, 2300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(MaterialApp(home: AgentSettingsPage(store: store)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    await tapAgentSetting(tester, 'agent-settings-search');
  }

  Future<void> persist(
    WidgetTester tester,
    Finder button,
    bool Function() saved,
  ) async {
    await tester.runAsync(() => tester.tap(button));
    // Dialog continuations run in the widget zone. Pump between real file I/O
    // completions so both secrets and config reach their durable state.
    for (var i = 0; i < 100 && !saved(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(saved(), true);
  }

  testWidgets(
    'separate search pages save DeepSeek configuration without changing the chat model',
    (tester) async {
      await openSettings(tester);
      for (final engine in AgentSearchEngine.values) {
        expect(
          find.byKey(ValueKey('agent-search-provider-${engine.name}')),
          findsOneWidget,
        );
      }
      await tapAgentSetting(tester, 'agent-search-provider-deepseek');
      expect(find.byKey(const ValueKey('agent-deepseek-key')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('agent-search-deepseek')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-deepseek-key')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('agent-deepseek-key')),
        'ds-ui-key',
      );
      await tester.enterText(
        find.byKey(const ValueKey('agent-deepseek-model')),
        'chosen-search-model',
      );
      await persist(
        tester,
        find.byKey(const ValueKey('agent-deepseek-save')),
        () => store.settings.webSearch.deepseek,
      );
      expect(store.settings.models.single.protocol, AgentProtocol.chat);
      expect(store.settings.webSearch.deepseekModel, 'chosen-search-model');
      expect(
        store.secrets[AgentWebSearchSettings.deepseekSecretId],
        'ds-ui-key',
      );
      expect(store.secrets[model.id], 'model-key');
      expect(store.settings.webSearch.tavily, false);
      expect(store.settings.webSearch.bing, false);
      expect(store.settings.webSearch.google, false);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-settings-models');
      await tester.tap(find.text(model.name));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-model-name')),
        '更改后的名称',
      );
      await tester.ensureVisible(find.text('保存模型'));
      await persist(
        tester,
        find.text('保存模型'),
        () => store.settings.models.single.name == '更改后的名称',
      );
      expect(store.settings.webSearch.deepseek, true);
      expect(store.settings.webSearch.deepseekModel, 'chosen-search-model');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Tavily key supports paste and disabling hides but retains its key',
    (tester) async {
      await tester.runAsync(
        () => store.saveSettings(
          store.settings.copyWith(
            webSearch: const AgentWebSearchSettings(bing: true),
          ),
          {},
        ),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': ' tvly-ui-key '};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openSettings(tester);
      await tapAgentSetting(tester, 'agent-search-provider-tavily');
      expect(
        find.byKey(const ValueKey('agent-tavily-key-input')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('agent-search-tavily')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-tavily-paste-key')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('agent-tavily-key-input')),
            )
            .controller!
            .text,
        'tvly-ui-key',
      );
      await persist(
        tester,
        find.byKey(const ValueKey('agent-tavily-save-key')),
        () => store.settings.webSearch.tavily,
      );
      expect(
        store.secrets[AgentWebSearchSettings.tavilySecretId],
        'tvly-ui-key',
      );
      expect(store.settings.webSearch.bing, true);
      await tapAgentSetting(tester, 'agent-search-provider-tavily');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-search-tavily')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-tavily-key-input')),
        findsNothing,
      );
      await persist(
        tester,
        find.byKey(const ValueKey('agent-tavily-save-key')),
        () => !store.settings.webSearch.tavily,
      );
      expect(
        store.secrets[AgentWebSearchSettings.tavilySecretId],
        'tvly-ui-key',
      );
      expect(store.settings.webSearch.bing, true);
      expect(store.secrets[model.id], 'model-key');
      expect(tester.takeException(), isNull);
    },
  );

  for (final engine in [AgentSearchEngine.tavily, AgentSearchEngine.deepseek]) {
    testWidgets('${engine.name} ignores empty and late clipboard text', (
      tester,
    ) async {
      var clipboard = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? clipboard.future : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openSettings(tester);
      await tapAgentSetting(tester, 'agent-search-provider-${engine.name}');
      await tester.tap(find.byKey(ValueKey('agent-search-${engine.name}')));
      await tester.pumpAndSettle();
      final field = find.byKey(
        ValueKey(
          engine == AgentSearchEngine.deepseek
              ? 'agent-deepseek-key'
              : 'agent-tavily-key-input',
        ),
      );
      final paste = find.byKey(ValueKey('agent-${engine.name}-paste-key'));
      await tester.enterText(field, 'old-manual-key');
      await tester.tap(paste);
      await tester.pump();
      await tester.enterText(field, 'new-manual-key');
      clipboard.complete({'text': 'stale-key'});
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'new-manual-key',
      );
      clipboard = Completer<Object?>();
      await tester.tap(paste);
      await tester.pump();
      clipboard.complete({'text': ' \n '});
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'new-manual-key',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(store.settings.webSearch.enabled(engine), false);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'native search is configured per model and preserves independent engines',
    (tester) async {
      await tester.runAsync(
        () => store.saveSettings(
          store.settings.copyWith(
            webSearch: const AgentWebSearchSettings(bing: true),
          ),
          {},
        ),
      );
      await openSettings(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-settings-models');
      await tester.tap(find.text(model.name));
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-model-capabilities');
      final toggle = find.byKey(const ValueKey('agent-model-native-search'));
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      await tester.tap(find.text('完成配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-model-protocol')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anthropic Messages').last);
      await tester.pumpAndSettle();
      await tapAgentSetting(tester, 'agent-model-capabilities');
      expect(find.textContaining('DeepSeek'), findsNothing);
      expect(find.textContaining('仅在模型服务商支持时可用'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.tap(find.text('完成配置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存模型'));
      await persist(
        tester,
        find.text('保存模型'),
        () => store.settings.models.single.nativeWebSearch,
      );
      expect(store.settings.models.single.protocol, AgentProtocol.messages);
      expect(store.settings.webSearch.bing, true);
      expect(tester.takeException(), isNull);
    },
  );
}
