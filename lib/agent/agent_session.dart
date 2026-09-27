import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'agent_controller.dart';
import 'agent_models.dart';
import 'agent_notice.dart';
import 'agent_store.dart';

/// What the Agent navigation item shows while no agent page is in view.
enum AgentTabStatus { none, running, confirm, unread }

/// Holds the agent for the lifetime of the app process, so a running task
/// keeps going while other tabs are shown. The store opens lazily the first
/// time the agent page is built; nothing starts with the app itself.
class AgentSession with WidgetsBindingObserver {
  AgentSession._(this.controller) {
    controller.addListener(_scheduleUpdate);
  }

  final AgentController controller;

  static Future<AgentSession>? _opening;
  static AgentSession? _current;

  /// Status for the navigation badge; stays [AgentTabStatus.none] until the
  /// session opens.
  static final status = ValueNotifier(AgentTabStatus.none);

  /// Contexts of shared-session agent pages that are on screen, most recently
  /// shown last. Pages covered by another route are not listed.
  static final _visiblePages = <BuildContext>[];

  /// Where pages opened by the agent go: above the agent page in view, so
  /// they stay visible when the agent is shown on its own full-screen route.
  static BuildContext? get pageContext =>
      _visiblePages.isEmpty ? null : _visiblePages.last;

  /// Lets tests supply a controller with a fake model client.
  @visibleForTesting
  static AgentController Function(AgentStore store) createController =
      AgentController.new;

  static Future<AgentController> open() async {
    final opening = _opening ??= _open();
    try {
      return (await opening).controller;
    } catch (_) {
      // A failed open is retried the next time the page is built.
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  static Future<AgentSession> _open() async {
    final store = await AgentStore.open('${App.dataPath}/agent');
    final session = AgentSession._(createController(store));
    WidgetsBinding.instance.addObserver(session);
    _current = session;
    session._scheduleUpdate();
    return session;
  }

  static void setPageVisible(BuildContext page, bool visible) {
    _visiblePages.remove(page);
    if (visible) _visiblePages.add(page);
    _current?._scheduleUpdate();
  }

  @visibleForTesting
  static Future<void> reset() async {
    final opening = _opening;
    _opening = null;
    _current = null;
    _visiblePages.clear();
    status.value = AgentTabStatus.none;
    createController = AgentController.new;
    hideAgentConfirmNotice();
    if (opening == null) return;
    try {
      final session = await opening;
      WidgetsBinding.instance.removeObserver(session);
      session.controller.removeListener(session._scheduleUpdate);
      session.controller.dispose();
    } catch (_) {}
  }

  bool _updateScheduled = false;
  bool _wasBusy = false;
  bool _unread = false;
  AgentConfirmation? _seenConfirmation;

  /// Visibility changes arrive while routes rebuild; the badge and notice
  /// update after that build.
  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    scheduleMicrotask(() {
      _updateScheduled = false;
      if (identical(_current, this)) _update();
    });
  }

  void _update() {
    final visible = _visiblePages.isNotEmpty;
    final busy = controller.busy;
    if (visible) {
      _unread = false;
    } else if (_wasBusy && !busy) {
      _unread = true;
    }
    _wasBusy = busy;
    final confirmation = controller.confirmation;
    if (confirmation == null || visible) {
      hideAgentConfirmNotice();
    } else if (!identical(confirmation, _seenConfirmation)) {
      final name = agentToolLabels[confirmation.name] ?? confirmation.name;
      showAgentConfirmNotice('Agent 需要确认：允许$name？');
    }
    // A request already seen on the agent page does not notify again.
    _seenConfirmation = confirmation;
    status.value = visible
        ? AgentTabStatus.none
        : confirmation != null
        ? AgentTabStatus.confirm
        : busy
        ? AgentTabStatus.running
        : _unread
        ? AgentTabStatus.unread
        : AgentTabStatus.none;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) controller.checkpoint();
  }
}
