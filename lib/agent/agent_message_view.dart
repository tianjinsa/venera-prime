import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera/utils/app_links.dart';
import 'agent_disclosure.dart';
import 'agent_image_view.dart';
import 'agent_models.dart';

class AgentUserMessageView extends StatelessWidget {
  final AgentMessage message;
  final bool busy;
  final VoidCallback? onEdit;
  final AgentMessageImageLoader? imageLoader;
  const AgentUserMessageView({
    super.key,
    required this.message,
    required this.busy,
    this.onEdit,
    this.imageLoader,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.isFollowUp)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        message.state == 'queued' ? '补充 · 当前操作结束后处理' : '补充',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (message.images.isNotEmpty) ...[
                    AgentImageStrip(
                      images: message.images,
                      readImage: (image) => imageLoader?.call(message, image),
                    ),
                    if (message.text.isNotEmpty) const SizedBox(height: 10),
                  ],
                  if (message.text.isNotEmpty)
                    SelectableText(
                      message.text,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontSize: 16,
                        height: 1.6,
                      ),
                    ),
                ],
              ),
            ),
            AgentMessageActions(text: message.text, busy: busy, onEdit: onEdit),
          ],
        ),
      ),
    );
  }
}

class AgentMessageActions extends StatelessWidget {
  final String text;
  final bool busy;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  const AgentMessageActions({
    super.key,
    required this.text,
    required this.busy,
    this.onEdit,
    this.onRegenerate,
  });
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (text.isNotEmpty)
        _button(
          context,
          '复制',
          Icons.copy_outlined,
          () => Clipboard.setData(ClipboardData(text: text)),
        ),
      if (onEdit != null)
        _button(context, '编辑后重发', Icons.edit_outlined, busy ? null : onEdit),
      if (onRegenerate != null)
        _button(context, '重新生成', Icons.refresh, busy ? null : onRegenerate),
    ],
  );
  Widget _button(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => IconButton(
    tooltip: label,
    onPressed: action,
    icon: Icon(icon, size: 15),
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
  );
}

bool agentToolHasFailure(AgentJson part) {
  final result = part['result'];
  if (result is! Map) return part['state'] == 'failed';
  final error = result['error'];
  if (error is Map && error['code'] == 'INPUT_UPDATED') return false;
  final data = result['data'];
  final summary = data is Map ? data['summary'] : null;
  return result['ok'] == false ||
      (summary is Map && summary['failed'] is num && summary['failed'] > 0);
}

