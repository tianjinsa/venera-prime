import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/translations.dart';

String _title(BackgroundTask task) {
  if (task.title.startsWith('Download: ')) {
    return 'Download: @name'.tlParams({'name': task.title.substring(10)});
  }
  if (task.title.startsWith('Follow Updates: ')) {
    return 'Follow Updates: @name'.tlParams({'name': task.title.substring(16)});
  }
  return task.title.tl;
}

BuildContext _navigationContext(BuildContext context) =>
    Navigator.maybeOf(context) == null ? App.rootContext : context;

String _status(BackgroundTask task) => switch (task.status) {
  BackgroundTaskStatus.running =>
    task.cancelRequested
        ? 'Cancelling'.tl
        : task.message == 'Paused'
        ? 'Paused'.tl
        : 'Running in background'.tl,
  BackgroundTaskStatus.completed => 'Finished'.tl,
  BackgroundTaskStatus.failed => 'Finished with errors'.tl,
  BackgroundTaskStatus.cancelled => 'Cancelled'.tl,
};

class TaskStatusText extends StatelessWidget {
  const TaskStatusText({super.key, required this.taskKey});
  final String taskKey;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: BackgroundTasks.instance,
    builder: (context, _) {
      final manager = BackgroundTasks.instance;
      final task = manager.latest(taskKey);
      final time = manager.lastFinished(taskKey);
      final record = manager.history[taskKey];
      final status =
          task?.status.name ?? (record is Map ? record['status'] : null);
      final lastLabel = status == 'failed'
          ? 'Last failed: @time'
          : status == 'cancelled'
          ? 'Last cancelled: @time'
          : 'Last completed: @time';
      final text = task?.isRunning == true
          ? _status(task!)
          : time == null
          ? 'Never checked'.tl
          : lastLabel.tlParams({
              'time': time.toLocal().toString().substring(0, 16),
            });
      return Text(text, style: Theme.of(context).textTheme.bodySmall);
    },
  );
}

Future<void> showBackgroundTask(
  BuildContext context,
  BackgroundTask task,
) => showDialog<void>(
  context: _navigationContext(context),
  builder: (context) => AnimatedBuilder(
    animation: task,
    builder: (context, _) => AlertDialog(
      title: Text(_title(task), maxLines: 2, overflow: TextOverflow.ellipsis),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_status(task)),
              const SizedBox(height: 12),
              if (task.isRunning) LinearProgressIndicator(value: task.progress),
              if (task.total != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${task.completed}/${task.total}'),
                ),
              if (task.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(task.message.tl),
                ),
              if (task.errors.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Errors: @count'.tlParams({'count': task.errors.length})),
                TextButton.icon(
                  key: const Key('background-task-copy-errors'),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: task.errors.join('\n\n')),
                  ),
                  icon: const Icon(Icons.copy),
                  label: Text('Copy all errors'.tl),
                ),
                for (var i = 0; i < task.errors.length; i++)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: SelectableText(task.errors[i])),
                      IconButton(
                        tooltip: 'Copy'.tl,
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: task.errors[i]),
                        ),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (task.isRunning && task.cancellable)
          TextButton(
            onPressed: task.cancelRequested ? null : task.requestCancel,
            child: Text('Cancel'.tl),
          ),
        if (!task.isRunning && task.onOpenResult != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              task.onOpenResult?.call();
            },
            child: Text((task.resultLabel ?? 'View result').tl),
          ),
        FilledButton(
          key: const Key('background-task-continue'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            task.isRunning ? 'Continue in background'.tl : 'Close'.tl,
          ),
        ),
      ],
    ),
  ),
);

