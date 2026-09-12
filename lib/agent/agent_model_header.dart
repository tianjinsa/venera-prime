import 'package:flutter/material.dart';
import 'package:venera/foundation/consts.dart';
import 'agent_controller.dart';

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
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 640),
        builder: (_) => _ModelSelectionPanel(bridge: widget.bridge),
      );
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
          color: scheme.surfaceContainerHighest.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: const ValueKey('agent-model-header'),
            borderRadius: BorderRadius.circular(10),
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

class _ModelSelectionPanel extends StatelessWidget {
  final AgentModelHeaderBridge bridge;
  const _ModelSelectionPanel({required this.bridge});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: bridge,
    builder: (context, _) {
      final controller = bridge.controller;
      final model = controller?.model;
      final busy = controller?.busy == true;
      void select(String? id, {String? thinking}) {
        if (id != null &&
            controller != null &&
            identical(bridge.controller, controller) &&
            !controller.busy) {
          controller.selectModel(id, thinking: thinking);
        }
      }

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const ValueKey('agent-model-selection-panel'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型与思考深度',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (controller == null)
                const Text('当前对话已关闭。')
              else if (model == null)
                const Text('请先在模型设置中添加模型。')
              else ...[
                if (busy) ...[
                  const Text('运行中，暂时不能切换模型或思考深度。'),
                  const SizedBox(height: 16),
                ],
                _selector(
                  label: '模型',
                  child: DropdownButton<String>(
                    key: const ValueKey('agent-header-model-selector'),
                    value: model.id,
                    isExpanded: true,
                    itemHeight: null,
                    items: controller.store.settings.models
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.id,
                            child: Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy ? null : select,
                  ),
                ),
                const SizedBox(height: 20),
                _selector(
                  label: '思考深度',
                  child: DropdownButton<String>(
                    key: const ValueKey('agent-header-thinking-selector'),
                    value: controller.thinkingId,
                    isExpanded: true,
                    itemHeight: null,
                    items: model.thinkingLevels
                        .map(
                          (level) => DropdownMenuItem(
                            value: level.id,
                            child: Text(
                              level.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (id) => select(model.id, thinking: id),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _selector({required String label, required Widget child}) =>
      InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(child: child),
      );
}
