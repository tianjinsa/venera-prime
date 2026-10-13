part of 'agent_settings_page.dart';

class _AgentSettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? footer;
  const _AgentSettingsScaffold({
    required this.title,
    required this.children,
    this.footer,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text(title), leading: const BackButton()),
    bottomNavigationBar: footer == null
        ? null
        : SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: SizedBox(width: double.infinity, child: footer),
                ),
              ),
            ),
          ),
    body: SafeArea(
      top: false,
      bottom: footer == null,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: PageStorageKey('agent-settings-$title'),
            padding: const EdgeInsets.only(top: 4, bottom: 28),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: children,
          ),
        ),
      ),
    ),
  );
}

class _AgentSettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  const _AgentSettingsGroup({
    required this.children,
    this.padding = EdgeInsets.zero,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

class _AgentSettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  const _AgentSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  // Match the app's Appearance / App settings: ordinary ListTile typography,
  // monochrome leading icon and chevron, with height driven by the text.
  Widget build(BuildContext context) => ListTile(
    enabled: onTap != null,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: trailing ?? const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _AgentSectionTitle extends StatelessWidget {
  final String title;
  const _AgentSectionTitle(this.title);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
    ),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.normal,
      ),
    ),
  );
}

class _AgentHelpText extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  const _AgentHelpText(this.text, {this.padding = EdgeInsets.zero});
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
  );
}

class _AgentErrorText extends StatelessWidget {
  final String text;
  const _AgentErrorText(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );
}

class _AgentEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _AgentEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });
  @override
  Widget build(BuildContext context) => _AgentSettingsGroup(
    padding: const EdgeInsets.all(28),
    children: [
      Icon(
        icon,
        size: 36,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(height: 16),
      Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}

// Labels and help are outside the input border so long translations and large
// system fonts can wrap without colliding with a floating label or another row.
Widget _agentField({
  required Key fieldKey,
  required String label,
  required TextEditingController controller,
  String? hint,
  int lines = 1,
  bool required = false,
  bool enabled = true,
  bool secret = false,
}) => Builder(
  builder: (context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextFormField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 5,
          keyboardType: lines == 1
              ? TextInputType.text
              : TextInputType.multiline,
          autocorrect: false,
          // Keep the ordinary Android keyboard and its long-press paste menu.
          enableSuggestions: true,
          enableIMEPersonalizedLearning: !secret,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            errorMaxLines: 4,
          ),
          validator: required
              ? (value) => value?.trim().isEmpty != false ? '请填写此项' : null
              : null,
        ),
        if (hint != null) ...[const SizedBox(height: 8), _AgentHelpText(hint)],
      ],
    ),
  ),
);

class _AgentChoiceField<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final String? hint;
  const _AgentChoiceField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.onChanged,
    this.hint,
  });

  Future<void> _choose(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
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
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final option in options)
                      ListTile(
                        key: ValueKey('agent-choice-${option.$1}'),
                        selected: option.$1 == value,
                        title: Text(option.$2),
                        trailing: option.$1 == value
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.pop(context, option.$1),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null && context.mounted) onChanged?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    final selected = options.where((option) => option.$1 == value).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: onChanged != null,
          title: Text(label),
          subtitle: Text(selected?.$2 ?? '请先配置可选项'),
          trailing: const Icon(Icons.arrow_drop_down),
          onTap: onChanged == null ? null : () => _choose(context),
        ),
        if (hint != null) ...[const SizedBox(height: 4), _AgentHelpText(hint!)],
      ],
    );
  }
}
