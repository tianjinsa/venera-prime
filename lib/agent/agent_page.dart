import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'agent_controller.dart';
import 'agent_history_view.dart';
import 'agent_image_view.dart';
import 'agent_images.dart';
import 'agent_message_view.dart';
import 'agent_models.dart';
import 'agent_settings_page.dart';
import 'agent_showcase_view.dart';
import 'agent_store.dart';
import 'agent_turn_view.dart';

class AgentPage extends StatefulWidget {
  final AgentController? controller;
  final Future<List<AgentImageDraft>> Function()? imagePicker;
  const AgentPage({super.key, this.controller, this.imagePicker});
  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> with WidgetsBindingObserver {
  AgentController? _controller;
  String? _loadError;
  final _draft = TextEditingController();
  final _draftImages = <AgentImageDraft>[];
  String? _draftConversation;
  bool _pickingImages = false;
  final _historySearch = TextEditingController();
  final _scroll = ScrollController();
  final _showcaseScroll = ScrollController();
  double _width = 0;
  String? _focusedGroup;
  int _focusRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final controller =
          widget.controller ??
          AgentController(await AgentStore.open('${App.dataPath}/agent'));
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(_onUpdate);
      setState(() {
        _controller = controller;
        _loadError = null;
      });
      _onUpdate();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError = 'Agent 数据无法打开。请检查数据目录或配置文件；原文件未被覆盖。';
        });
      }
    }
  }

  void _onUpdate() {
    if (!mounted) return;
    final conversationId = _controller?.conversation.id;
    if (_draftConversation != conversationId) {
      _draftConversation = conversationId;
      _draft.clear();
      _draftImages.clear();
      _focusedGroup = null;
    }
    final follow = !_scroll.hasClients || _scroll.position.extentAfter < 160;
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller?.checkpoint();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onUpdate);
    _controller?.dispose();
    _draft.dispose();
    _historySearch.dispose();
    _scroll.dispose();
    _showcaseScroll.dispose();
    super.dispose();
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error is AgentException ? error.message : '操作未完成，请重试'),
      ),
    );
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _settings() async {
    final controller = _controller!;
    await controller.stopAndWait();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentSettingsPage(store: controller.store),
      ),
    );
    if (mounted) controller.reload();
  }

  Future<void> _send() async {
    final controller = _controller!;
    if (controller.isStopping ||
        _pickingImages ||
        _draft.text.trim().isEmpty && _draftImages.isEmpty) {
      return;
    }
    if (controller.model == null) {
      await _settings();
      return;
    }
    final text = _draft.text;
    final images = _draftImages.toList();
    final conversationId = controller.conversation.id;
    setState(() {
      _draft.clear();
      _draftImages.clear();
    });
    try {
      await controller.send(text, images: images);
    } catch (e) {
      if (mounted) {
        if (controller.conversation.id == conversationId) {
          setState(() {
            _draft.text = _draft.text.isEmpty ? text : '$text\n${_draft.text}';
            _draftImages.insertAll(0, images);
          });
        }
        _error(e);
      }
    }
  }

  Future<void> _pickImages() async {
    if (_pickingImages) return;
    final conversationId = _controller!.conversation.id;
    setState(() => _pickingImages = true);
    try {
      final images = await (widget.imagePicker ?? pickAgentImages)();
      if (mounted && _controller!.conversation.id == conversationId) {
        setState(() => _draftImages.addAll(images));
      }
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _pickingImages = false);
    }
  }

  Future<String?> _editText(
    String title,
    String initial, {
    bool multiline = false,
  }) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TextField(
            controller: input,
            autofocus: true,
            minLines: multiline ? 3 : 1,
            maxLines: multiline ? 8 : 1,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    input.dispose();
    return result;
  }

  Future<bool> _deleteConversations(
    List<AgentConversation> conversations,
  ) async {
    final bytes = conversations.fold<int>(
      0,
      (total, c) => total + c.storageBytes,
    );
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          conversations.length == 1
              ? '删除这段对话？'
              : '删除 ${conversations.length} 段对话？',
        ),
        content: Text(
          '将一并删除图片、文字、工具运行记录和展示记录，内容约 ${agentFormatBytes(bytes)}。\n\n已经加入收藏和稍后再看的漫画不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('agent-confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return false;
    try {
      await _controller!.deleteConversations(conversations);
      return true;
    } catch (e) {
      _error(e);
      return false;
    }
  }

  Future<void> _history() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * .85,
      child: AnimatedBuilder(
        animation: _controller!,
        builder: (_, _) =>
            _historyPanel(close: () => Navigator.pop(sheetContext)),
      ),
    ),
  );
  Future<void> _showcase([String? id]) async {
    if (id != null) {
      setState(() {
        _focusedGroup = id;
        _focusRevision++;
      });
    }
    if (_width >= 720) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showcaseScroll.hasClients) {
          _showcaseScroll.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .85,
        child: AnimatedBuilder(
          animation: _controller!,
          builder: (_, _) =>
              _showcasePanel(close: () => Navigator.pop(sheetContext)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Material(
        child: Center(
          child: _loadError == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => _loadError = null);
                          _load();
                        },
                        child: const Text('重新打开'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      body: AnimatedBuilder(
        animation: controller,
        builder: (_, _) => LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.maxWidth;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_width >= 1024) ...[
                  SizedBox(width: 216, child: _historyPanel()),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: _chat()),
                if (_width >= 720) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 304,
                    child: _showcasePanel(scroll: _showcaseScroll),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _chat() {
    final controller = _controller!;
    final model = controller.model;
    final entries = <List<AgentMessage>>[];
    for (final message in controller.messages) {
      final startsTurn = message.role == 'user' && !message.isFollowUp;
      if (startsTurn ||
          entries.isEmpty ||
          entries.last.first.role == 'user' && !entries.last.first.isFollowUp) {
        entries.add([message]);
      } else {
        entries.last.add(message);
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              if (_width < 1024)
                IconButton(
                  tooltip: '历史对话',
                  onPressed: _history,
                  icon: const Icon(Icons.history),
                ),
              Expanded(
                child: Text(
                  controller.conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: '新对话',
                onPressed: () => _act(controller.newConversation),
                icon: const Icon(Icons.add_comment_outlined),
              ),
              if (_width < 720)
                Badge(
                  isLabelVisible: controller.showcases.isNotEmpty,
                  label: Text(
                    controller.showcases
                        .fold<int>(0, (n, g) => n + g.comics.length)
                        .toString(),
                  ),
                  child: IconButton(
                    tooltip: '展示漫画',
                    onPressed: () => _showcase(),
                    icon: const Icon(Icons.view_sidebar_outlined),
                  ),
                ),
              IconButton(
                key: const ValueKey('agent-settings'),
                tooltip: '模型设置',
                onPressed: () => _act(_settings),
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
        ),
        if (model != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: model.id,
                    underline: const SizedBox.shrink(),
                    items: controller.store.settings.models
                        .map(
                          (m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(
                              m.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: controller.busy
                        ? null
                        : (id) {
                            if (id != null) controller.selectModel(id);
                          },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: controller.thinkingId,
                    underline: const SizedBox.shrink(),
                    items: model.thinkingLevels
                        .map(
                          (level) => DropdownMenuItem(
                            value: level.id,
                            child: Text(
                              level.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: controller.busy
                        ? null
                        : (id) =>
                              controller.selectModel(model.id, thinking: id),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: controller.messages.isEmpty
              ? _empty(model == null)
              : ListView.builder(
                  key: const ValueKey('agent-messages'),
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (_, index) {
                    final messages = entries[index];
                    final message = messages.first;
                    if (message.role == 'user' && !message.isFollowUp) {
                      return Align(
                        key: ValueKey(message.id),
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 860),
                          child: AgentUserMessageView(
                            message: message,
                            busy: controller.busy,
                            imageLoader: (message, image) => controller.store
                                .imageBytes(message.conversationId, image.id),
                            onEdit: () async {
                              final text = await _editText(
                                '编辑后重发（替换后续回复）',
                                message.text,
                                multiline: true,
                              );
                              if (text != null) {
                                await _act(
                                  () => controller.editAndResend(message, text),
                                );
                              }
                            },
                          ),
                        ),
                      );
                    }
                    final current = index == entries.length - 1;
                    return Align(
                      key: ValueKey(message.id),
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: AgentTurnView(
                          messages: messages,
                          imageLoader: (message, image) => controller.store
                              .imageBytes(message.conversationId, image.id),
                          running: current && controller.busy,
                          interrupted:
                              current &&
                              controller.error != null &&
                              controller.hasUnfinishedTask,
                          modelName:
                              controller.store.settings
                                  .findModel(message.modelId)
                                  ?.name ??
                              '未配置模型',
                          busy: controller.busy,
                          onRegenerate: current
                              ? () => _act(controller.regenerate)
                              : null,
                          canRetry: controller.canRetry,
                          onRetry: (message, call) =>
                              _act(() => controller.retryTool(message, call)),
                          onShowcase: (id) => _showcase(id),
                          hasUndo: (id) => controller.store.hasUndo(
                            id,
                            controller.conversation.id,
                          ),
                          onUndo: (id) => _act(() async {
                            final result = await controller.undo(id);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '恢复 ${result['restored']} 本，跳过 ${result['skipped']} 本，失败 ${result['failed']} 本',
                                  ),
                                ),
                              );
                            }
                          }),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (controller.confirmation != null)
          _confirmation(controller.confirmation!),
        if (!controller.busy && controller.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.error!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _act(controller.resume),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('继续'),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '重试回复',
                      onSelected: (value) => _act(
                        () => controller.regenerate(
                          useCurrentModel: value == 'current',
                        ),
                      ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'original',
                          child: Text('沿用原模型重新生成'),
                        ),
                        PopupMenuItem(value: 'current', child: Text('用当前模型重试')),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('重新生成'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (model != null) _contextStatus(),
        _composer(),
      ],
    );
  }

  Widget _empty(bool noModel) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            noModel ? '先连接一个模型' : '让 Agent 帮你整理漫画',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            noModel
                ? '配置模型后，即可通过对话搜索漫画、整理收藏和稍后再看。'
                : '告诉我漫画名称或源 ID，以及你想进行的操作。\n例如：在 jm 搜索指定漫画，并加入稍后再看。',
            textAlign: TextAlign.center,
          ),
          if (noModel) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _act(_settings),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('配置模型'),
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ComicSourcePage()),
            ),
            icon: const Icon(Icons.extension_outlined),
            label: const Text('管理漫画源'),
          ),
        ],
      ),
    ),
  );

  Widget _contextStatus() {
    final controller = _controller!;
    final usage = controller.usage;
    final capacity = controller.model!.contextWindowTokens;
    final label = controller.compacting
        ? '正在压缩上下文…'
        : controller.compactionQueued
        ? '压缩已排队，当前操作结束后处理'
        : usage == null
        ? controller.contextNotice ?? '上下文 · 等待接口统计'
        : '上下文 ${usage.totalTokens} / $capacity · ${(usage.totalTokens / capacity * 100).toStringAsFixed(1)}%';
    final detail = usage == null
        ? '等待模型返回 token 使用统计后更新占用量。达到容量90%时自动压缩。'
        : '最近一次响应：输入 ${usage.inputTokens ?? "未知"}（其中缓存 ${usage.cachedTokens ?? "未知"}），输出 ${usage.outputTokens ?? "未知"}。总计 ${usage.totalTokens} tokens。缓存属于输入时不重复计数。';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
      child: Row(
        children: [
          Icon(
            Icons.data_usage,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: detail,
              child: Text(
                label,
                key: const ValueKey('agent-context-status'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('agent-compact'),
            tooltip: '压缩上下文',
            onPressed:
                controller.compacting ||
                    controller.compactionQueued ||
                    controller.isStopping ||
                    (!controller.busy && !controller.canCompact)
                ? null
                : () => _act(controller.requestCompaction),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.compress_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    final controller = _controller!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Shortcuts(
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              const _SendAgentIntent(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              const _SendAgentIntent(),
        },
        child: Actions(
          actions: {
            _SendAgentIntent: CallbackAction<_SendAgentIntent>(
              onInvoke: (_) {
                _send();
                return null;
              },
            ),
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_draftImages.isNotEmpty) ...[
                AgentImageStrip(
                  key: const ValueKey('agent-draft-images'),
                  images: _draftImages
                      .map((image) => image.attachment)
                      .toList(),
                  readImage: (image) => _draftImages
                      .firstWhere((draft) => draft.attachment.id == image.id)
                      .bytes,
                  onRemove: (image) => setState(
                    () => _draftImages.removeWhere(
                      (draft) => draft.attachment.id == image.id,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const ValueKey('agent-attach-image'),
                    tooltip: '添加图片',
                    onPressed: _pickingImages || controller.isStopping
                        ? null
                        : _pickImages,
                    icon: _pickingImages
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 22,
                          ),
                  ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('agent-input'),
                      controller: _draft,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: controller.busy ? '补充要求，当前操作结束后处理…' : '输入消息…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (controller.busy)
                    IconButton.outlined(
                      key: const ValueKey('agent-stop'),
                      tooltip: '停止',
                      onPressed: controller.isStopping ? null : controller.stop,
                      icon: const Icon(Icons.stop_rounded, size: 20),
                    ),
                  if (controller.busy) const SizedBox(width: 6),
                  IconButton.filled(
                    key: const ValueKey('agent-send'),
                    tooltip: controller.busy
                        ? '补充消息（Ctrl+Enter）'
                        : '发送（Ctrl+Enter）',
                    onPressed: controller.isStopping || _pickingImages
                        ? null
                        : _send,
                    icon: const Icon(Icons.arrow_upward, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _confirmation(AgentConfirmation confirmation) {
    final count = confirmation.arguments['comics'];
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '允许${agentToolLabels[confirmation.name] ?? confirmation.name}？',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (count is List) '涉及 ${count.length} 本漫画',
                if (confirmation.arguments['folder'] != null)
                  '收藏夹：${confirmation.arguments['folder']}',
                if (confirmation.arguments['from_folder'] != null)
                  '从“${confirmation.arguments['from_folder']}”移到“${confirmation.arguments['to_folder']}”',
                if (confirmation.arguments['name'] != null)
                  '名称：${confirmation.arguments['name']}',
              ].join(' · '),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _controller!.answerConfirmation(true),
                  child: const Text('允许'),
                ),
                TextButton(
                  onPressed: () => _controller!.answerConfirmation(false),
                  child: const Text('拒绝'),
                ),
                TextButton(
                  onPressed: () =>
                      _controller!.answerConfirmation(true, allowSession: true),
                  child: const Text('本会话允许'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyPanel({VoidCallback? close}) {
    final controller = _controller!;
    return AgentHistoryPanel(
      conversations: controller.conversations,
      currentId: controller.conversation.id,
      search: _historySearch,
      onSearch: controller.searchHistory,
      onNew: () => _act(controller.newConversation),
      close: close,
      onSelect: (conversation) {
        close?.call();
        _act(() => controller.selectConversation(conversation));
      },
      onRename: (conversation) async {
        final text = await _editText('重命名对话', conversation.title);
        if (text != null) controller.renameConversation(conversation, text);
      },
      onDelete: _deleteConversations,
    );
  }

  Widget _showcasePanel({VoidCallback? close, ScrollController? scroll}) {
    final controller = _controller!;
    return AgentShowcasePanel(
      conversationId: controller.conversation.id,
      groups: controller.showcases,
      focusedGroup: _focusedGroup,
      focusRevision: _focusRevision,
      close: close,
      scroll: scroll,
      clear: controller.clearShowcases,
      hideGroup: controller.hideShowcase,
      hideComic: controller.hideComic,
    );
  }
}

class _SendAgentIntent extends Intent {
  const _SendAgentIntent();
}
