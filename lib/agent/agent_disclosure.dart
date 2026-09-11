import 'package:flutter/material.dart';

/// Compact, independently expandable activity. Explicit storage identifiers
/// keep expansion state separate from the scroll positions of selectable text.
class AgentDisclosure extends StatefulWidget {
  final String storageId;
  final String label;
  final Widget leading;
  final WidgetBuilder builder;
  final String? detail;
  final bool initiallyExpanded;
  final String? resetToken;
  final Color? color;
  final Widget? trailing;
  const AgentDisclosure({
    super.key,
    required this.storageId,
    required this.label,
    required this.leading,
    required this.builder,
    this.detail,
    this.initiallyExpanded = false,
    this.resetToken,
    this.color,
    this.trailing,
  });

  @override
  State<AgentDisclosure> createState() => _AgentDisclosureState();
}

class _DisclosureMemory {
  final bool expanded;
  final String? token;
  const _DisclosureMemory(this.expanded, this.token);
}

class _AgentDisclosureState extends State<AgentDisclosure> {
  bool _expanded = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _restore();
      _initialized = true;
    }
  }

  void _restore() {
    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: 'agent-disclosure:${widget.storageId}');
    _expanded = saved is _DisclosureMemory && saved.token == widget.resetToken
        ? saved.expanded
        : widget.initiallyExpanded;
  }

  void _remember() => PageStorage.maybeOf(context)?.writeState(
    context,
    _DisclosureMemory(_expanded, widget.resetToken),
    identifier: 'agent-disclosure:${widget.storageId}',
  );

  @override
  void didUpdateWidget(covariant AgentDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId) {
      _restore();
    } else if (oldWidget.resetToken != widget.resetToken) {
      _expanded = widget.initiallyExpanded;
      _remember();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                expanded: _expanded,
                child: TextButton(
                  key: ValueKey('toggle-${widget.storageId}'),
                  style: TextButton.styleFrom(
                    foregroundColor: color,
                    minimumSize: const Size(40, 40),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    alignment: Alignment.centerLeft,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    setState(() => _expanded = !_expanded);
                    _remember();
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconTheme(
                        data: IconThemeData(color: color, size: 15),
                        child: widget.leading,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.label,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (widget.detail?.isNotEmpty == true) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: color.withValues(alpha: .75),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _expanded ? .25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: const Icon(Icons.chevron_right, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
        if (_expanded) widget.builder(context),
      ],
    );
  }
}
