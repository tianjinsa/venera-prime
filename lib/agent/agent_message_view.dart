import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera/utils/app_links.dart';
import 'agent_attachment_view.dart';
import 'agent_disclosure.dart';
import 'agent_image_view.dart';
import 'agent_models.dart';
import 'agent_text_view.dart';

class AgentUserMessageView extends StatelessWidget {
  final AgentMessage message;
  final bool busy;
  final VoidCallback? onEdit;
  final AgentMessageImageLoader? imageLoader;
  final AgentMessageTextFileLoader? fileLoader;
  const AgentUserMessageView({
    super.key,
    required this.message,
    required this.busy,
    this.onEdit,
    this.imageLoader,
    this.fileLoader,
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
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
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
                  if (message.images.isNotEmpty ||
                      message.files.isNotEmpty) ...[
                    AgentAttachmentStrip(
                      images: message.images,
                      files: message.files,
                      readImage: (image) => imageLoader?.call(message, image),
                      readFile: (file) => fileLoader?.call(message, file),
                    ),
                    if (message.text.isNotEmpty) const SizedBox(height: 10),
                  ],
                  if (message.text.isNotEmpty)
                    AgentSelectableText(
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
            AgentSelectableText(
              part['text'] as String? ?? '',
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
    final running = part['state'] == 'running' || part['state'] == 'pending';
    final failed = agentToolHasFailure(part);
    final caption = agentToolCaption(part);
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
            AgentToolDetail(
              key: PageStorageKey('tool-detail-$identity'),
              part: part,
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
    if (name.startsWith('net_fav_')) return Icons.cloud_outlined;
    if (name.startsWith('history_')) return Icons.history;
    if (name.startsWith('download_')) return Icons.download_outlined;
    if (name.startsWith('local_')) return Icons.folder_zip_outlined;
    if (name.startsWith('updates_')) return Icons.update;
    if (name.startsWith('open_')) return Icons.open_in_new;
    if (name.startsWith('blocked_')) return Icons.block;
    if (name.startsWith('source_') || name == 'list_sources') {
      return Icons.travel_explore;
    }
    if (name == 'explore_load' ||
        name == 'category_comics' ||
        name == 'ranking_comics') {
      return Icons.explore_outlined;
    }
    if (name == 'comic_comments') return Icons.forum_outlined;
    if (name == 'reading_stats') return Icons.bar_chart;
    if (name == 'showcase_comics') return Icons.view_sidebar_outlined;
    return Icons.menu_book_outlined;
  }
}

/// A short result line: what was done and how far it succeeded.
String agentToolCaption(AgentJson part) {
  final state = part['state'];
  if (state == 'running' || state == 'pending') return '执行中';
  final result = part['result'];
  if (result is! Map) return '';
  final error = result['error'];
  if (error is Map) {
    return error['code'] == 'INPUT_UPDATED'
        ? '已跳过，按补充要求重新判断'
        : error['message']?.toString() ?? '未完成';
  }
  final data = result['data'];
  if (data is! Map) return data is List ? '${data.length} 项' : '';
  String pages(Object? page, Object? total) =>
      page is int && total is int && total > 0
      ? '第 $page/$total 页'
      : page is int
      ? '第 $page 页'
      : '';
  String join(List<String> values) =>
      values.where((v) => v.isNotEmpty).join(' · ');
  final summary = data['summary'];
  if (summary is Map) {
    final unit = part['name'] == 'search_all' ? '个源' : '';
    return join([
      '成功 ${summary['ok']}$unit',
      if (summary['skipped'] != 0) '跳过 ${summary['skipped']}',
      if (summary['failed'] != 0) '失败 ${summary['failed']}',
    ]);
  }
  switch (part['name']) {
    case 'showcase_comics':
      return '已展示 ${data['count']} 本';
    case 'comic_get' || 'comic_open_by_id':
      final chapters = data['chapters'];
      return join([
        if (data['title'] is String) '《${data['title']}》',
        if (chapters is Map &&
            chapters['count'] is int &&
            chapters['count'] > 0)
          '${chapters['count']} 章',
      ]);
    case 'comic_chapters':
      return join([
        pages(data['page'], data['total_pages']),
        '共 ${data['count']} 章',
      ]);
    case 'comic_comments':
      return join([
        pages(data['page'], data['max_page']),
        '${data['count']} 条评论',
      ]);
    case 'open_comic' || 'open_page':
      return '已打开';
    case 'reading_stats':
      final seconds = data['total_seconds'];
      return seconds is int
          ? '近 ${data['days']} 天 ${(seconds / 60).round()} 分钟'
          : '';
  }
  if (data['parts'] is List) return '${(data['parts'] as List).length} 个分区';
  if (data['results'] is List) return '${(data['results'] as List).length} 项';
  // Paged local lists.
  if (data['total'] is int) {
    return join([
      pages(data['page'], data['total_pages']),
      '共 ${data['total']} 条',
    ]);
  }
  // Pages from a source.
  if (data['style'] != null || data['sections'] is List) {
    final count = data['count'] ?? (data['sections'] as List?)?.length;
    return join([
      pages(data['page'], data['max_page']),
      if (count is int) '$count 项',
      if (data['has_more'] == true && data['max_page'] == null) '还有更多',
      if (data['from_cache'] == true) '缓存',
    ]);
  }
  final candidates = data['candidates'];
  if (candidates is List) return '${candidates.length} 个候选';
  return '';
}

class _CachedMarkdown extends StatelessWidget {
  final String text;
  final Future<void> Function(String?) onLink;
  const _CachedMarkdown({super.key, required this.text, required this.onLink});

  @override
  Widget build(BuildContext context) {
    final chunks = agentMarkdownChunks(text);
    // A shared selection region avoids a separate scrollable EditableText for
    // every paragraph, while preserving long-press selection and link taps.
    // Long responses are parsed in stable chunks: while streaming, only the
    // last chunk changes and is parsed again.
    return SelectionArea(
      child: chunks.length == 1
          ? _MarkdownChunk(text: text, onLink: onLink)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < chunks.length; i++)
                  Padding(
                    key: ValueKey(i),
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
                    child: _MarkdownChunk(text: chunks[i], onLink: onLink),
                  ),
              ],
            ),
    );
  }
}

class _MarkdownChunk extends StatefulWidget {
  final String text;
  final Future<void> Function(String?) onLink;
  const _MarkdownChunk({required this.text, required this.onLink});
  @override
  State<_MarkdownChunk> createState() => _MarkdownChunkState();
}

class _MarkdownChunkState extends State<_MarkdownChunk> {
  Widget? _body;
  @override
  void didUpdateWidget(covariant _MarkdownChunk oldWidget) {
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
    // Returning the same widget lets an unchanged chunk skip its subtree.
    return _body ??= MarkdownBody(
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
    );
  }
}

/// Tool arguments and receipt. The JSON text is encoded once per receipt, and
/// a large receipt is laid out lazily inside its bounded viewport.
class AgentToolDetail extends StatelessWidget {
  final AgentJson part;
  const AgentToolDetail({super.key, required this.part});

