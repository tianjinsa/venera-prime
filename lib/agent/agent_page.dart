import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart' show ComicTile;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'agent_controller.dart';
import 'agent_message_view.dart';
import 'agent_models.dart';
import 'agent_settings_page.dart';
import 'agent_store.dart';
import 'agent_tools.dart';

class AgentPage extends StatefulWidget {
  final AgentController? controller;
  const AgentPage({super.key, this.controller});
  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  AgentController? _controller;
  String? _loadError;
  final _draft = TextEditingController();
  final _historySearch = TextEditingController();
  final _scroll = ScrollController();
  final _showcaseScroll = ScrollController();
  double _width = 0;
  String? _focusedGroup;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
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
    if (controller.busy || _draft.text.trim().isEmpty) return;
    if (controller.model == null) {
      await _settings();
      return;
    }
    final text = _draft.text;
    _draft.clear();
    try {
      await controller.send(text);
    } catch (e) {
      if (mounted) {
        _draft.text = text;
        _error(e);
      }
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

  Future<void> _deleteConversation(AgentConversation conversation) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这段对话？'),
        content: const Text('对话及其展示记录将删除，已经加入收藏和稍后再看的漫画不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await _act(() => _controller!.deleteConversation(conversation));
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
    if (id != null) setState(() => _focusedGroup = id);
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
                    width: 280,
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
    final lastUser = controller.messages.lastIndexWhere(
      (m) => m.role == 'user',
    );
    // A user turn may contain many model responses. Render every step and its
    // ordered parts instead of flattening reasoning, prose, and tool calls.
    final steps = <int>[];
    var step = 0;
    for (final message in controller.messages) {
      step = message.role == 'user' ? 0 : step + 1;
      steps.add(step);
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
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: controller.messages.length,
                  itemBuilder: (_, index) {
                    final message = controller.messages[index];
                    return AgentMessageView(
                      key: ValueKey(message.id),
                      message: message,
                      stepNumber: steps[index] == 0 ? null : steps[index],
                      modelName:
                          controller.store.settings
                              .findModel(message.modelId)
                              ?.name ??
                          'Agent',
                      busy: controller.busy,
                      onEdit: message.role == 'user'
                          ? () async {
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
                            }
                          : null,
                      onRegenerate:
                          index == controller.messages.length - 1 &&
                              index > lastUser
                          ? () => _act(controller.regenerate)
                          : null,
                      canRetry: (call) => controller.canRetry(message, call),
                      onRetry: (call) =>
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('agent-input'),
                  controller: _draft,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '输入消息…',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('agent-send'),
                tooltip: controller.busy ? '停止' : '发送（Ctrl+Enter）',
                onPressed: controller.isStopping
                    ? null
                    : controller.busy
                    ? controller.stop
                    : _send,
                icon: Icon(
                  controller.busy ? Icons.stop_rounded : Icons.arrow_upward,
                ),
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
    return Column(
      children: [
        ListTile(
          title: const Text('历史对话'),
          trailing: close == null
              ? IconButton(
                  tooltip: '新对话',
                  onPressed: () => _act(controller.newConversation),
                  icon: const Icon(Icons.add),
                )
              : IconButton(
                  tooltip: '关闭',
                  onPressed: close,
                  icon: const Icon(Icons.close),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
            controller: _historySearch,
            onChanged: controller.searchHistory,
            decoration: const InputDecoration(
              hintText: '搜索对话',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: controller.conversations.length,
            itemBuilder: (_, index) {
              final conversation = controller.conversations[index];
              final date = DateTime.fromMillisecondsSinceEpoch(
                conversation.updatedAt,
              );
              return ListTile(
                selected: conversation.id == controller.conversation.id,
                title: Text(
                  conversation.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${date.month}/${date.day} · ${conversation.messageCount} 条消息',
                ),
                onTap: () {
                  close?.call();
                  _focusedGroup = null;
                  _act(() => controller.selectConversation(conversation));
                },
                trailing: PopupMenuButton<String>(
                  enabled: !controller.busy,
                  onSelected: (action) async {
                    if (action == 'delete') {
                      await _deleteConversation(conversation);
                    } else {
                      final text = await _editText('重命名对话', conversation.title);
                      if (text != null) {
                        controller.renameConversation(conversation, text);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _showcasePanel({VoidCallback? close, ScrollController? scroll}) {
    final controller = _controller!;
    final groups = [...controller.showcases];
    final focus = groups.indexWhere((g) => g.id == _focusedGroup);
    if (focus > 0) groups.insert(0, groups.removeAt(focus));
    return Column(
      children: [
        ListTile(
          title: const Text('展示漫画'),
          trailing: close == null
              ? IconButton(
                  tooltip: '清空展示面板',
                  onPressed: groups.isEmpty ? null : controller.clearShowcases,
                  icon: const Icon(Icons.clear_all),
                )
              : IconButton(
                  tooltip: '关闭',
                  onPressed: close,
                  icon: const Icon(Icons.close),
                ),
        ),
        if (close != null && groups.isNotEmpty)
          TextButton(
            onPressed: controller.clearShowcases,
            child: const Text('清空展示面板'),
          ),
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Agent 展示的漫画会出现在这里',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: groups.length,
                  itemBuilder: (_, index) {
                    final group = groups[index];
                    return Card(
                      key: ValueKey(group.id),
                      color: group.id == _focusedGroup
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            title: Text(
                              group.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${group.comics.length} 本'),
                            trailing: IconButton(
                              tooltip: '移除此组',
                              onPressed: () =>
                                  controller.hideShowcase(group.id),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ),
                          if (group.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                group.note,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(8),
                            itemCount: group.comics.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      appdata.settings['comicDisplayMode'] ==
                                          'detailed'
                                      ? 1
                                      : 2,
                                  mainAxisExtent:
                                      appdata.settings['comicDisplayMode'] ==
                                          'detailed'
                                      ? 136
                                      : null,
                                  childAspectRatio: .58,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                            itemBuilder: (_, comicIndex) {
                              final comic = group.comics[comicIndex];
                              return Stack(
                                children: [
                                  Positioned.fill(
                                    child: ComicTile(
                                      comic: AgentTools.toComic(comic),
                                      heroID: Object.hash(
                                        group.id,
                                        comic.identity,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: IconButton.filledTonal(
                                      tooltip: '从展示中移除',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          controller.hideComic(group.id, comic),
                                      icon: const Icon(Icons.close, size: 14),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SendAgentIntent extends Intent {
  const _SendAgentIntent();
}
