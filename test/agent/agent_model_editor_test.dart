import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_settings_page.dart';
import 'package:venera/agent/agent_store.dart';
import 'agent_test_support.dart';

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

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-model-editor-');
    configureAgentTestPaths(directory.path);
    store = await AgentStore.open('${directory.path}/agent');
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
    await tester.pumpWidget(MaterialApp(home: AgentSettingsPage(store: store)));
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

  testWidgets('all model fields request ordinary Android text input', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.tap(find.text('高级请求配置'));
    await tester.pumpAndSettle();

    for (final name in [
      'name',
      'url',
      'model',
      'key',
      'thinking',
      'context',
      'temperature',
      'body',
      'headers',
    ]) {
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
    expect(find.text('Agent 模型设置'), findsOneWidget);
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
      expect(find.text('Agent 模型设置'), findsOneWidget);
      expect(store.secrets[model.id], previousKey);
      expect(tester.takeException(), isNull);
    },
    variant: android,
  );
}