Future<void> showBackgroundTasks(
  BuildContext context,
) => showModalBottomSheet<void>(
  context: _navigationContext(context),
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .8,
    child: ListenableBuilder(
      listenable: BackgroundTasks.instance,
      builder: (context, _) {
        final manager = BackgroundTasks.instance;
        final tasks = manager.tasks;
        return Column(
          children: [
            ListTile(
              title: Text('Background tasks'.tl),
              subtitle: Text('Tasks continue when you leave their pages.'.tl),
              trailing: IconButton(
                tooltip: 'Clear finished tasks'.tl,
                icon: const Icon(Icons.clear_all),
                onPressed: manager.clearFinished,
              ),
            ),
            Expanded(
              child: tasks.isEmpty
                  ? Center(child: Text('No background tasks'.tl))
                  : ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, i) {
                        final task = tasks[i];
                        final openResult =
                            task.pinned &&
                            task.status == BackgroundTaskStatus.completed &&
                            task.onOpenResult != null;
                        return ListTile(
                          leading: Icon(
                            task.isRunning
                                ? Icons.sync
                                : task.status == BackgroundTaskStatus.failed
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                          ),
                          title: Text(
                            _title(task),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                openResult
                                    ? (task.resultLabel ?? 'View result').tl
                                    : '${_status(task)}${task.total == null ? '' : '  ${task.completed}/${task.total}'}',
                              ),
                              if (task.isRunning)
                                LinearProgressIndicator(value: task.progress),
                              if (task.message.isNotEmpty)
                                Text(
                                  task.message.tl,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (task.errors.isNotEmpty)
                                Text(
                                  'Errors: @count'.tlParams({
                                    'count': task.errors.length,
                                  }),
                                ),
                            ],
                          ),
                          trailing: openResult
                              ? IconButton(
                                  tooltip: 'View task'.tl,
                                  icon: const Icon(Icons.info_outline),
                                  onPressed: () =>
                                      showBackgroundTask(context, task),
                                )
                              : null,
                          onTap: () {
                            if (openResult) {
                              Navigator.of(context).pop();
                              task.onOpenResult?.call();
                            } else {
                              showBackgroundTask(context, task);
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  ),
);

/// Root overlay: moving/changing the badge never rebuilds the app underneath.
class BackgroundTaskOverlay extends StatefulWidget {
  const BackgroundTaskOverlay({
    super.key,
    required this.child,
    this.enabled = true,
  });
  final Widget child;
  final bool enabled;
  @override
  State<BackgroundTaskOverlay> createState() => _BackgroundTaskOverlayState();
}

class _BackgroundTaskOverlayState extends State<BackgroundTaskOverlay> {
  bool _right = true;
  bool _keyboardFocus = false;
  final _badgeFocus = FocusNode(debugLabel: 'Background task badge');
  double _fraction = 1;
  Offset? _drag;
  Rect? _pendingExclusion;
  Rect? _sentExclusion;
  bool _exclusionScheduled = false;
  bool _hasSentExclusion = false;
  double _pendingPixelRatio = 1;
  static const _platform = MethodChannel('venera/method_channel');

  Future<void> _sendExclusion(Rect? rect) async {
    if (!App.isAndroid) return;
    try {
      await _platform.invokeMethod<void>('setTaskButtonGestureExclusion', {
        'rect': rect == null
            ? <int>[]
            : [
                rect.left.floor(),
                rect.top.floor(),
                rect.right.ceil(),
                rect.bottom.ceil(),
              ],
      });
    } on MissingPluginException {
      // Older hosts and widget test harnesses need no native exclusion.
    } on PlatformException {
      // Edge docking remains available on systems without this optional API.
    }
  }

  void _updateExclusion(BuildContext context, Rect? rect, double pixelRatio) {
    if (!App.isAndroid) return;
    _pendingExclusion = rect;
    _pendingPixelRatio = pixelRatio;
    if (_exclusionScheduled) return;
    _exclusionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _exclusionScheduled = false;
      if (!mounted || !context.mounted) return;
      final bounds = _pendingExclusion;
      final pixelRatio = _pendingPixelRatio;
      Rect? physical;
      final box = context.findRenderObject();
      if (bounds != null && box is RenderBox && box.attached) {
        final origin = box.localToGlobal(bounds.topLeft);
        physical = Rect.fromLTWH(
          origin.dx * pixelRatio,
          origin.dy * pixelRatio,
          bounds.width * pixelRatio,
          bounds.height * pixelRatio,
        );
      }
      if (_hasSentExclusion && physical == _sentExclusion) return;
      _hasSentExclusion = true;
      _sentExclusion = physical;
      _sendExclusion(physical);
    });
  }

  @override
  void dispose() {
    _sendExclusion(null);
    _badgeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (widget.enabled)
        const SingleActivator(LogicalKeyboardKey.f6): _badgeFocus.requestFocus,
    },
    child: LayoutBuilder(
      builder: (context, constraints) {
        const size = 44.0;
        final mq = MediaQuery.of(context);
        final minY = math.max(mq.padding.top, mq.viewPadding.top);
        final maxY = math.max(
          minY,
          constraints.maxHeight -
              math.max(
                math.max(mq.padding.bottom, mq.viewPadding.bottom),
                mq.viewInsets.bottom,
              ) -
              size,
        );
        final y = _drag?.dy ?? (minY + (maxY - minY) * _fraction);
        // Cutouts remain protected; gesture insets are not visual padding. The
        // badge has its own small Android gesture-exclusion rectangle instead.
        final minX = math.max(mq.padding.left, mq.viewPadding.left);
        final maxX = math.max(
          minX,
          constraints.maxWidth -
              math.max(mq.padding.right, mq.viewPadding.right) -
              size,
        );
        final x = _drag != null
            ? _drag!.dx.clamp(minX, maxX)
            : (_right ? maxX + 18 : minX - 18);
        _updateExclusion(
          context,
          widget.enabled
              ? Rect.fromLTWH(x, y.clamp(minY, maxY), size, size)
              : null,
          mq.devicePixelRatio,
        );
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(child: widget.child),
            if (widget.enabled)
              AnimatedPositioned(
                duration: Duration(milliseconds: _drag == null ? 180 : 0),
                left: x,
                top: y.clamp(minY, maxY),
                width: size,
                height: size,
                child: ListenableBuilder(
                  listenable: BackgroundTasks.instance.activeCountListenable,
                  builder: (context, _) {
                    final count = BackgroundTasks.instance.activeCount;
                    return FocusableActionDetector(
                      focusNode: _badgeFocus,
                      onShowFocusHighlight: (value) =>
                          setState(() => _keyboardFocus = value),
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.space):
                            ActivateIntent(),
                      },
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (_) {
                            showBackgroundTasks(context);
                            return null;
                          },
                        ),
                      },
                      child: Semantics(
                        label: 'Background tasks'.tl,
                        tooltip: '${"Background tasks".tl} (F6)',
                        button: true,
                        child: _TaskBadgeOpacity(
                          restingOpacity: _drag != null || _keyboardFocus
                              ? .95
                              : count == 0
                              ? .25
                              : .55,
                          child: Material(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            shape: CircleBorder(
                              side: _keyboardFocus
                                  ? BorderSide(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer,
                                      width: 2,
                                    )
                                  : BorderSide.none,
                            ),
                            elevation: 2,
                            child: GestureDetector(
                              key: const Key('background-task-badge'),
                              behavior: HitTestBehavior.opaque,
                              dragStartBehavior: DragStartBehavior.down,
                              onTap: () => showBackgroundTasks(context),
                              onPanStart: (_) => setState(
                                () => _drag = Offset(x.clamp(minX, maxX), y),
                              ),
                              onPanUpdate: (event) => setState(
                                () => _drag = Offset(
                                  (_drag!.dx + event.delta.dx).clamp(
                                    minX,
                                    maxX,
                                  ),
                                  (_drag!.dy + event.delta.dy).clamp(
                                    minY,
                                    maxY,
                                  ),
                                ),
                              ),
                              onPanEnd: (_) => setState(() {
                                _right =
                                    _drag!.dx + size / 2 >=
                                    constraints.maxWidth / 2;
                                final droppedY = _drag!.dy.clamp(minY, maxY);
                                // Snap near either corner, retaining free vertical
                                // placement when released along the middle edge.
                                final toTop = droppedY - minY;
                                final toBottom = maxY - droppedY;
                                _fraction = maxY == minY
                                    ? 0
                                    : math.min(toTop, toBottom) <= size
                                    ? (toTop < toBottom ? 0 : 1)
                                    : (droppedY - minY) / (maxY - minY);
                                _drag = null;
                              }),
                              onPanCancel: () => setState(() => _drag = null),
                              child: Center(
                                child: count == 0
                                    ? const Icon(Icons.work_outline, size: 18)
                                    : Text(
                                        '$count',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// Keep progress and attention animations confined to the badge subtree.
class _TaskBadgeOpacity extends StatefulWidget {
  const _TaskBadgeOpacity({required this.restingOpacity, required this.child});

  final double restingOpacity;
  final Widget child;

  @override
  State<_TaskBadgeOpacity> createState() => _TaskBadgeOpacityState();
}

class _TaskBadgeOpacityState extends State<_TaskBadgeOpacity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _disableAnimations = false;
  bool _tickerEnabled = true;

  ValueNotifier<bool> get _attention =>
      BackgroundTasks.instance.needsAttentionListenable;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _attention.addListener(_onAttentionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _updateAnimation();
  }

  void _onAttentionChanged() {
    _updateAnimation();
    setState(() {});
  }

  void _updateAnimation() {
    if (_attention.value && !_disableAnimations && _tickerEnabled) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _attention.removeListener(_onAttentionChanged);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    child: widget.child,
    builder: (context, child) => Opacity(
      key: const Key('background-task-badge-opacity'),
      opacity: !_attention.value
          ? widget.restingOpacity
          : _disableAnimations || !_tickerEnabled
          ? .85
          : .35 + .5 * Curves.easeInOut.transform(_pulse.value),
      child: child,
    ),
  );
}
