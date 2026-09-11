import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'agent_client.dart';
import 'agent_context.dart';
import 'agent_models.dart';
import 'agent_store.dart';
import 'agent_tools.dart';
import 'agent_wire.dart';

class AgentConfirmation {
  final String name;
  final AgentJson arguments;
  const AgentConfirmation(this.name, this.arguments);
}

class AgentController extends ChangeNotifier {
  final AgentStore store;
  final AgentClient client;
  final AgentTools tools;
  late AgentConversation conversation;
  List<AgentConversation> conversations = [];
  List<AgentMessage> messages = [];
  List<AgentShowcase> showcases = [];
  String historyQuery = '';
  String? error;
  AgentConfirmation? confirmation;
  bool busy = false;
  bool compacting = false;
  bool compactionQueued = false;
  String? contextNotice;
  AgentConversationContext contextState = const AgentConversationContext();
  bool _disposed = false;
  bool _allowSession = false;
  AgentRun? _run;
  AgentMessage? _activeMessage;
  Completer<bool>? _approval;
  Future<void>? _task;
  Timer? _notifyTimer;
  Timer? _checkpointTimer;

  AgentController(this.store, {AgentClient? client, AgentTools? tools})
    : client = client ?? AgentClient(),
      tools = tools ?? AgentTools(store) {
    conversations = store.conversations();
    conversation = conversations.isEmpty
        ? store.createConversation(
            modelId: store.settings.defaultModel?.id,
            thinkingId: store.settings.defaultModel?.defaultThinking,
          )
        : conversations.first;
    reload();
  }

