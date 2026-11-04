import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';

import 'support/test_translations.dart';

class _PreservedChild extends StatefulWidget {
  const _PreservedChild(this.onInit);
  final VoidCallback onInit;
  @override
  State<_PreservedChild> createState() => _PreservedChildState();
}

class _PreservedChildState extends State<_PreservedChild> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Private content'));
}

void main() {
  setUpAll(ensureTestTranslations);
  setUp(() {
    for (final task in BackgroundTasks.instance.tasks) {
      task.setPresentation(pinned: false, needsAttention: false);
      task.finish();
    }
    BackgroundTasks.instance.clearFinished();
    BackgroundTasks.instance.configure(history: {});
  });

  testWidgets('empty task counts are hidden in the panel and details', (
    tester,
  ) async {
    BackgroundTasks.instance.start('empty-check', 'Empty check')
      ..update(completed: 0, total: 0)
      ..finish(message: 'No comics to check');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => BackgroundTaskOverlay(child: child!),
        home: const Scaffold(),
      ),
    );
    await tester.tap(find.byKey(const Key('background-task-badge')));
    await tester.pumpAndSettle();
    expect(find.text('No comics to check'), findsOneWidget);
    expect(find.textContaining('0/0'), findsNothing);
    await tester.tap(find.text('Empty check'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('0/0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('repeated badge activation opens only one task panel', (
    tester,
  ) async {
    final task = BackgroundTasks.instance.start('panel-reentry', 'Panel task')
      ..finish();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => BackgroundTaskOverlay(child: child!),
        home: const Scaffold(),
      ),
    );
    await tester.pumpAndSettle();
    final badge = find.byKey(const Key('background-task-badge'));
    final panels = find.byType(BottomSheet, skipOffstage: false);

    await tester.tap(badge);
    await tester.tap(badge);
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(panels, findsOneWidget);

    await tester.tap(badge);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(panels, findsOneWidget);

    await tester.tap(find.text(task.title));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(panels, findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(panels, findsNothing);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);

    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(panels, findsOneWidget);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(panels, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('badge supports F6 focus and Enter or Space activation', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: child,
          builder: (context, enabled, child) =>
              BackgroundTaskOverlay(enabled: enabled, child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    await tester.pumpAndSettle();
    final badge = find.byKey(const Key('background-task-badge'));
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(badge)).hasFocus, isTrue);
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const Key('background-task-badge-opacity')),
          )
          .opacity,
      .95,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('No background tasks'), findsOneWidget);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    Focus.of(tester.element(badge)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('No background tasks'), findsOneWidget);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(badge, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('No background tasks'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('attention breathes only while visible and preserves app state', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    var inits = 0;
    final task = BackgroundTasks.instance.start(
      'ready-pulse',
      'Ready',
      pinned: true,
    )..finish();
    final running = BackgroundTasks.instance.start('active-pulse', 'Working');
    final opacity = find.byKey(const Key('background-task-badge-opacity'));
    double value() => tester.widget<Opacity>(opacity).opacity;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: child,
          builder: (context, enabled, child) =>
              BackgroundTaskOverlay(enabled: enabled, child: child!),
        ),
        home: _PreservedChild(() => inits++),
      ),
    );
    await tester.pumpAndSettle();
    expect(value(), .55);
    task.setPresentation(needsAttention: true);
    await tester.pump();
    final first = value();
    await tester.pump(const Duration(milliseconds: 600));
    expect(value(), greaterThan(first));
    expect(value(), inInclusiveRange(.35, .85));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    visible.value = false;
    await tester.pumpAndSettle();
    expect(opacity, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(running.isRunning, isTrue);
    expect(running.cancelRequested, isFalse);
    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    expect(inits, 1);

    task.setPresentation(needsAttention: false);
    await tester.pumpAndSettle();
    expect(value(), .55);
    expect(tester.binding.transientCallbackCount, 0);
    running.finish();
    await tester.pumpAndSettle();
    expect(value(), .25);
    task.setPresentation(needsAttention: true);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion uses a static attention highlight', (
    tester,
  ) async {
    final task = BackgroundTasks.instance.start(
      'static-ready',
      'Ready',
      pinned: true,
    )..finish();
    task.setPresentation(needsAttention: true);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: BackgroundTaskOverlay(child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const Key('background-task-badge-opacity')),
          )
          .opacity,
      .85,
    );
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ready task opens installation directly while normal tasks show details',
    (tester) async {
      var installs = 0;
      final task =
          BackgroundTasks.instance.start(
              'ready-open',
              'Update ready',
              pinned: true,
            )
            ..onOpenResult = () {
              installs++;
            }
            ..resultLabel = 'Install'
            ..finish();
      task.setPresentation(needsAttention: true);
      final running = BackgroundTasks.instance.start(
        'ordinary-open',
        'Ordinary job',
      );
      running.update(completed: 0, total: 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showBackgroundTasks(context),
                child: const Text('Open tasks'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open tasks'));
      await tester.pumpAndSettle();
      expect(find.text('Install'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Update ready')).dy,
        lessThan(tester.getTopLeft(find.text('Ordinary job')).dy),
      );
      await tester.tap(find.text('Update ready'));
      await tester.pumpAndSettle();
      expect(installs, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Install'), findsNothing);

      await tester.tap(find.text('Open tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ordinary job'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(installs, 1);
      await tester.tap(find.byKey(const Key('background-task-continue')));
      await tester.pumpAndSettle();
      expect(running.isRunning, isTrue);
      expect(running.cancelRequested, isFalse);
      running.finish();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'root builder badge opens center and does not replace content when hidden',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      var inits = 0;
      final task = BackgroundTasks.instance.start(
        'test-active',
        'Test operation',
      );
      task.update(completed: 1, total: 10);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: visible,
            child: child,
            builder: (context, enabled, child) =>
                BackgroundTaskOverlay(enabled: enabled, child: child!),
          ),
          home: _PreservedChild(() => inits++),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-task-badge')));
      await tester.pumpAndSettle();
      expect(find.text('Test operation'), findsOneWidget);
      expect(tester.takeException(), isNull);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      visible.value = false;
      await tester.pump();
      expect(find.byKey(const Key('background-task-badge')), findsNothing);
      visible.value = true;
      await tester.pump();
      expect(inits, 1);
      task.finish();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('badge docks within safe edges and survives resize during drag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(left: 64, right: 20)),
          child: BackgroundTaskOverlay(child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    final badge = find.byKey(const Key('background-task-badge'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await gesture.moveTo(const Offset(70, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getCenter(badge).dx, greaterThanOrEqualTo(64));
    final drag = await tester.startGesture(tester.getCenter(badge));
    await drag.moveTo(const Offset(700, 160));
    await tester.pump();
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(tester.getCenter(badge).dx, lessThan(360));
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'badge stays fully visible at both safe corners without gesture-inset gaps',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 24, bottom: 32),
              viewPadding: const EdgeInsets.only(top: 24, bottom: 32),
              systemGestureInsets: const EdgeInsets.only(
                left: 32,
                right: 32,
                bottom: 32,
              ),
            ),
            child: BackgroundTaskOverlay(child: child!),
          ),
          home: const Scaffold(),
        ),
      );
      final badge = find.byKey(const Key('background-task-badge'));
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).bottom, 768);
      expect(tester.getRect(badge).right, 400);
      expect(tester.getCenter(badge).dx, lessThan(400));
      final toTop = await tester.startGesture(tester.getCenter(badge));
      await toTop.moveTo(const Offset(40, 60));
      await tester.pump();
      await toTop.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).top, 24);
      expect(tester.getRect(badge).left, 0);
      final toBottom = await tester.startGesture(tester.getCenter(badge));
      await toBottom.moveTo(const Offset(360, 738));
      await tester.pump();
      await toBottom.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).bottom, 768);
      expect(tester.getRect(badge).right, 400);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed outcomes remain selectable and copyable in small dialogs',
    (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'];
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
      final task = BackgroundTasks.instance.start(
        'test-failed',
        'Long comic title ' * 20,
      );
      task.addError('日本語の作品名\nHTTP 503');
      task.finish();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const TaskStatusText(taskKey: 'test-failed'),
                  TextButton(
                    onPressed: () => showBackgroundTask(context, task),
                    child: const Text('Open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Last failed:'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const Key('background-task-copy-errors')),
      );
      await tester.tap(find.byKey(const Key('background-task-copy-errors')));
      await tester.pump();
      expect(copied, task.errors.single);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
