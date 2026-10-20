import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_model_catalog.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_store.dart';
import 'agent_test_support.dart';

/// Serves the list a service would, without any real connection.
class _CatalogAdapter implements HttpClientAdapter {
  final requests = <String>[];
  final responses = <(int, String)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    final next = responses.isEmpty ? (404, '{}') : responses.removeAt(0);
    return ResponseBody.fromString(next.$2, next.$1);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const model = AgentModel(
    id: 'editor-test',
    name: '测试模型',
    baseUrl: 'https://example.invalid/v1',
    model: 'test-model',
  );
  const previousKey = 'stored-test-key';
  final paste = find.byKey(const ValueKey('agent-model-paste-key'));
  Finder field(String name) => find.byKey(ValueKey('agent-model-$name'));
  late Directory directory;
  late AgentStore store;
  late _CatalogAdapter adapter;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-model-editor-');
    configureAgentTestPaths(directory.path);
    store = await AgentStore.open('${directory.path}/agent');
    adapter = _CatalogAdapter();
    await store.saveSettings(
      AgentSettings(models: const [model], defaultModelId: model.id),
      {model.id: previousKey},
    );
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> openEditor(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: AgentSettingsPage(
          store: store,
          catalog: AgentModelCatalogClient(
            createDio: () => Dio()..httpClientAdapter = adapter,
          ),
        ),
      ),
    );
    await tapAgentSetting(tester, 'agent-settings-models');
    await tester.tap(find.text(model.name));
    await tester.pumpAndSettle();
  }

  TextEditingController keyController(WidgetTester tester) =>
      tester.widget<TextFormField>(field('key')).controller!;

  void mockClipboard(WidgetTester tester, FutureOr<Object?> Function() read) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return read();
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }

  const android = TargetPlatformVariant({TargetPlatform.android});

  testWidgets('leaving a changed model offers to retain or discard the draft', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(field('name'), '尚未保存的名称');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('name')).controller!.text,
      '尚未保存的名称',
    );
    expect(store.settings.models.single.name, model.name);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('模型管理'), findsOneWidget);
    expect(store.settings.models.single.name, model.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all model fields request ordinary Android text input', (
    tester,
  ) async {
    await openEditor(tester);
    Future<void> checkFields(List<String> names) async {
      for (final name in names) {
        await tester.ensureVisible(field(name));
        await tester.showKeyboard(field(name));
        await tester.pump();
        final call = tester.testTextInput.log.lastWhere(
          (call) => call.method == 'TextInput.setClient',
        );
        final configuration = (call.arguments as List)[1] as Map;
        expect(configuration['obscureText'], false, reason: name);
        expect(configuration['enableSuggestions'], true, reason: name);
        expect(configuration['autocorrect'], false, reason: name);
        expect(
          (configuration['inputType'] as Map)['name'],
          ['thinking', 'body', 'headers'].contains(name)
              ? 'TextInputType.multiline'
              : 'TextInputType.text',
          reason: name,
        );
        if (name == 'key') {
          expect(configuration['enableIMEPersonalizedLearning'], false);
        }
      }
      tester.testTextInput.hide();
      await tester.pump();
    }

    await checkFields(['name', 'url', 'model', 'key']);
    await tapAgentSetting(tester, 'agent-model-thinking-settings');
    await checkFields(['thinking', 'context']);
    await tester.tap(find.text('完成配置'));
    await tester.pumpAndSettle();
    await tapAgentSetting(tester, 'agent-model-advanced');
    await checkFields(['body', 'headers']);
    await tester.tap(find.text('完成配置'));
    await tester.pumpAndSettle();
    await tapAgentSetting(tester, 'agent-model-capabilities');
    await checkFields(['temperature', 'max_output']);
    expect(tester.takeException(), isNull);
  }, variant: android);

  testWidgets('paste API Key replaces the full value and saves it intact', (
    tester,
  ) async {
    final pastedKey = 'sk-test-${List.filled(256, 'Ab9_-.').join()}-end';
    mockClipboard(tester, () => {'text': pastedKey});
    await openEditor(tester);
    await tester.tap(paste);
    await tester.pumpAndSettle();
    expect(keyController(tester).text, pastedKey);
    expect(
      keyController(tester).selection,
      TextSelection.collapsed(offset: pastedKey.length),
    );

    await tester.ensureVisible(find.text('保存模型'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存模型'));
      for (var i = 0; i < 100 && store.secrets[model.id] != pastedKey; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(store.secrets[model.id], pastedKey);
    final persisted = await tester.runAsync(() async {
      return jsonDecode(
            await File('${store.directory.path}/secrets.json').readAsString(),
          )
          as Map;
    });
    expect(persisted![model.id], pastedKey);
    expect(find.text('模型管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: android);

  testWidgets('API Key keeps the ordinary long press paste menu', (
    tester,
  ) async {
    const pastedKey = 'pasted-through-the-text-menu';
    mockClipboard(tester, () => {'text': pastedKey});
    await openEditor(tester);
    await tester.enterText(field('key'), '');
    final editable = find.descendant(
      of: field('key'),
      matching: find.byType(EditableText),
    );
    final render = tester.state<EditableTextState>(editable).renderEditable;
    await tester.longPressAt(
      render.localToGlobal(
        render.getLocalRectForCaret(const TextPosition(offset: 0)).center,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(keyController(tester).text, pastedKey);
    expect(tester.takeException(), isNull);
  }, variant: android);

  testWidgets(
    'empty or cancelled clipboard reads preserve the existing API Key',
    (tester) async {
      Object? response;
      var cancelled = false;
      mockClipboard(tester, () {
        if (cancelled) {
          throw PlatformException(code: 'cancelled', message: 'private detail');
        }
        return response;
      });
      await openEditor(tester);
      for (final text in [null, '', ' \n ']) {
        response = text == null ? null : {'text': text};
        await tester.tap(paste);
        await tester.pumpAndSettle();
        expect(keyController(tester).text, previousKey);
        expect(tester.widget<TextButton>(paste).onPressed, isNotNull);
      }
      cancelled = true;
      await tester.tap(paste);
      await tester.pumpAndSettle();
      expect(keyController(tester).text, previousKey);
      expect(tester.widget<TextButton>(paste).onPressed, isNotNull);
      expect(find.textContaining('private detail'), findsNothing);
      expect(store.secrets[model.id], previousKey);
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );

  testWidgets(
    'a delayed paste does not overwrite a newer manual API Key edit',
    (tester) async {
      final clipboard = Completer<Object?>();
      mockClipboard(tester, () => clipboard.future);
      await openEditor(tester);
      await tester.tap(paste);
      await tester.pump();
      expect(tester.widget<TextButton>(paste).onPressed, isNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存模型'))
            .onPressed,
        isNull,
      );
      await tester.enterText(field('key'), 'new-manual-test-key');
      clipboard.complete({'text': 'stale-clipboard-test-key'});
      await tester.pumpAndSettle();
      expect(keyController(tester).text, 'new-manual-test-key');
      expect(tester.widget<TextButton>(paste).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );

  testWidgets(
    'leaving the model editor ignores a pending clipboard response',
    (tester) async {
      final clipboard = Completer<Object?>();
      mockClipboard(tester, () => clipboard.future);
      await openEditor(tester);
      await tester.tap(paste);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      clipboard.complete({'text': 'late-test-key'});
      await tester.pumpAndSettle();
      expect(find.text('模型管理'), findsOneWidget);
      expect(store.secrets[model.id], previousKey);
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );

  testWidgets(
    'the model ID can be chosen from the list the service returns',
    (tester) async {
      adapter.responses.add((
        200,
        jsonEncode({
          'data': [
            {'id': 'qwen-max'},
            {'id': 'qwen-plus'},
          ],
        }),
      ));
      await openEditor(tester);
      await tester.tap(find.byKey(const ValueKey('agent-model-list')));
      await tester.pumpAndSettle();
      expect(adapter.requests, ['https://example.invalid/v1/models']);
      expect(find.text('选择模型 ID'), findsOneWidget);
      expect(find.text('qwen-max'), findsOneWidget);
      expect(find.text('qwen-plus'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('agent-model-option-qwen-plus')),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextFormField>(field('model'))
          .controller!;
      expect(controller.text, 'qwen-plus');
      // The saved display name is kept; only an empty one follows the ID.
      final name = tester.widget<TextFormField>(field('name')).controller!;
      expect(name.text, model.name);
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );

  testWidgets(
    'the model list can be filtered and cancelled without change',
    (tester) async {
      adapter.responses.add((
        200,
        jsonEncode({
          'data': [
            {'id': 'alpha-model'},
            {'id': 'beta-model'},
          ],
        }),
      ));
      await openEditor(tester);
      await tester.tap(find.byKey(const ValueKey('agent-model-list')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-model-picker-search')),
        'beta',
      );
      await tester.pumpAndSettle();
      expect(find.text('alpha-model'), findsNothing);
      expect(find.text('beta-model'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('model')).controller!.text,
        model.model,
      );
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );

  testWidgets('a service without a model list keeps manual input usable', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(field('url'), 'https://example.invalid/v1');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-model-list')));
    // The versioned fallback is tried before reporting the support gap.
    await tester.pumpAndSettle();
    expect(adapter.requests, ['https://example.invalid/v1/models']);
    expect(find.textContaining('请手动填写模型 ID'), findsWidgets);
    await tester.enterText(field('model'), 'typed-by-hand');
    await tester.pump();
    expect(
      tester.widget<TextFormField>(field('model')).controller!.text,
      'typed-by-hand',
    );
    expect(tester.takeException(), isNull);
  }, variant: android);
}
