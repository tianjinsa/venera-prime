import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'agent_message_view.dart';
import 'agent_models.dart';

/// A single-row entry point for future tasks, separate from chat history.
class AgentQueueStatus extends StatelessWidget {
  final AgentController controller;
  final VoidCallback onResume;
  final ValueChanged<String> onCancel;

  const AgentQueueStatus({
    super.key,
    required this.controller,
    required this.onResume,
    required this.onCancel,
  });

  void _open(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => _AgentQueuePanel(
        controller: controller,
        onResume: onResume,
        onCancel: onCancel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final pending = controller.pendingMessages;
      if (pending.isEmpty) return const SizedBox.shrink();
      return Material(
        color: Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const ValueKey('agent-queue-open'),
                onPressed: () => _open(context),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.format_list_numbered, size: 18),
                label: Text(
                  '排队 ${pending.length} 条',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _QueueRunAction(
              controller: controller,
              onResume: onResume,
              resumeKey: const ValueKey('agent-queue-resume'),
            ),
            const SizedBox(width: 4),
          ],
        ),
      );
    },
  );
}

class _QueueRunAction extends StatelessWidget {
  final AgentController controller;
  final VoidCallback onResume;
  final Key resumeKey;

  const _QueueRunAction({
    required this.controller,
    required this.onResume,
    required this.resumeKey,
  });

  @override
  Widget build(BuildContext context) => controller.busy
      ? Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '等待',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        )
      : TextButton(
          key: resumeKey,
          onPressed: () {
            if (!controller.busy && controller.pendingMessages.isNotEmpty) {
              onResume();
            }
          },
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('继续'),
        );
}

class _AgentQueuePanel extends StatefulWidget {
  final AgentController controller;
  final VoidCallback onResume;
  final ValueChanged<String> onCancel;

  const _AgentQueuePanel({
    required this.controller,
    required this.onResume,
    required this.onCancel,
  });

  @override
  State<_AgentQueuePanel> createState() => _AgentQueuePanelState();
}

class _AgentQueuePanelState extends State<_AgentQueuePanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      key: const ValueKey('agent-queue-panel'),
      height: math.min(MediaQuery.sizeOf(context).height * .6, 560),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final pending = widget.controller.pendingMessages;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '排队消息',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (pending.isNotEmpty)
                      _QueueRunAction(
                        controller: widget.controller,
                        onResume: widget.onResume,
                        resumeKey: const ValueKey('agent-queue-panel-resume'),
                      ),
                    IconButton(
                      tooltip: '关闭队列',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    widget.controller.busy
                        ? '共 ${pending.length} 条，当前任务完成后依次执行'
                        : '共 ${pending.length} 条，继续后按顺序处理',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: pending.isEmpty
                    ? const Center(child: Text('暂无排队消息'))
                    : Scrollbar(
                        controller: _scroll,
                        child: ListView.separated(
                          key: const ValueKey('agent-queue-list'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          itemCount: pending.length,
                          separatorBuilder: (_, _) => const Divider(height: 12),
                          itemBuilder: (_, index) => _QueueMessage(
                            key: ValueKey(
                              'agent-queue-item-${pending[index].id}',
                            ),
                            message: pending[index],
                            position: index + 1,
                            controller: widget.controller,
                            onCancel: widget.onCancel,
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _QueueMessage extends StatelessWidget {
  final AgentMessage message;
  final int position;
  final AgentController controller;
  final ValueChanged<String> onCancel;

  const _QueueMessage({
    super.key,
    required this.message,
    required this.position,
    required this.controller,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '第 $position 条',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            key: ValueKey('agent-queue-cancel-${message.id}'),
            tooltip: '取消第 $position 条排队消息',
            onPressed: () {
              if (controller.pendingMessages.any((m) => m.id == message.id)) {
                onCancel(message.id);
              }
            },
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
      AgentUserMessageView(
        message: message,
        busy: true,
        imageLoader: (message, image) =>
            controller.store.imageBytes(message.conversationId, image.id),
        fileLoader: (message, file) =>
            controller.store.textFileBytes(message.conversationId, file.id),
      ),
    ],
  );
}
