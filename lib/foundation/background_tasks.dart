import 'dart:async';
import 'package:flutter/foundation.dart';

enum BackgroundTaskStatus { running, completed, failed, cancelled }

class BackgroundTask extends ChangeNotifier {
  BackgroundTask._(
    this.id,
    this.key,
    this.title,
    this.cancellable,
    this._pinned,
    this._changed,
  );
  final int id;
  final String key;
  final String title;
  final bool cancellable;
  final VoidCallback _changed;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;
  BackgroundTaskStatus status = BackgroundTaskStatus.running;
  String message = '';
  int completed = 0;
  int? total;
  final List<String> errors = [];
  bool cancelRequested = false;
  VoidCallback? onCancel;
  VoidCallback? onOpenResult;
  String? resultLabel;
  bool _pinned;
  bool _needsAttention = false;

  bool get pinned => _pinned;
  bool get needsAttention => _needsAttention;

  /// Presentation can change after work finishes, for example while a
  /// downloaded update waits for installation.
  void setPresentation({bool? pinned, bool? needsAttention, String? message}) {
    if ((pinned == null || pinned == _pinned) &&
        (needsAttention == null || needsAttention == _needsAttention) &&
        (message == null || message == this.message)) {
      return;
    }
    if (pinned != null) _pinned = pinned;
    if (needsAttention != null) _needsAttention = needsAttention;
    if (message != null) this.message = message;
    _notify();
  }

  bool get isRunning => status == BackgroundTaskStatus.running;
  double? get progress => total == null || total! <= 0
      ? null
      : (completed / total!).clamp(0.0, 1.0);

  void update({int? completed, int? total, String? message}) {
    if (!isRunning) return;
    if ((completed == null || completed == this.completed) &&
        (total == null || total == this.total) &&
        (message == null || message == this.message)) {
      return;
    }
    if (completed != null) this.completed = completed;
    if (total != null) this.total = total;
    if (message != null) this.message = message;
    _notify();
  }

  void addError(String error) {
    if (!isRunning) return;
    errors.add(error);
    _notify();
  }

  void requestCancel() {
    if (!isRunning || !cancellable || cancelRequested) return;
    cancelRequested = true;
    onCancel?.call();
    _notify();
  }

  void finish({String? message}) {
    if (!isRunning) return;
    if (message != null) this.message = message;
    status = cancelRequested
        ? BackgroundTaskStatus.cancelled
        : errors.isEmpty
        ? BackgroundTaskStatus.completed
        : BackgroundTaskStatus.failed;
    finishedAt = DateTime.now();
    onCancel = null;
    _notify();
  }

  void fail(Object error) {
    if (!isRunning) return;
    errors.add(error.toString());
    status = cancelRequested
        ? BackgroundTaskStatus.cancelled
        : BackgroundTaskStatus.failed;
    finishedAt = DateTime.now();
    onCancel = null;
    _notify();
  }

  void _notify() {
    notifyListeners();
    _changed();
  }
}

/// App-owned jobs outlive their dialogs/routes. No promise of execution after
/// the OS terminates the application is made by this in-process registry.
class BackgroundTasks extends ChangeNotifier {
  static final instance = BackgroundTasks();
  BackgroundTasks();
  final List<BackgroundTask> _tasks = [];
  final ValueNotifier<int> activeCountListenable = ValueNotifier(0);
  final ValueNotifier<bool> needsAttentionListenable = ValueNotifier(false);
  final Map<String, Future<dynamic>> _running = {};
  Map<String, dynamic> _history = {};
  VoidCallback? _persist;
  int _id = 0;

  List<BackgroundTask> get tasks => List.unmodifiable([
    ..._tasks.reversed.where((task) => task.pinned),
    ..._tasks.reversed.where((task) => !task.pinned && task.isRunning),
    ..._tasks.reversed.where((task) => !task.pinned && !task.isRunning),
  ]);
  int get activeCount => _tasks.where((t) => t.isRunning).length;
  Map<String, dynamic> get history => _history;

  void configure({
    required Map<String, dynamic> history,
    VoidCallback? persist,
  }) {
    _history = history;
    _persist = persist;
  }

  BackgroundTask? latest(String key) {
    for (final task in _tasks.reversed) {
      if (task.key == key) return task;
    }
    return null;
  }

  DateTime? lastFinished(String key) {
    final record = _history[key];
    final value = record is Map ? record['finishedAt'] : null;
    return value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }

  BackgroundTask start(
    String key,
    String title, {
    bool cancellable = false,
    bool pinned = false,
  }) {
    final previous = latest(key);
    if (previous != null && previous.isRunning) return previous;
    late final BackgroundTask task;
    var recorded = false;
    task = BackgroundTask._(++_id, key, title, cancellable, pinned, () {
      if (!task.isRunning && !recorded) {
        recorded = true;
        if (!key.startsWith('loading-dialog:') &&
            !key.startsWith('local-delete:')) {
          _history[key] = {
            'finishedAt': task.finishedAt!.millisecondsSinceEpoch,
            'status': task.status.name,
          };
        }
        if (_history.length > 200) {
          final keys = _history.keys.toList()
            ..sort((a, b) {
              int time(String k) {
                final record = _history[k];
                return record is Map && record['finishedAt'] is int
                    ? record['finishedAt'] as int
                    : 0;
              }

              return time(a).compareTo(time(b));
            });
          for (final old in keys.take(_history.length - 200)) {
            _history.remove(old);
          }
        }
        _persist?.call();
      }
      _prune();
      _notifyState();
    });
    _tasks.add(task);
    _prune();
    _notifyState();
    return task;
  }

  Future<T> run<T>(
    String key,
    String title,
    Future<T> Function(BackgroundTask task) action, {
    bool cancellable = false,
  }) {
    final existing = _running[key];
    if (existing != null) return existing as Future<T>;
    final task = start(key, title, cancellable: cancellable);
    final completer = Completer<T>();
    _running[key] = completer.future;
    Future<void>(() async {
      try {
        final result = await action(task);
        task.finish();
        completer.complete(result);
      } catch (error, stack) {
        task.fail(error);
        completer.completeError(error, stack);
      } finally {
        if (identical(_running[key], completer.future)) _running.remove(key);
      }
    });
    return completer.future;
  }

  void _prune() {
    while (_tasks.where((t) => !t.isRunning && !t.pinned).length > 50) {
      _tasks.removeAt(_tasks.indexWhere((t) => !t.isRunning && !t.pinned));
    }
  }

  void clearFinished() {
    _tasks.removeWhere((t) => !t.isRunning && !t.pinned);
    _notifyState();
  }

  void _notifyState() {
    activeCountListenable.value = activeCount;
    needsAttentionListenable.value = _tasks.any((task) => task.needsAttention);
    notifyListeners();
  }

  @override
  void dispose() {
    activeCountListenable.dispose();
    needsAttentionListenable.dispose();
    super.dispose();
  }
}
