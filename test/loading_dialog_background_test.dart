import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'support/test_translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTestTranslations);
  tearDown(() => BackgroundTasks.instance.clearFinished());

  Future<BuildContext> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    return tester.element(find.byType(Scaffold));
  }

  testWidgets(
    'minimized loading keeps progress and completes without disposed state',
    (tester) async {
      final context = await mount(tester);
      final controller = showLoadingDialog(
        context,
        message: 'Importing fixtures',
        withProgress: true,
        allowBackground: true,
        allowCancel: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('loading-dialog-continue')));
      await tester.pumpAndSettle();
      expect(controller.viewClosed, isTrue);
      expect(controller.closed, isFalse);
      expect(controller.task!.isRunning, isTrue);
      controller.setProgress(.75);
      controller.setMessage('Registering fixtures');
      expect(controller.progress, .75);
      expect(controller.message, 'Registering fixtures');
      expect(controller.task!.progress, .75);
      expect(controller.task!.message, 'Registering fixtures');
      controller.setProgress(null);
      expect(controller.task!.progress, isNull);
      controller.close();
      expect(controller.task!.status, BackgroundTaskStatus.completed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a minimized failure stays selectable and copyable in the task center',
    (tester) async {
      final context = await mount(tester);
      final controller = showLoadingDialog(
        context,
        allowBackground: true,
        message: 'Export',
      );
      await tester.pump();
      controller.minimize();
      await tester.pumpAndSettle();
      controller.fail('Comic title: disk full');
      controller.close();
      expect(controller.task!.status, BackgroundTaskStatus.failed);
      expect(controller.task!.errors, ['Comic title: disk full']);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      showBackgroundTask(context, controller.task!);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      await tester.tap(find.byKey(const Key('background-task-copy-errors')));
      await tester.pump();
      expect(copied, 'Comic title: disk full');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'early close, explicit cancellation and opt-out retain accurate states',
    (tester) async {
      final context = await mount(tester);
      final early = showLoadingDialog(context, message: 'Immediate')..close();
      await tester.pumpAndSettle();
      expect(early.task!.status, BackgroundTaskStatus.completed);
      var cancelled = 0;
      final cancellable = showLoadingDialog(
        context,
        onCancel: () => cancelled++,
      );
      await tester.pump();
      cancellable.task!.requestCancel();
      await tester.pumpAndSettle();
      expect(cancellable.task!.status, BackgroundTaskStatus.running);
      expect(cancellable.task!.cancelRequested, isTrue);
      expect(cancellable.closed, isFalse);
      expect(cancellable.viewClosed, isTrue);
      cancellable.close();
      expect(cancelled, 1);
      expect(cancellable.task!.status, BackgroundTaskStatus.cancelled);
      final count = BackgroundTasks.instance.tasks.length;
      var untrackedCancellations = 0;
      final untracked = showLoadingDialog(
        context,
        trackTask: false,
        onCancel: () => untrackedCancellations++,
      );
      expect(untracked.task, isNull);
      expect(BackgroundTasks.instance.tasks.length, count);
      await tester.pump();
      untracked.cancel();
      await tester.pumpAndSettle();
      expect(untrackedCancellations, 1);
      expect(untracked.closed, isFalse);
      untracked.close();
      await tester.pumpAndSettle();
      final detached = LoadingDialogController()..close();
      detached.setProgress(.5);
      expect(tester.takeException(), isNull);
    },
  );
}
