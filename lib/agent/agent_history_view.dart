import 'package:flutter/material.dart';
import 'agent_models.dart';

class AgentHistoryPanel extends StatefulWidget {
  final List<AgentConversation> conversations;
  final String currentId;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback onNew;
  final VoidCallback? close;
  final ValueChanged<AgentConversation> onSelect;
  final ValueChanged<AgentConversation> onRename;
  final Future<bool> Function(List<AgentConversation>) onDelete;
  const AgentHistoryPanel({
    super.key,
    required this.conversations,
    required this.currentId,
    required this.search,
    required this.onSearch,
    required this.onNew,
    this.close,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<AgentHistoryPanel> createState() => _AgentHistoryPanelState();
}

class _AgentHistoryPanelState extends State<AgentHistoryPanel> {
  bool _selecting = false;
  bool _deleting = false;
  final _selected = <String>{};

  @override
  void didUpdateWidget(covariant AgentHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = widget.conversations.map((c) => c.id).toSet();
    _selected.removeWhere((id) => !visible.contains(id));
  }

  void _toggle(AgentConversation conversation) {
    if (_deleting) return;
    setState(() {
      _selecting = true;
      if (!_selected.add(conversation.id)) _selected.remove(conversation.id);
    });
  }

  Future<void> _delete() async {
    final selected = widget.conversations
        .where((c) => _selected.contains(c.id))
        .toList();
    if (selected.isEmpty || _deleting) return;
    setState(() => _deleting = true);
    try {
      if (await widget.onDelete(selected) && mounted) {
        setState(() {
          _selected.clear();
          _selecting = false;
        });
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all =
        widget.conversations.isNotEmpty &&
        _selected.length == widget.conversations.length;
    final selectedBytes = widget.conversations
        .where((c) => _selected.contains(c.id))
        .fold<int>(0, (total, c) => total + c.storageBytes);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _selecting ? '已选 ${_selected.length} 段' : '历史对话',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const ValueKey('agent-history-manage'),
                tooltip: _selecting ? '退出多选' : '管理对话',
                onPressed: _deleting
                    ? null
                    : () => setState(() {
                        _selecting = !_selecting;
                        _selected.clear();
                      }),
                icon: Icon(
                  _selecting ? Icons.close : Icons.checklist_rounded,
                  size: 20,
                ),
              ),
              if (!_selecting)
                IconButton(
                  tooltip: widget.close == null ? '新对话' : '关闭',
                  onPressed: widget.close ?? widget.onNew,
                  icon: Icon(
                    widget.close == null ? Icons.add : Icons.close,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
            controller: widget.search,
            onChanged: widget.onSearch,
            enabled: !_deleting,
            decoration: const InputDecoration(
              hintText: '搜索对话',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_selecting)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                Text(
                  '所选内容约 ${agentFormatBytes(selectedBytes)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      key: const ValueKey('agent-history-select-all'),
                      onPressed: _deleting || widget.conversations.isEmpty
                          ? null
                          : () => setState(() {
                              _selected.clear();
                              if (!all) {
                                _selected.addAll(
                                  widget.conversations.map((c) => c.id),
                                );
                              }
                            }),
                      child: Text(all ? '取消全选' : '全选结果'),
                    ),
                    TextButton.icon(
                      key: const ValueKey('agent-history-delete-selected'),
                      onPressed: _selected.isEmpty || _deleting
                          ? null
                          : _delete,
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(_deleting ? '删除中' : '删除所选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: widget.conversations.isEmpty
              ? const Center(child: Text('没有匹配的对话'))
              : ListView.builder(
                  itemCount: widget.conversations.length,
                  itemBuilder: (_, index) {
                    final conversation = widget.conversations[index];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      conversation.updatedAt,
                    );
                    return ListTile(
                      key: ValueKey('history-${conversation.id}'),
                      contentPadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                      horizontalTitleGap: 6,
                      minLeadingWidth: 24,
                      selected: _selecting
                          ? _selected.contains(conversation.id)
                          : conversation.id == widget.currentId,
                      leading: _selecting
                          ? Checkbox(
                              value: _selected.contains(conversation.id),
                              visualDensity: VisualDensity.compact,
                              onChanged: _deleting
                                  ? null
                                  : (_) => _toggle(conversation),
                            )
                          : null,
                      title: Text(
                        conversation.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${date.month}/${date.day} · ${conversation.messageCount} 条消息',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '约 ${agentFormatBytes(conversation.storageBytes)}',
                            key: ValueKey('history-size-${conversation.id}'),
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      onTap: _deleting
                          ? null
                          : () => _selecting
                                ? _toggle(conversation)
                                : widget.onSelect(conversation),
                      onLongPress: _deleting
                          ? null
                          : () => _toggle(conversation),
                      trailing: _selecting
                          ? null
                          : SizedBox(
                              width: 32,
                              child: PopupMenuButton<String>(
                                tooltip: '对话选项',
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.more_horiz, size: 18),
                                onSelected: (action) {
                                  if (action == 'delete') {
                                    widget.onDelete([conversation]);
                                  } else if (action == 'select') {
                                    _toggle(conversation);
                                  } else {
                                    widget.onRename(conversation);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重命名'),
                                  ),
                                  PopupMenuItem(
                                    value: 'select',
                                    child: Text('选择对话'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