  static final _cache = Expando<(Object?, Object?, String)>();
  static const _lazyChunks = 3;

  static String _json(AgentJson part) {
    final cached = _cache[part];
    final result = part['result'];
    if (cached != null &&
        identical(cached.$1, part['arguments']) &&
        identical(cached.$2, result)) {
      return cached.$3;
    }
    final text = const JsonEncoder.withIndent('  ').convert({
      'tool': part['name'],
      'arguments': part['arguments'],
      if (result is Map) 'result': result,
    });
    _cache[part] = (part['arguments'], result, text);
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.6,
    );
    final text = _json(part);
    final chunks = agentTextChunks(text, size: 1024);
    final decoration = BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    );
    if (chunks.length <= _lazyChunks) {
      return Container(
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxHeight: 280),
        decoration: decoration,
        child: SingleChildScrollView(
          child: AgentSelectableText(text, style: style),
        ),
      );
    }
    return Container(
      height: 280,
      decoration: decoration,
      child: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: chunks.length,
          itemBuilder: (_, index) {
            final chunk = chunks[index];
            return Text(
              index < chunks.length - 1 && chunk.endsWith('\n')
                  ? chunk.substring(0, chunk.length - 1)
                  : chunk,
              style: style,
            );
          },
        ),
      ),
    );
  }
}
