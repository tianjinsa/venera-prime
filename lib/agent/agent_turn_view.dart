import 'package:flutter/material.dart';
import 'agent_activity_view.dart';
import 'agent_disclosure.dart';
import 'agent_image_view.dart';
import 'agent_message_view.dart';
import 'agent_models.dart';

/// Presentation grouping only: every response and supplemental input retains
/// its own ordered record in storage and in the model request.
class AgentTurnView extends StatelessWidget {
  final List<AgentMessage> messages;
  final String modelName;
  final bool running;
  final bool busy;
  final bool interrupted;
  final AgentMessageImageLoader? imageLoader;
  final VoidCallback? onRegenerate;
  final bool Function(AgentMessage, AgentJson) canRetry;
  final void Function(AgentMessage, AgentJson) onRetry;
  final void Function(String) onShowcase;
  final bool Function(String) hasUndo;
  final void Function(String) onUndo;
  const AgentTurnView({
    super.key,
    required this.messages,
    required this.modelName,
    required this.running,
    required this.busy,
    this.interrupted = false,
    this.imageLoader,
    this.onRegenerate,
    required this.canRetry,
    required this.onRetry,
    required this.onShowcase,
    required this.hasUndo,
    required this.onUndo,
  });
  bool get _complete =>
      !running &&
      !interrupted &&
      messages.last.role == 'assistant' &&
      messages.last.state == 'done' &&
      messages.last.tools.isEmpty &&
      messages.last.text.trim().isNotEmpty;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final complete = _complete;
    final last = messages.last;
    final tools = messages.expand((m) => m.tools).toList();
    final failures = tools.where(agentToolHasFailure).length;
    final status = running
        ? '正在处理'
        : complete
        ? '已完成'
        : last.state == 'interrupted'
        ? '已停止'
        : '未完成';
    final detail = [
      if (tools.isNotEmpty) '${tools.length} 项操作',
      if (failures > 0) '$failures 项未完成',
    ].join(' · ');
    final history = <Widget>[];
    final activity = <({AgentMessage message, int index})>[];
    void flushActivity() {
      if (activity.isEmpty) return;
      final items = activity.toList();
      activity.clear();
      final first = items.first;
      final parts = items.map((item) => item.message.parts[item.index]);
      final id = 'activity-${first.message.id}-${first.index}';
      history.add(
        AgentActivityView(
          key: ValueKey(id),
          storageId: id,
          resetToken: complete ? last.id : 'active',
          reasoningCount: parts.where((p) => p['type'] == 'reasoning').length,
          toolCount: parts.where((p) => p['type'] == 'tool_call').length,
          failures: parts
              .where((p) => p['type'] == 'tool_call' && agentToolHasFailure(p))
              .length,
          running:
              running &&
              items.any((item) {
                final part = item.message.parts[item.index];
                return part['type'] == 'tool_call'
                    ? part['state'] == 'running' || part['state'] == 'pending'
                    : item.message.state == 'running' &&
                          item.index == item.message.parts.length - 1;
              }),
          children: [
            for (final item in items) _parts(item.message, [item.index]),
          ],
        ),
      );
    }

    for (final message in messages) {
      if (message.role == 'user') {
        flushActivity();
        history.add(
          AgentUserMessageView(
            key: ValueKey(message.id),
            message: message,
            busy: busy,
            imageLoader: imageLoader,
          ),
        );
        continue;
      }
      for (var i = 0; i < message.parts.length; i++) {
        final part = message.parts[i];
        if (part['type'] == 'reasoning' || part['type'] == 'tool_call') {
          activity.add((message: message, index: i));
        } else if (part['type'] == 'text' &&
            (part['text'] as String? ?? '').trim().isNotEmpty) {
          flushActivity();
          if (!complete || message != last) {
            history.add(_parts(message, [i]));
          }
        }
      }
      if (message.error != null) {
        flushActivity();
        history.add(_parts(message, [], showError: true));
      }
    }
    flushActivity();
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_awesome,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Agent',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (history.isNotEmpty)
                  AgentDisclosure(
                    storageId: 'turn-${messages.first.id}',
                    label: status,
                    detail: detail,
                    initiallyExpanded: !complete,
                    resetToken: complete ? last.id : 'active',
                    color: failures > 0 ? theme.colorScheme.error : null,
                    leading: running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : Icon(
                            complete ? Icons.check_rounded : Icons.more_horiz,
                          ),
                    builder: (_) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: history,
                    ),
                  )
                else if (running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '正在思考…',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (complete)
                  _parts(last, [
                    for (var i = 0; i < last.parts.length; i++)
                      if (last.parts[i]['type'] == 'text') i,
                  ]),
                if (!running)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AgentMessageActions(
                      text: last.role == 'assistant' ? last.text : '',
                      busy: busy,
                      onRegenerate: onRegenerate,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _parts(
    AgentMessage message,
    List<int> indices, {
    bool showError = false,
  }) => AgentMessageParts(
    key: ValueKey('${message.id}-${indices.join(',')}'),
    message: message,
    indices: indices,
    busy: busy,
    showError: showError,
    resetToken: _complete ? messages.last.id : 'active',
    canRetry: (call) => canRetry(message, call),
    onRetry: (call) => onRetry(message, call),
    onShowcase: onShowcase,
    hasUndo: hasUndo,
    onUndo: onUndo,
  );
}
