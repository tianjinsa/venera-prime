import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart' show OverlayWidgetState;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'agent_page.dart';
import 'agent_session.dart';

/// Status bubble on the Agent navigation item: a spinner while running, an
/// exclamation mark while a write waits for approval, and a dot for results
/// that arrived while no agent page was in view.
class AgentTabBadge extends StatelessWidget {
  final Widget child;
  const AgentTabBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: AgentSession.status,
    builder: (context, status, child) {
      final scheme = Theme.of(context).colorScheme;
      return switch (status) {
        AgentTabStatus.none => child!,
        AgentTabStatus.running => Badge(
          key: const ValueKey('agent-tab-running'),
          backgroundColor: scheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 3.5),
          label: Semantics(
            label: 'Agent 运行中',
            child: SizedBox.square(
              dimension: 9,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: scheme.onPrimary,
              ),
            ),
          ),
          child: child,
        ),
        AgentTabStatus.confirm => Badge(
          key: const ValueKey('agent-tab-confirm'),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          label: Icon(
            Icons.priority_high,
            size: 10,
            color: scheme.onError,
            semanticLabel: 'Agent 等待确认',
          ),
          child: child,
        ),
        AgentTabStatus.unread => Semantics(
          label: 'Agent 有新结果',
          child: Badge(
            key: const ValueKey('agent-tab-unread'),
            smallSize: 8,
            child: child,
          ),
        ),
      };
    },
    child: child,
  );
}

Route<void>? _standaloneRoute;

/// Shows the agent on its own route above everything, without the navigation
/// bars or their search and toolbox actions. Going back returns to the page
/// that was shown before; an agent route already open is reused.
void openAgentPage() {
  hideAgentConfirmNotice();
  final navigator = App.rootNavigatorKey.currentState;
  if (navigator == null) return;
  final existing = _standaloneRoute;
  if (existing != null && existing.isActive) {
    navigator.popUntil((route) => route == existing);
    return;
  }
  final route = AppPageRoute<void>(
    builder: (_) => const AgentPage(standalone: true),
  );
  _standaloneRoute = route;
  unawaited(navigator.push(route));
}

OverlayEntry? _noticeEntry;
OverlayWidgetState? _noticeOverlay;
Timer? _noticeTimer;

/// A short, tappable message above the app's pages; tapping opens the agent.
void showAgentConfirmNotice(String message) {
  hideAgentConfirmNotice();
  final overlay = App.rootNavigatorKey.currentContext
      ?.findAncestorStateOfType<OverlayWidgetState>();
  if (overlay == null) return;
  final entry = OverlayEntry(builder: (_) => _AgentNotice(message: message));
  overlay.addOverlay(entry);
  _noticeEntry = entry;
  _noticeOverlay = overlay;
  _noticeTimer = Timer(const Duration(seconds: 8), hideAgentConfirmNotice);
}

void hideAgentConfirmNotice() {
  _noticeTimer?.cancel();
  _noticeTimer = null;
  final entry = _noticeEntry;
  _noticeEntry = null;
  if (entry != null) _noticeOverlay?.remove(entry);
  _noticeOverlay = null;
}

class _AgentNotice extends StatelessWidget {
  final String message;
  const _AgentNotice({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return Positioned(
      // Above the bottom navigation bar, so the Agent badge stays visible.
      bottom: 80 + media.viewPadding.bottom + media.viewInsets.bottom,
      left: 16,
      right: 16,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            key: const ValueKey('agent-confirm-notice'),
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(8),
            elevation: 2,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: openAgentPage,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 20,
                      color: scheme.onInverseSurface,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: openAgentPage,
                      child: Text(
                        '查看',
                        style: TextStyle(color: scheme.inversePrimary),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: hideAgentConfirmNotice,
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: scheme.onInverseSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