/// An ordered response slice, without a card or a repeated model heading.
class AgentMessageParts extends StatelessWidget {
  final AgentMessage message;
  final List<int> indices;
  final bool busy;
  final bool showError;
  final String? resetToken;
  final bool Function(AgentJson) canRetry;
  final void Function(AgentJson) onRetry;
  final void Function(String) onShowcase;
  final bool Function(String) hasUndo;
  final void Function(String) onUndo;
  const AgentMessageParts({
    super.key,
    required this.message,
    required this.indices,
    required this.busy,
    this.showError = true,
    this.resetToken,
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final index in indices) _part(context, message.parts[index], index),
      if (showError && message.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            message.error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ),
    ],
  );
  Widget _part(BuildContext context, AgentJson part, int index) {
    switch (part['type']) {
      case 'text':
        final text = part['text'] as String? ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _CachedMarkdown(
            key: ValueKey('${message.id}-$index'),
            text: text,
            onLink: _link,
          ),
        );
      case 'reasoning':
        final thinking =
            message.state == 'running' && index == message.parts.length - 1;
        return AgentDisclosure(
          key: ValueKey('reasoning-${message.id}-$index'),
          storageId: 'reasoning-${message.id}-$index',
          resetToken: resetToken,
          label: thinking ? '正在思考' : '思考过程',
          leading: const Icon(Icons.psychology_outlined),
          builder: (context) => _detail(
            context,
            SelectableText(
              part['text'] as String? ?? '',
              key: PageStorageKey('reasoning-text-${message.id}-$index'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 13,
                height: 1.7,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      case 'tool_call':
        return _tool(context, part, index);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _detail(BuildContext context, Widget child) => Container(
    margin: const EdgeInsets.only(left: 10, top: 2, bottom: 10),
    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: .6),
          width: 2,
        ),
      ),
    ),
    child: child,
  );
  Widget _tool(BuildContext context, AgentJson part, int index) {
    final result = part['result'] is Map ? agentObject(part['result']) : null;
    final data = result?['data'];
    final error = result?['error'];
    final running = part['state'] == 'running' || part['state'] == 'pending';
    final failed = agentToolHasFailure(part);
    final summary = data is Map ? data['summary'] : null;
    String caption = running ? '执行中' : '';
    if (summary is Map) {
      caption =
          '成功 ${summary['ok']} · 跳过 ${summary['skipped']} · 失败 ${summary['failed']}';
    } else if (error is Map) {
      caption = error['code'] == 'INPUT_UPDATED'
          ? '已跳过，按补充要求重新判断'
          : error['message']?.toString() ?? '未完成';
    } else if (data is Map && data['count'] is int) {
      caption = '已展示 ${data['count']} 本';
    }
    final showcaseId = data is Map ? data['set_id'] as String? : null;
    final undoId = data is Map ? data['undo_id'] as String? : null;
    final identity = '${message.id}-$index';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgentDisclosure(
          key: ValueKey('tool-$identity'),
          storageId: 'tool-$identity',
          resetToken: resetToken,
          label:
              agentToolLabels[part['name']] ??
              part['name']?.toString() ??
              '工具调用',
          detail: caption,
          color: failed ? Theme.of(context).colorScheme.error : null,
          leading: running
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : Icon(
                  failed
                      ? Icons.error_outline
                      : _toolIcon(part['name']?.toString() ?? ''),
                ),
          builder: (context) => _detail(
            context,
            Container(
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                key: PageStorageKey('tool-scroll-$identity'),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert({
                    'tool': part['name'],
                    'arguments': part['arguments'],
                    if (result != null) 'result': result,
                  }),
                  key: PageStorageKey('tool-text-$identity'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showcaseId != null ||
            undoId != null && hasUndo(undoId) ||
            canRetry(part))
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 4),
            child: Wrap(
              spacing: 4,
              children: [
                if (showcaseId != null)
                  TextButton.icon(
                    onPressed: () => onShowcase(showcaseId),
                    icon: const Icon(Icons.view_sidebar_outlined, size: 14),
                    label: const Text('查看漫画'),
                  ),
                if (undoId != null && hasUndo(undoId))
                  TextButton.icon(
                    onPressed: busy ? null : () => onUndo(undoId),
                    icon: const Icon(Icons.undo, size: 14),
                    label: const Text('撤销移除'),
                  ),
                if (canRetry(part))
                  TextButton.icon(
                    onPressed: busy ? null : () => onRetry(part),
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('重试工具'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _toolIcon(String name) {
    if (name.contains('search')) return Icons.search;
    if (name.startsWith('fav_')) return Icons.folder_outlined;
    if (name.startsWith('later_')) return Icons.bookmark_border;
    if (name == 'showcase_comics') return Icons.view_sidebar_outlined;
    if (name == 'list_sources') return Icons.travel_explore;
    return Icons.menu_book_outlined;
  }
}

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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A shared selection region avoids a separate scrollable EditableText for
    // every paragraph, while preserving long-press selection and link taps.
    return _body ??= SelectionArea(
      child: MarkdownBody(
        data: widget.text,
        selectable: false,
        imageBuilder: (_, _, _) => const Text('[图片已省略]'),
        onTapLink: (_, href, _) => widget.onLink(href),
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: theme.textTheme.bodyMedium?.copyWith(fontSize: 16, height: 1.7),
          blockSpacing: 14,
          code: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableCellsPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          tableBorder: TableBorder.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: .65),
            width: .6,
          ),
        ),
      ),
    );
  }
}