  AgentModel? get model =>
      store.settings.findModel(conversation.modelId) ??
      store.settings.defaultModel;
  String? get thinkingId => model?.thinking(conversation.thinkingId).id;
  bool get isStopping => busy && _run?.isCancelled == true;
  AgentUsage? get usage =>
      contextState.usageModelId == model?.id ? contextState.usage : null;
  bool get hasUnfinishedTask =>
      messages.isNotEmpty &&
      (messages.last.role == 'user' ||
          messages.last.state != 'done' ||
          messages.last.tools.isNotEmpty);
  bool get _hasQueuedInput =>
      messages.any((m) => m.role == 'user' && m.state == 'queued');
  int get _rootIndex =>
      messages.lastIndexWhere((m) => m.role == 'user' && !m.isFollowUp);
  bool get canCompact => _compactionBoundary() >= 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _throttle() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 80), () {
      _notifyTimer = null;
      _notify();
    });
  }

  void checkpoint() {
    if (!_disposed && _activeMessage != null) {
      store.saveMessage(_activeMessage!);
    }
  }

  void _scheduleCheckpoint() {
    _checkpointTimer ??= Timer(const Duration(milliseconds: 500), () {
      _checkpointTimer = null;
      checkpoint();
    });
  }

  void reload() {
    if (_disposed) return;
    messages = store.messages(conversation.id);
    showcases = store.showcases(conversation.id);
    contextState = store.conversationContext(conversation.id);
    conversations = store.conversations(historyQuery);
    if (!busy && error == null && hasUnfinishedTask) {
      final last = messages.last;
      error = last.error ?? '上次任务未完成，已保存生成内容和操作结果。发送消息或点击继续即可接着处理。';
    }
    _notify();
  }

  void searchHistory(String query) {
    historyQuery = query;
    conversations = store.conversations(query);
    _notify();
  }

  Future<void> newConversation() async {
    await stopAndWait();
    if (_disposed) return;
    _allowSession = false;
    conversation = store.createConversation(
      modelId: model?.id,
      thinkingId: thinkingId,
    );
    error = null;
    reload();
  }

  Future<void> selectConversation(AgentConversation value) async {
    if (value.id == conversation.id) return;
    await stopAndWait();
    if (_disposed) return;
    _allowSession = false;
    conversation = value;
    error = null;
    reload();
  }

  void renameConversation(AgentConversation value, String title) {
    if (title.trim().isEmpty) return;
    value.title = title.trim();
    store.saveConversation(value);
    if (value.id == conversation.id) conversation.title = value.title;
    conversations = store.conversations(historyQuery);
    _notify();
  }

  Future<void> deleteConversation(AgentConversation value) async {
    if (value.id == conversation.id) await stopAndWait();
    if (_disposed) return;
    store.deleteConversation(value.id);
    if (value.id == conversation.id) {
      final remaining = store.conversations();
      conversation = remaining.isEmpty
          ? store.createConversation(modelId: store.settings.defaultModel?.id)
          : remaining.first;
      _allowSession = false;
    }
    reload();
  }

  void selectModel(String id, {String? thinking}) {
    if (busy) return;
    final selected = store.settings.findModel(id);
    if (selected == null) return;
    conversation.modelId = id;
    conversation.thinkingId = selected.thinking(thinking).id;
    store.saveConversation(conversation);
    _notify();
  }

  Future<void> send(String text) async {
    if (_disposed) return;
    final content = text.trim();
    if (content.isEmpty) return;
    if (content.length > 32000) {
      throw const AgentException('INPUT_TOO_LARGE', '消息过长，请分段发送');
    }
    if (model == null) {
      throw const AgentException('NO_MODEL', '请先配置模型');
    }
    if (isStopping) throw const AgentException('STOPPING', '正在停止，请稍后发送');
    final selected = model!;
    final root = (busy || hasUnfinishedTask) && _rootIndex >= 0
        ? messages[_rootIndex].id
        : null;
    final message = AgentMessage(
      id: agentId(),
      conversationId: conversation.id,
      role: 'user',
      parts: [
        {
          'type': 'text',
          'text': content,
          if (root != null) 'follow_up_to': root,
        },
      ],
      modelId: selected.id,
      thinkingId: thinkingId,
      createdAt: agentNow(),
      state: busy ? 'queued' : 'done',
    );
    if (messages.isEmpty) {
      conversation.title = content.runes
          .take(24)
          .map(String.fromCharCode)
          .join();
    }
    conversation.modelId = selected.id;
    conversation.thinkingId = thinkingId;
    store.saveConversation(conversation);
    store.saveMessage(message);
    messages.add(message);
    if (busy) {
      // A new requirement invalidates unstarted calls, including a pending
      // confirmation. The operation already executing is allowed to finish.
      if (_approval != null && !_approval!.isCompleted) {
        _approval!.complete(false);
      }
      _notify();
      return;
    }
    await _start(selected, message.thinkingId);
  }

  void stop() {
    _run?.cancel();
    if (_approval != null && !_approval!.isCompleted) {
      _approval!.complete(false);
    }
    _notify();
  }

  Future<void> stopAndWait() async {
    if (!busy) return;
    stop();
    await _task;
  }

  Future<void> regenerate({bool useCurrentModel = false}) async {
    await stopAndWait();
    if (_disposed) return;
    final users = messages
        .where((m) => m.role == 'user' && !m.isFollowUp)
        .toList();
    if (users.isEmpty) return;
    final lastUser = users.last;
    final selected = useCurrentModel
        ? model
        : store.settings.findModel(lastUser.modelId);
    if (selected == null) {
      throw const AgentException('NO_MODEL', '原模型已删除，请选择“用当前模型重试”');
    }
    final supplements = messages
        .where((m) => m.followUpTo == lastUser.id)
        .toList();
    store.truncateFrom(lastUser, include: false);
    for (final message in supplements) {
      message.state = 'done';
      store.saveMessage(message);
    }
    reload();
    await _start(selected, useCurrentModel ? thinkingId : lastUser.thinkingId);
  }

  Future<void> editAndResend(AgentMessage user, String text) async {
    if (user.role != 'user' || text.trim().isEmpty) return;
    await stopAndWait();
    if (_disposed) return;
    store.truncateFrom(user);
    reload();
    await send(text);
  }

  Future<void> resume() async {
    await stopAndWait();
    if (_disposed) return;
    if (model == null || messages.every((m) => m.role != 'user')) return;
    await _start(model!, thinkingId);
  }

  static bool retryable(AgentJson call) {
    final result = call['result'];
    if (result is! Map || result['ok'] != false) return false;
    final code = result['error'] is Map ? result['error']['code'] : null;
    if (code == 'INPUT_UPDATED') return false;
    if (!AgentTools.writeTools.contains(call['name'])) return true;
    // Unknown/partial write failures are never blindly replayed.
    return {
      'INVALID_ARGUMENT',
      'FOLDER_NOT_FOUND',
      'SOURCE_NOT_FOUND',
      'HALLUCINATED_REF',
      'ID_NOT_DIRECT',
      'BATCH_TOO_LARGE',
      'NO_SEARCH_SUPPORT',
      'FOLDER_EXISTS',
    }.contains(code);
  }

  bool canRetry(AgentMessage message, AgentJson call) {
    final lastUser = _rootIndex;
    return !_disposed &&
        !busy &&
        retryable(call) &&
        messages.indexWhere((m) => m.id == message.id) > lastUser;
  }

  Future<void> retryTool(AgentMessage message, AgentJson call) async {
    if (!canRetry(message, call)) return;
    final selected = store.settings.findModel(message.modelId);
    if (selected == null) {
      throw const AgentException('NO_MODEL', '原模型已删除，无法继续这次调用');
    }
    // Later rounds can already contain successful writes. Preserve their
    // results in the next model request instead of truncating their audit.
    messages[messages.indexWhere((m) => m.id == message.id)] = message;
    store.invalidateContextFrom(message);
    contextState = store.conversationContext(conversation.id);
    await _start(
      selected,
      message.thinkingId,
      retryMessage: message,
      retryCall: call,
    );
  }

  void answerConfirmation(bool allow, {bool allowSession = false}) {
    if (_approval == null || _approval!.isCompleted) return;
    if (allow && allowSession) _allowSession = true;
    _approval!.complete(allow);
  }

  Future<bool> _confirm(String name, AgentJson args, AgentRun run) async {
    final policy = store.settings.confirmPolicy;
    final required =
        AgentTools.writeTools.contains(name) &&
        (policy == 'all' ||
            policy == 'destructive' &&
                AgentTools.destructiveTools.contains(name));
    if (!required || _allowSession) return true;
    confirmation = AgentConfirmation(name, args);
    final pending = Completer<bool>();
    _approval = pending;
    _notify();
    try {
      return await run.wait(
        pending.future,
        timeout: const Duration(minutes: 15),
      );
    } finally {
      confirmation = null;
      _approval = null;
      _notify();
    }
  }

  Future<void> _executeCall(
    AgentMessage message,
    AgentJson call,
    AgentRun run,
  ) async {
    run.check();
    if (_hasQueuedInput) {
      _skipForNewInput(message, call);
      return;
    }
    call['state'] = 'running';
    call.remove('result');
    store.saveMessage(message);
    _notify();
    final stopwatch = Stopwatch()..start();
    final args = agentObject(call['arguments']);
    final name = call['name'] as String;
    final allowed = await _confirm(name, args, run);
    run.check();
    if (_hasQueuedInput) {
      _skipForNewInput(message, call);
      return;
    }
    final result = allowed
        ? await tools.execute(
            name,
            args,
            AgentToolContext(conversation.id, run),
          )
        : const AgentException('USER_DENIED', '用户拒绝了该操作，不要重复请求').toJson();
    run.check();
    call['result'] = result;
    call['state'] = result['ok'] == true ? 'done' : 'failed';
    call['duration_ms'] = stopwatch.elapsedMilliseconds;
    store.saveMessage(message);
    showcases = store.showcases(conversation.id);
    _notify();
  }

  void _skipForNewInput(AgentMessage message, AgentJson call) {
    call['state'] = 'skipped';
    call['result'] = const AgentException(
      'INPUT_UPDATED',
      '用户补充了要求，该工具尚未执行，请按新要求重新判断',
    ).toJson();
    store.saveMessage(message);
    _notify();
  }

  int _compactionBoundary() {
    final previous = messages.indexWhere(
      (m) => m.id == contextState.throughMessageId,
    );
    final candidates = <int>[];
    for (var i = previous + 1; i < messages.length; i++) {
      final message = messages[i];
      if (message.role == 'assistant' &&
          message.state != 'running' &&
          !message.tools.any(
            (call) => ['pending', 'running'].contains(call['state']),
          )) {
        candidates.add(i);
      }
    }
    // Keep the newest response and its tool receipts when possible.
    return candidates.isEmpty
        ? -1
        : candidates[candidates.length > 1 ? candidates.length - 2 : 0];
  }

  bool _shouldCompact(AgentModel selected) =>
      contextState.usageModelId == selected.id &&
      (contextState.usage?.totalTokens ?? 0) >=
          selected.contextWindowTokens * .9;

  Future<void> requestCompaction() async {
    if (_disposed || model == null || isStopping || compacting) return;
    if (busy) {
      compactionQueued = true;
      _notify();
      return;
    }
    await _start(model!, thinkingId, compactOnly: true);
  }

  Future<void> _compact(
    AgentModel selected,
    String? thinking,
    AgentRun run,
  ) async {
    compactionQueued = false;
    final boundary = _compactionBoundary();
    if (boundary < 0) {
      contextNotice = '暂无可压缩的历史';
      return;
    }
    compacting = true;
    _notify();
    final previous = contextState;
    final throughId = messages[boundary].id;
    try {
      final response = await client.complete(
        model: selected,
        apiKey: store.secrets[selected.id] ?? '',
        thinkingId: thinking,
        messages: [
          ...agentWire(
            messages.sublist(0, boundary + 1),
            selected,
            context: previous,
          ),
          {'role': 'user', 'content': agentCompactionPrompt},
        ],
        tools: const [],
        run: run,
        onDelta: (_, _) {},
      );
      run.check();
      if (response.text.trim().isEmpty || response.tools.isNotEmpty) {
        throw const AgentException('INVALID_SUMMARY', '模型没有返回有效的上下文摘要');
      }
      final next = AgentConversationContext(
        summary: response.text.trim(),
        throughMessageId: throughId,
        compactedAt: agentNow(),
        compactionCount: previous.compactionCount + 1,
      );
      // Save only complete summaries. The summarizer's usage is not the next
      // conversation request's occupancy, so wait for new response statistics.
      store.saveContext(conversation.id, next);
      contextState = next;
      contextNotice = '上下文已压缩，完整记录仍可查看';
    } catch (e) {
      if (run.isCancelled) rethrow;
      throw AgentException(
        'COMPACTION_FAILED',
        '上下文压缩失败，原上下文已保留。${e is AgentException ? e.message : '请稍后重试。'}',
      );
    } finally {
      compacting = false;
      _notify();
    }
  }

  Future<void> _start(
    AgentModel selected,
    String? thinking, {
    AgentMessage? retryMessage,
    AgentJson? retryCall,
    bool compactOnly = false,
  }) async {
    while (busy && !_disposed) {
      await stopAndWait();
    }
    if (_disposed) return;
    selected.validate();
    final run = AgentRun();
    _run = run;
    busy = true;
    error = null;
    contextNotice = null;
    _notify();
    final task = _generate(
      selected,
      thinking,
      run,
      retryMessage: retryMessage,
      retryCall: retryCall,
      compactOnly: compactOnly,
    );
    _task = task;
    await task;
  }

  Future<void> _generate(
    AgentModel selected,
    String? thinking,
    AgentRun run, {
    AgentMessage? retryMessage,
    AgentJson? retryCall,
    bool compactOnly = false,
  }) async {
    try {
      if (compactOnly) {
        await _compact(selected, thinking, run);
        if (!_hasQueuedInput) return;
      }
      if (retryMessage != null && retryCall != null) {
        _activeMessage = retryMessage;
        await _executeCall(retryMessage, retryCall, run);
        retryMessage.state = 'done';
        retryMessage.error = null;
        store.saveMessage(retryMessage);
        _activeMessage = null;
      }
      while (true) {
        run.check();
        if (compactionQueued || _shouldCompact(selected)) {
          await _compact(selected, thinking, run);
        }
        run.check();
        for (final input in messages.where(
          (m) => m.role == 'user' && m.state == 'queued',
        )) {
          input.state = 'done';
          store.saveMessage(input);
        }
        final wire = agentWire(messages, selected, context: contextState);
        final assistant = AgentMessage(
          id: agentId(),
          conversationId: conversation.id,
          role: 'assistant',
          parts: [],
          modelId: selected.id,
          thinkingId: selected.thinking(thinking).id,
          createdAt: agentNow(),
          state: 'running',
        );
        _activeMessage = assistant;
        messages.add(assistant);
        store.saveMessage(assistant);
        _notify();
        final response = await client.complete(
          model: selected,
          apiKey: store.secrets[selected.id] ?? '',
          thinkingId: thinking,
          messages: wire,
          tools: AgentTools.schemas,
          run: run,
          onDelta: (type, text) {
            if (_disposed || run.isCancelled) return;
            assistant.appendText(type, text);
            _throttle();
            _scheduleCheckpoint();
          },
        );
        run.check();
        // Some clients expose only a final result, without delta callbacks.
        if (assistant.text.isEmpty && response.text.isNotEmpty) {
          assistant.appendText('text', response.text);
        }
        if (!assistant.parts.any((p) => p['type'] == 'reasoning') &&
            response.reasoning.isNotEmpty) {
          assistant.appendText('reasoning', response.reasoning);
        }
        for (final tool in response.tools) {
          assistant.parts.add({
            'type': 'tool_call',
            'id': tool.id,
            'name': tool.name,
            'arguments': agentObject(jsonDecode(tool.arguments)),
            'state': 'pending',
          });
        }
        store.saveMessage(assistant);
        contextState = contextState.withUsage(response.usage, selected.id);
        store.saveContext(conversation.id, contextState);
        for (final call in assistant.tools) {
          await _executeCall(assistant, call, run);
        }
        assistant.state = 'done';
        store.saveMessage(assistant);
        _activeMessage = null;
        _notify();
        if (response.tools.isEmpty && !_hasQueuedInput) {
          if (compactionQueued || _shouldCompact(selected)) {
            await _compact(selected, thinking, run);
          }
          if (!_hasQueuedInput) return;
        }
      }
    } catch (e) {
      if (_disposed) return;
      final interrupted = run.isCancelled;
      error = interrupted
          ? '已停止等待。已完成的操作已保存，源请求可能仍在结束中。'
          : e is AgentException
          ? e.message
          : '本轮未完成，请检查配置或重试。';
      _markInterrupted(interrupted ? 'interrupted' : 'failed');
    } finally {
      busy = false;
      compacting = false;
      compactionQueued = false;
      _activeMessage = null;
      _checkpointTimer?.cancel();
      _checkpointTimer = null;
      if (!_disposed) {
        _notifyTimer?.cancel();
        _notifyTimer = null;
        confirmation = null;
        conversations = store.conversations(historyQuery);
        showcases = store.showcases(conversation.id);
        _notify();
      }
    }
  }

  void _markInterrupted(String state) {
    final message = _activeMessage;
    if (message == null) return;
    message.state = state;
    message.error = error;
    for (final call in message.tools) {
      if (call['state'] == 'pending' || call['state'] == 'running') {
        call['state'] = 'interrupted';
        call['result'] = const AgentException(
          'CANCELLED',
          '工具未完成，未取得成功结果',
        ).toJson();
      }
    }
    store.saveMessage(message);
  }

  Future<AgentJson> undo(String id) async {
    if (busy || _disposed) return {'restored': 0, 'skipped': 0, 'failed': 0};
    await tools.favorites.init();
    await tools.later.init();
    if (_disposed) return {'restored': 0, 'skipped': 0, 'failed': 0};
    final result = tools.undo(
      id,
      AgentToolContext(conversation.id, AgentRun()),
    );
    reload();
    return result;
  }

  void hideComic(String setId, AgentComic comic) {
    store.hideComic(setId, comic);
    showcases = store.showcases(conversation.id);
    _notify();
  }

  void hideShowcase(String id) {
    store.hideShowcase(id);
    showcases = store.showcases(conversation.id);
    _notify();
  }

  void clearShowcases() {
    store.clearShowcases(conversation.id);
    showcases = [];
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (busy) {
      _run?.cancel();
      error = '页面已离开，生成已停止';
      _markInterrupted('interrupted');
    }
    _disposed = true;
    _notifyTimer?.cancel();
    _checkpointTimer?.cancel();
    if (_approval != null && !_approval!.isCompleted) {
      _approval!.complete(false);
    }
    client.close();
    store.close();
    super.dispose();
  }
}
