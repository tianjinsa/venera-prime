import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera/utils/app_links.dart';
import 'agent_models.dart';

class AgentMessageView extends StatelessWidget {
  final AgentMessage message;
  final String modelName;
  final int? stepNumber;
  final bool busy;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final bool Function(AgentJson) canRetry;
  final void Function(AgentJson) onRetry;
  final void Function(String) onShowcase;
  final bool Function(String) hasUndo;
  final void Function(String) onUndo;
  const AgentMessageView({
    super.key,
    required this.message,
    required this.modelName,
    this.stepNumber,
    required this.busy,
    this.onEdit,
    this.onRegenerate,
    required this.canRetry,
    required this.onRetry,
    required this.onShowcase,
    required this.hasUndo,
    required this.onUndo,
  });

  Future<void> _link(String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) return;
    if (!await handleAppLink(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: user
                  ? scheme.primaryContainer.withValues(alpha: .5)
                  : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        user ? Icons.person_outline : Icons.auto_awesome,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          user
                              ? '你'
                              : stepNumber == null
                              ? modelName
                              : '$modelName · 第 $stepNumber 步',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      if (message.text.isNotEmpty)
                        IconButton(
                          tooltip: '复制',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: message.text),
                          ),
                          icon: const Icon(Icons.copy_outlined, size: 16),
                        ),
                      if (onEdit != null)
                        IconButton(
                          tooltip: '编辑后重发',
                          visualDensity: VisualDensity.compact,
                          onPressed: busy ? null : onEdit,
                          icon: const Icon(Icons.edit_outlined, size: 16),
                        ),
                      if (onRegenerate != null)
                        IconButton(
                          tooltip: '重新生成',
                          visualDensity: VisualDensity.compact,
                          onPressed: busy ? null : onRegenerate,
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                    ],
                  ),
                  for (var i = 0; i < message.parts.length; i++)
                    _part(context, message.parts[i], i),
                  if (message.parts.isEmpty && message.state == 'running')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('正在思考…'),
                    ),
                  if (message.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        message.error!,
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _part(BuildContext context, AgentJson part, int index) {
    switch (part['type']) {
      case 'text':
        final text = part['text'] as String? ?? '';
        if (message.role == 'user') return SelectableText(text);
        return _CachedMarkdown(
          key: ValueKey('${message.id}-$index'),
          text: text,
          onLink: _link,
        );
      case 'reasoning':
        return ExpansionTile(
          key: PageStorageKey('reasoning-${message.id}-$index'),
          tilePadding: EdgeInsets.zero,
          title: const Text('思考内容', style: TextStyle(fontSize: 13)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SelectableText(
                  part['text'] as String? ?? '',
                  // Keep text scrolling separate from the tile's bool state.
                  key: PageStorageKey('reasoning-text-${message.id}-$index'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        );
      case 'tool_call':
        return _tool(context, part);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _tool(BuildContext context, AgentJson part) {
    final result = part['result'] is Map ? agentObject(part['result']) : null;
    final data = result?['data'];
    final error = result?['error'];
    final state = part['state'];
    final running = state == 'running' || state == 'pending';
    final failed = result?['ok'] == false;
    final summary = data is Map ? data['summary'] : null;
    String caption = running
        ? '执行中…'
        : failed
        ? '未完成'
        : '已完成';
    if (summary is Map) {
      caption =
          '成功 ${summary['ok']} · 跳过 ${summary['skipped']} · 失败 ${summary['failed']}';
    } else if (error is Map) {
      caption = error['message']?.toString() ?? caption;
    } else if (data is Map && data['count'] is int) {
      caption = '已展示 ${data['count']} 本';
    }
    final showcaseId = data is Map ? data['set_id'] as String? : null;
    final undoId = data is Map ? data['undo_id'] as String? : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            key: PageStorageKey('tool-${part['id']}'),
            leading: running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    failed ? Icons.error_outline : Icons.check_circle_outline,
                    color: failed ? Theme.of(context).colorScheme.error : null,
                    size: 20,
                  ),
            title: Text(
              agentToolLabels[part['name']] ?? part['name']?.toString() ?? '工具',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(caption, style: const TextStyle(fontSize: 12)),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: SingleChildScrollView(
                    key: PageStorageKey('tool-scroll-${part['id']}'),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert({
                        'tool': part['name'],
                        'arguments': part['arguments'],
                        if (result != null) 'result': result,
                      }),
                      key: PageStorageKey('tool-text-${part['id']}'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (showcaseId != null || undoId != null || canRetry(part))
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Wrap(
                spacing: 4,
                children: [
                  if (showcaseId != null)
                    TextButton.icon(
                      onPressed: () => onShowcase(showcaseId),
                      icon: const Icon(Icons.view_sidebar_outlined, size: 16),
                      label: const Text('查看漫画'),
                    ),
                  if (undoId != null && hasUndo(undoId))
                    TextButton.icon(
                      onPressed: busy ? null : () => onUndo(undoId),
                      icon: const Icon(Icons.undo, size: 16),
                      label: const Text('撤销移除'),
                    ),
                  if (canRetry(part))
                    TextButton.icon(
                      onPressed: busy ? null : () => onRetry(part),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试工具'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A parent stream tick does not reparse unchanged, completed messages.
class _CachedMarkdown extends StatefulWidget {
  final String text;
  final Future<void> Function(String?) onLink;
  const _CachedMarkdown({super.key, required this.text, required this.onLink});
  @override
  State<_CachedMarkdown> createState() => _CachedMarkdownState();
}

class _CachedMarkdownState extends State<_CachedMarkdown> {
  Widget? _body;
  @override
  void didUpdateWidget(covariant _CachedMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _body = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _body = null;
  }

  @override
  Widget build(BuildContext context) => _body ??= MarkdownBody(
    data: widget.text,
    selectable: true,
    imageBuilder: (_, _, _) => const Text('[图片已省略]'),
    onTapLink: (_, href, _) => widget.onLink(href),
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      tableColumnWidth: const IntrinsicColumnWidth(),
    ),
  );
}
