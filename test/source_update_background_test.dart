import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/source_update_service.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test(
    'batch update survives caller departure and counts real failures',
    () async {
      final tasks = BackgroundTasks();
      final called = <String>[];
      final first = Completer<bool>();
      final started = Completer<void>();
      Future<bool> update(String key) async {
        called.add(key);
        if (key == 'a') {
          started.complete();
          return first.future;
        }
        if (key == 'b') throw StateError('download failed');
        return false;
      }

      final job = runSourceUpdates(
        keys: ['a', 'b', 'c'],
        update: update,
        cancel: (_) {},
        tasks: tasks,
      );
      await started.future;
      final duplicate = runSourceUpdates(
        keys: ['different'],
        update: (_) async => throw StateError('duplicate'),
        cancel: (_) {},
        tasks: tasks,
      );
      expect(identical(job, duplicate), isTrue);
      expect(tasks.activeCount, 1);
      // No widget/context is retained; completing work after the initiating
      // caller has left still processes the rest and stores its result.
      first.complete(true);
      final result = await job;
      expect(called, ['a', 'b', 'c']);
      expect(result.succeeded, 1);
      expect(result.errors, hasLength(2));
      final task = tasks.latest('source-update-all')!;
      expect(task.status, BackgroundTaskStatus.failed);
      expect(task.completed, 3);
      expect(tasks.lastFinished(task.key), isNotNull);
    },
  );

  test('cancelling signals active source and does not start another', () async {
    final tasks = BackgroundTasks();
    final started = Completer<void>();
    final first = Completer<bool>();
    final cancelled = <String>[];
    final called = <String>[];
    final job = runSourceUpdates(
      keys: ['a', 'b'],
      tasks: tasks,
      update: (key) {
        called.add(key);
        started.complete();
        return first.future;
      },
      cancel: cancelled.add,
    );
    await started.future;
    final task = tasks.latest('source-update-all')!;
    task.requestCancel();
    task.requestCancel();
    first.complete(false);
    final result = await job;
    expect(cancelled, ['a']);
    expect(called, ['a']);
    expect(result.cancelled, isTrue);
    expect(result.succeeded, 0);
    expect(task.status, BackgroundTaskStatus.cancelled);
    expect(task.onCancel, isNull);
  });
}
