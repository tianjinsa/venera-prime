import 'package:flutter/material.dart';
import 'package:venera/foundation/consts.dart';
import 'agent_controller.dart';
import 'agent_models.dart';
import 'agent_settings_page.dart';

bool agentUsesMobileModelHeader(BuildContext context) =>
    MediaQuery.sizeOf(context).width <= changePoint;

/// Shares a page-owned controller with the surrounding navigation title bar.
class AgentModelHeaderBridge extends ChangeNotifier {
  AgentController? _controller;
  Object? _selection;
  bool _scheduled = false;
  bool _disposed = false;

  AgentController? get controller => _controller;

  void bind(AgentController controller) {
    if (_disposed || identical(_controller, controller)) return;
    _controller?.removeListener(_changed);
    _controller = controller;
    controller.addListener(_changed);
    _changed();
  }

  void unbind(AgentController controller) {
    if (_disposed || !identical(_controller, controller)) return;
    controller.removeListener(_changed);
    _controller = null;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    final controller = _controller;
    final selection = (
      controller,
      controller?.store.settings,
      controller?.model?.id,
      controller?.thinkingId,
      controller?.busy,
    );
    if (_selection == selection) return;
    _selection = selection;
    if (_scheduled) return;
    _scheduled = true;
    // Binding can happen while AgentPage is building under the title bar.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_changed);
    _controller = null;
    super.dispose();
  }
}

class AgentModelHeader extends StatefulWidget {
  final AgentModelHeaderBridge bridge;
  const AgentModelHeader({super.key, required this.bridge});

  @override
  State<AgentModelHeader> createState() => _AgentModelHeaderState();
}

class _AgentModelHeaderState extends State<AgentModelHeader> {
  bool _panelOpen = false;

  Future<void> _openPanel() async {
    if (_panelOpen || widget.bridge.controller == null) return;
    _panelOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await _showModelSelection(context, widget.bridge);
    } finally {
      _panelOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.bridge,
    builder: (context, _) {
      final controller = widget.bridge.controller;
      final model = controller?.model;
      final name = model?.name ?? '未配置模型';
      final thinking = model?.thinking(controller?.thinkingId).label ?? '思考深度';
      final scheme = Theme.of(context).colorScheme;
      return Tooltip(
        message: '$name · $thinking\n选择模型与思考深度',
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const ValueKey('agent-model-header'),
            borderRadius: BorderRadius.circular(12),
            onTap: controller == null ? null : _openPanel,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          key: const ValueKey('agent-header-model-name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        Text(
                          thinking,
                          key: const ValueKey('agent-header-thinking-name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    controller?.busy == true
                        ? Icons.lock_outline
                        : Icons.expand_more,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<void> _showModelSelection(
  BuildContext context,
  AgentModelHeaderBridge bridge,
) async {
  final manage = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _ModelSelectionPanel(bridge: bridge),
  );
  if (manage != true || !context.mounted) return;
  final controller = bridge.controller;
  if (controller == null || controller.busy) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AgentModelsPage(store: controller.store),
    ),
  );
  if (context.mounted && identical(bridge.controller, controller)) {
    controller.reload();
  }
}

/// The wider and standalone layouts use the same picker as the mobile header.
class AgentModelPickerButton extends StatefulWidget {
  final AgentController controller;
  const AgentModelPickerButton({super.key, required this.controller});
  @override
  State<AgentModelPickerButton> createState() => _AgentModelPickerButtonState();
}

class _AgentModelPickerButtonState extends State<AgentModelPickerButton> {
  bool _open = false;
  Future<void> _show() async {
    if (_open) return;
    _open = true;
    final bridge = AgentModelHeaderBridge()..bind(widget.controller);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await _showModelSelection(context, bridge);
    } finally {
      bridge.dispose();
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.controller.model;
    return OutlinedButton(
      key: const ValueKey('agent-model-picker-button'),
      onPressed: _show,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              model?.name ?? '选择模型',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              model?.thinking(widget.controller.thinkingId).label ?? '',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more_rounded, size: 20),
        ],
      ),
    );
  }
}

class _ModelSelectionPanel extends StatefulWidget {
  final AgentModelHeaderBridge bridge;
  const _ModelSelectionPanel({required this.bridge});
  @override
  State<_ModelSelectionPanel> createState() => _ModelSelectionPanelState();
}

class _ModelSelectionPanelState extends State<_ModelSelectionPanel> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _select(AgentController controller, String id, {String? thinking}) {
    if (identical(widget.bridge.controller, controller) && !controller.busy) {
      controller.selectModel(id, thinking: thinking);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.bridge,
    builder: (context, _) {
      final controller = widget.bridge.controller;
      final model = controller?.model;
      final busy = controller?.busy == true;
      final theme = Theme.of(context);
      final query = _search.text.trim().toLowerCase();
      final models =
          controller?.store.settings.models
              .where(
                (item) =>
                    query.isEmpty ||
                    item.name.toLowerCase().contains(query) ||
                    item.model.toLowerCase().contains(query),
              )
              .toList() ??
          const <AgentModel>[];
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: CustomScrollView(
              key: const ValueKey('agent-model-selection-panel'),
              shrinkWrap: true,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '选择模型',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                        if (controller == null)
                          const Text('当前对话已关闭。')
                        else if (model == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text('还没有模型，先添加一个开始对话。'),
                          )
                        else ...[
                          if (busy) ...[
                            const Text('运行中，暂时不能切换模型或思考深度。'),
                            const SizedBox(height: 12),
                          ],
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('思考深度', style: theme.textTheme.labelLarge),
                                const SizedBox(height: 4),
                                Text(
                                  model.name,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  key: const ValueKey(
                                    'agent-header-thinking-selector',
                                  ),
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final level in model.thinkingLevels)
                                      ChoiceChip(
                                        key: ValueKey(
                                          'agent-picker-thinking-${level.id}',
                                        ),
                                        label: Text(level.label),
                                        selected:
                                            controller.thinkingId == level.id,
                                        onSelected: busy
                                            ? null
                                            : (_) => _select(
                                                controller,
                                                model.id,
                                                thinking: level.id,
                                              ),
                                        visualDensity: VisualDensity.standard,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            key: const ValueKey('agent-model-search'),
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              hintText: '搜索模型名称或 ID',
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清空搜索',
                                      onPressed: () => setState(_search.clear),
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                              filled: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (model != null && models.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '没有匹配的模型，试试其他名称或 ID。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.builder(
                    key: const ValueKey('agent-header-model-selector'),
                    itemCount: models.length,
                    itemBuilder: (context, index) {
                      final item = models[index];
                      final selected = item.id == model?.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Material(
                          color: selected
                              ? theme.colorScheme.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: ListTile(
                            key: ValueKey('agent-picker-model-${item.id}'),
                            selected: selected,
                            enabled: !busy,
                            selectedColor:
                                theme.colorScheme.onSecondaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: Icon(
                              selected
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                            ),
                            title: Text(
                              item.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(item.model),
                            onTap: busy || controller == null
                                ? null
                                : () => _select(controller, item.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    child: TextButton.icon(
                      key: const ValueKey('agent-picker-manage-models'),
                      onPressed: controller == null || busy
                          ? null
                          : () => Navigator.pop(context, true),
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('管理模型'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
