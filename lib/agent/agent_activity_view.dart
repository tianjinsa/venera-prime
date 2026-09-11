import 'package:flutter/material.dart';
import 'agent_disclosure.dart';

/// Consecutive reasoning and tools between two visible conversation messages.
class AgentActivityView extends StatelessWidget {
  final String storageId;
  final String resetToken;
  final int reasoningCount;
  final int toolCount;
  final int failures;
  final bool running;
  final List<Widget> children;
  const AgentActivityView({
    super.key,
    required this.storageId,
    required this.resetToken,
    required this.reasoningCount,
    required this.toolCount,
    required this.failures,
    required this.running,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final surface = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? .06 : .045),
      scheme.surface,
    );
    final secondary = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: .72),
      surface,
    );
    final border = scheme.onSurface.withValues(alpha: .1);
    final detailSurface = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? .035 : .025),
      surface,
    );
    final activityTheme = theme.copyWith(
      colorScheme: scheme.copyWith(
        onSurface: secondary,
        onSurfaceVariant: secondary,
        surfaceContainerLow: detailSurface,
        outlineVariant: border,
      ),
      textTheme: theme.textTheme.apply(
        bodyColor: secondary,
        displayColor: secondary,
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Theme(
        data: activityTheme,
        child: AgentDisclosure(
          storageId: storageId,
          resetToken: resetToken,
          label: running ? '执行中' : '执行过程',
          detail: [
            if (reasoningCount > 0) '思考 $reasoningCount',
            if (toolCount > 0) '工具 $toolCount',
            if (failures > 0) '$failures 项未完成',
          ].join(' · '),
          color: failures > 0 ? scheme.error : secondary,
          leading: running
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : const Icon(Icons.account_tree_outlined),
          builder: (_) => Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
