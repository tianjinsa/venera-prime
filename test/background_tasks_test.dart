import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

class _SyncProbe with ChangeNotifier implements DataSync {
  int uploads = 0;
  @override
  Future<Res<bool>> uploadData({bool force = false}) async {
    uploads++;
    return const Res(true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test('pinned results stay ahead of running tasks and survive cleanup', () {
    final tasks = BackgroundTasks();
    addTearDown(tasks.dispose);
    final ready = tasks.start('ready', 'Ready', pinned: true)..finish();
    ready.setPresentation(needsAttention: true, message: 'Install');
    final running = tasks.start('running', 'Running');
    final finished = tasks.start('finished', 'Finished')..finish();
    final pinnedRunning = tasks.start('pinned', 'Pinned', pinned: true);
    final newerRunning = tasks.start('new-running', 'New running');
    expect(tasks.tasks, [
      pinnedRunning,
      ready,
      newerRunning,
      running,
      finished,
    ]);
    expect(ready.message, 'Install');
    expect(ready.status, BackgroundTaskStatus.completed);

    for (var i = 0; i < 60; i++) {
      tasks.start('old-$i', 'Old $i').finish();
    }
    expect(tasks.tasks, contains(ready));
    expect(
      tasks.tasks.where((task) => !task.isRunning && !task.pinned),
      hasLength(50),
    );
    tasks.clearFinished();
    expect(tasks.tasks, [pinnedRunning, ready, newerRunning, running]);
    expect(tasks.needsAttentionListenable.value, isTrue);

    ready.setPresentation(pinned: false, needsAttention: false);
    tasks.clearFinished();
    expect(tasks.tasks, isNot(contains(ready)));
    expect(tasks.needsAttentionListenable.value, isFalse);
  });

  test('attention listeners only fire when aggregate attention changes', () {
    final tasks = BackgroundTasks();
    addTearDown(tasks.dispose);
    var notifications = 0;
    tasks.needsAttentionListenable.addListener(() => notifications++);
    final first = tasks.start('first', 'First', pinned: true);
    final second = tasks.start('second', 'Second');
    expect(first.needsAttention, isFalse);
    expect(second.pinned, isFalse);
    first.setPresentation(needsAttention: true);
    for (var i = 0; i < 5; i++) {
      first.update(completed: i, total: 5);
    }
    second.setPresentation(needsAttention: true);
    first.finish();
    first.setPresentation(needsAttention: false);
    expect(notifications, 1);
    second.setPresentation(needsAttention: false);
    expect(notifications, 2);
    second.setPresentation(needsAttention: false);
    expect(notifications, 2);
    second.finish();
    second.setPresentation(needsAttention: true);
    expect(notifications, 3);
    tasks.clearFinished();
    expect(notifications, 4);
  });

  test('the same running key shares one action and result future', () async {
    final tasks = BackgroundTasks();
    final gate = Completer<int>();
    var starts = 0;
    final first = tasks.run<int>('same', 'First', (_) {
      starts++;
      return gate.future;
    });
    final second = tasks.run<int>('same', 'Second', (_) async {
      starts++;
      return 99;
    });
    expect(identical(first, second), isTrue);
    expect(tasks.activeCount, 1);
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    gate.complete(42);
    expect(await first, 42);
    expect(await second, 42);
    expect(tasks.latest('same')!.status, BackgroundTaskStatus.completed);
    expect(tasks.history['same']['status'], 'completed');
    expect(await tasks.run<int>('same', 'Next', (_) async => 7), 7);
    expect(tasks.tasks, hasLength(2));
  });

  testWidgets('closing the progress view does not cancel an app-owned action', (
    tester,
  ) async {
    final tasks = BackgroundTasks();
    final gate = Completer<void>();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final result = tasks.run<void>('view', 'Working', (task) async {
      task.update(completed: 0, total: 1);
      await gate.future;
      task.update(completed: 1);
    }, cancellable: true);
    final task = tasks.latest('view')!;
    showBackgroundTask(tester.element(find.byType(Scaffold)), task);
    await tester.pump();
    await tester.tap(find.byKey(const Key('background-task-continue')));
    await tester.pumpAndSettle();
    expect(task.isRunning, isTrue);
    expect(task.cancelRequested, isFalse);
    expect(tasks.history, isEmpty);
    gate.complete();
    await tester.pump();
    await result;
    expect(task.status, BackgroundTaskStatus.completed);
    expect(task.completed, 1);
    expect(tasks.history['view']['status'], 'completed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed results are primary and close remains secondary', (
    tester,
  ) async {
    final tasks = BackgroundTasks();
    addTearDown(tasks.dispose);
    var opened = 0;
    final task = tasks.start('app-update-check', 'Check for updates')
      ..resultLabel = 'View update'
      ..onOpenResult = () {
        opened++;
      }
      ..finish();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    showBackgroundTask(tester.element(find.byType(Scaffold)), task);
    await tester.pumpAndSettle();
    final result = find.byKey(const Key('background-task-open-result'));
    final close = find.byKey(const Key('background-task-continue'));
    expect(tester.widget(result), isA<FilledButton>());
    expect(tester.widget(close), isA<TextButton>());
    expect(find.text('Finished'.tl), findsNothing);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dismiss in [false, true]) {
    testWidgets(
      'manual update result opens only while progress dialog is visible: dismiss=$dismiss',
      (tester) async {
        final tasks = BackgroundTasks();
        addTearDown(tasks.dispose);
        var opened = 0;
        final task = tasks.start('app-update-check', 'Check for updates');
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        showBackgroundTask(
          tester.element(find.byType(Scaffold)),
          task,
          openResultOnCompletion: true,
        );
        await tester.pump();
        if (dismiss) {
          await tester.tap(find.byKey(const Key('background-task-continue')));
          // Complete while the dismissed route is still animating out.
        }
        task
          ..resultLabel = 'View update'
          ..onOpenResult = () {
            opened++;
          }
          ..finish();
        await tester.pumpAndSettle();
        expect(opened, dismiss ? 0 : 1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(Scaffold), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('partial errors and thrown failures persist failed outcomes', () async {
    final tasks = BackgroundTasks();
    final partial = await tasks.run<String>('partial', 'Partial', (task) async {
      task.addError('Comic A: source unavailable');
      task.update(completed: 2, total: 2);
      return 'kept successful items';
    });
    expect(partial, 'kept successful items');
    expect(
      tasks.latest('partial')!.errors.single,
      'Comic A: source unavailable',
    );
    expect(tasks.history['partial']['status'], 'failed');
    await expectLater(
      tasks.run<void>('thrown', 'Failure', (_) async {
        throw StateError('disk full');
      }),
      throwsStateError,
    );
    expect(tasks.latest('thrown')!.errors.single, contains('disk full'));
    expect(tasks.history['thrown']['status'], 'failed');
  });

  test(
    'cancel stays running until cooperative work exits and persists cancelled once',
    () async {
      final tasks = BackgroundTasks();
      var writes = 0;
      tasks.configure(history: {}, persist: () => writes++);
      final entered = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      var cancelCallbacks = 0;
      final result = tasks.run<void>('cancel', 'Cancelable', (task) async {
        task.onCancel = () => cancelCallbacks++;
        for (var i = 0; i < 3 && !task.cancelRequested; i++) {
          requests++;
          if (i == 0) {
            entered.complete();
            await release.future;
          }
        }
      }, cancellable: true);
      await entered.future;
      final task = tasks.latest('cancel')!;
      task.requestCancel();
      task.requestCancel();
      expect(cancelCallbacks, 1);
      expect(task.status, BackgroundTaskStatus.running);
      expect(tasks.history, isEmpty);
      release.complete();
      await result;
      expect(requests, 1);
      expect(task.status, BackgroundTaskStatus.cancelled);
      expect(tasks.history['cancel']['status'], 'cancelled');
      expect(writes, 1);
      task.finish();
      task.fail('late callback');
      expect(writes, 1);
      expect(task.errors, isEmpty);
      final protected = tasks.start('protected', 'Not cancellable');
      protected.requestCancel();
      expect(protected.cancelRequested, isFalse);
      protected.finish();
      expect(tasks.history['protected']['status'], 'completed');
    },
  );

  test(
    'out-of-order completion and late callbacks preserve each key and latest generation',
    () async {
      final tasks = BackgroundTasks();
      final first = tasks.start('first', 'First');
      final second = tasks.start('second', 'Second');
      second.fail('second finished first');
      first.finish();
      expect(tasks.history['first']['status'], 'completed');
      expect(tasks.history['second']['status'], 'failed');
      expect(
        tasks.lastFinished('first')!.millisecondsSinceEpoch,
        first.finishedAt!.millisecondsSinceEpoch,
      );
      final replacement = tasks.start('first', 'Replacement');
      replacement.fail('replacement failed');
      final recorded = Map<String, dynamic>.from(tasks.history['first']);
      first.finish(message: 'late completion');
      first.fail('late failure');
      first.update(completed: 100);
      expect(tasks.latest('first'), same(replacement));
      expect(tasks.history['first'], recorded);
      final running = tasks.start('running', 'Keep running');
      tasks.clearFinished();
      expect(tasks.tasks, [running]);
      expect(tasks.history['first'], recorded);
      running.finish();
    },
  );

  test(
    'persisting cancelled task metadata writes only implicit data and never requests DataSync',
    () async {
      final root = await Directory.systemTemp.createTemp('task-persistence-');
      String? previousDataPath;
      try {
        previousDataPath = App.dataPath;
      } catch (_) {}
      final previousImplicit = appdata.implicitData;
      final previousSync = DataSync.instance;
      final dataVersion = appdata.settings['dataVersion'];
      final probe = _SyncProbe();
      DataSync.instance = probe;
      App.dataPath = root.path;
      appdata.implicitData = {};
      final tasks = BackgroundTasks();
      // This is the production persistence path used by init.dart's configure
      // callback. It intentionally avoids appdata.saveData(), which uploads.
      tasks.configure(
        history: {},
        persist: () {
          appdata.implicitData['backgroundTaskHistory'] = tasks.history;
          appdata.writeImplicitData();
        },
      );
      try {
        final task = tasks.start('cancelled', 'Cancelled', cancellable: true);
        task.requestCancel();
        task.finish();
        final file = File('${root.path}/implicitData.json');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (!await file.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final saved = jsonDecode(await file.readAsString()) as Map;
        expect(
          saved['backgroundTaskHistory']['cancelled']['status'],
          'cancelled',
        );
        expect(probe.uploads, 0);
        expect(appdata.settings['dataVersion'], dataVersion);
        expect(await File('${root.path}/appdata.json').exists(), isFalse);
        expect(await File('${root.path}/syncdata.json').exists(), isFalse);
      } finally {
        tasks.configure(history: {});
        appdata.implicitData = previousImplicit;
        DataSync.instance = previousSync;
        if (previousDataPath != null) App.dataPath = previousDataPath;
        await root.delete(recursive: true);
      }
    },
  );
}
