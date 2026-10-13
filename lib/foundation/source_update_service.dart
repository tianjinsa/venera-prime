import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/utils/translations.dart';

class SourceUpdateResult {
  const SourceUpdateResult(
    this.total,
    this.succeeded,
    this.errors,
    this.cancelled,
  );

  final int total;
  final int succeeded;
  final List<String> errors;
  final bool cancelled;
}

/// Runs independently of the page that started an update. Source installation
/// remains with the existing parser/atomic replacement implementation.
Future<SourceUpdateResult> runSourceUpdates({
  required Iterable<String> keys,
  required Future<bool> Function(String key) update,
  required void Function(String key) cancel,
  String Function(String key)? name,
  Future<void> Function(SourceUpdateResult result)? onFinished,
  BackgroundTasks? tasks,
}) {
  final registry = tasks ?? BackgroundTasks.instance;
  final pending = keys.toSet().toList();
  return registry.run('source-update-all', 'Update comic sources'.tl, (
    task,
  ) async {
    var succeeded = 0;
    String? activeKey;
    task.update(total: pending.length);
    task.onCancel = () {
      if (activeKey != null) cancel(activeKey);
    };
    try {
      for (var index = 0; index < pending.length; index++) {
        if (task.cancelRequested) break;
        final key = pending[index];
        activeKey = key;
        task.update(message: name?.call(key) ?? key);
        try {
          if (await update(key)) {
            succeeded++;
          } else if (!task.cancelRequested) {
            task.addError('$key: ${"Update was not applied".tl}');
          }
        } catch (error) {
          if (!task.cancelRequested) task.addError('$key: $error');
        }
        activeKey = null;
        task.update(completed: index + 1);
      }
    } finally {
      task.onCancel = null;
    }
    final result = SourceUpdateResult(
      pending.length,
      succeeded,
      List.unmodifiable(task.errors),
      task.cancelRequested,
    );
    task.update(message: '@n sources updated'.tlParams({'n': succeeded}));
    await onFinished?.call(result);
    return result;
  }, cancellable: true);
}
