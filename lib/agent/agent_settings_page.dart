import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent_models.dart';
import 'agent_source_backups.dart';
import 'agent_store.dart';

class AgentSettingsPage extends StatefulWidget {
  final AgentStore store;
  const AgentSettingsPage({super.key, required this.store});
  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  bool _saving = false;

  Future<void> _save(AgentSettings settings) async {
    setState(() => _saving = true);
    try {
      await widget.store.saveSettings(settings, widget.store.secrets);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败，请检查数据目录是否可写')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([AgentModel? model]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AgentModelEditor(store: widget.store, original: model),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _delete(AgentModel model) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${model.name}”？'),
        content: const Text('历史消息会保留。以后仍可重新配置该模型。'),
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
    if (confirm != true) return;
    final settings = widget.store.settings;
    final models = settings.models.where((m) => m.id != model.id).toList();
    await _save(
      AgentSettings(
        models: models,
        defaultModelId: settings.defaultModelId == model.id
            ? (models.isEmpty ? null : models.first.id)
            : settings.defaultModelId,
        confirmPolicy: settings.confirmPolicy,
        autoBackupLimit: settings.autoBackupLimit,
        manualBackupLimit: settings.manualBackupLimit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Agent 模型设置')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '连接你自己的模型服务',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '支持 Chat Completions、OpenAI Responses 和 Anthropic Messages 接口。配置、密钥和历史仅保存在本机，不随应用备份或 WebDAV 同步。',
              ),
              const SizedBox(height: 20),
              for (final model in settings.models)
                Card(
                  child: ListTile(
                    leading: Icon(
                      settings.defaultModel?.id == model.id
                          ? Icons.star_rounded
                          : Icons.smart_toy_outlined,
                    ),
                    title: Text(model.name),
                    subtitle: Text(
                      model.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _saving ? null : () => _edit(model),
                    trailing: PopupMenuButton<String>(
                      enabled: !_saving,
                      onSelected: (action) {
                        if (action == 'delete') {
                          _delete(model);
                        } else {
                          _save(
                            AgentSettings(
                              models: settings.models,
                              defaultModelId: model.id,
                              confirmPolicy: settings.confirmPolicy,
                              autoBackupLimit: settings.autoBackupLimit,
                              manualBackupLimit: settings.manualBackupLimit,
                            ),
                          );
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'default', child: Text('设为默认模型')),
                        PopupMenuItem(value: 'delete', child: Text('删除模型')),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('agent-add-model'),
                onPressed: _saving ? null : () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('添加模型'),
              ),
              const SizedBox(height: 28),
              DropdownButtonFormField<String>(
                key: ValueKey(settings.confirmPolicy),
                initialValue: settings.confirmPolicy,
                decoration: const InputDecoration(
                  labelText: '写操作确认',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'never', child: Text('全自动执行（默认）')),
                  DropdownMenuItem(
                    value: 'destructive',
                    child: Text('删除和移动前确认'),
                  ),
                  DropdownMenuItem(value: 'all', child: Text('全部写操作前确认')),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        _save(
                          AgentSettings(
                            models: settings.models,
                            defaultModelId: settings.defaultModelId,
                            confirmPolicy: value,
                            autoBackupLimit: settings.autoBackupLimit,
                            manualBackupLimit: settings.manualBackupLimit,
                          ),
                        );
                      },
              ),
              const SizedBox(height: 12),
              const Text(
                'Agent 可以搜索漫画，管理收藏、稍后再看、阅读历史和下载等。删除收藏、稍后再看和历史后可以在工具卡片中撤销。',
              ),
              const SizedBox(height: 20),
              _SourceBackupsSection(
                AgentSourceBackups(
                  Directory('${widget.store.directory.path}/source_backups'),
                ),
                settings: settings,
                onChanged: _saving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentModelEditor extends StatefulWidget {
  final AgentStore store;
  final AgentModel? original;
  const _AgentModelEditor({required this.store, this.original});
  @override
  State<_AgentModelEditor> createState() => _AgentModelEditorState();
}

class _AgentModelEditorState extends State<_AgentModelEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  late bool _vision;
  late bool _reasoning;
  late bool _stream;
  late AgentProtocol _protocol;
  bool _pastingKey = false;
  bool _saving = false;
  String? _error;
  static const _encoder = JsonEncoder.withIndent('  ');
  List<AgentThinkingLevel> _levels = [];
  String? _defaultThinking;

  /// Enabled levels of a protocol with a native thinking field.
  late Set<String> _native;
  @override
  void initState() {
    super.initState();
    final model = widget.original;
    final values = {
      'name': model?.name ?? '',
      'url': model?.baseUrl ?? 'https://api.openai.com/v1',
      'model': model?.model ?? '',
      'key': widget.store.secrets[model?.id] ?? '',
      'thinking': _encoder.convert(
        model?.thinkingLevels.map((e) => e.toJson()).toList() ??
            [
              {'id': 'default', 'label': '默认', 'params': <String, dynamic>{}},
            ],
      ),
      'body': _encoder.convert(model?.extraBody ?? {}),
      'headers': _encoder.convert(model?.headers ?? {}),
      'context': agentFormatTokens(model?.contextWindowTokens ?? 128000),
      'temperature': model?.temperature?.toString() ?? '',
      'max_output': model?.maxOutputTokens == null
          ? ''
          : agentFormatTokens(model!.maxOutputTokens!),
    };
    for (final entry in values.entries) {
      _fields[entry.key] = TextEditingController(text: entry.value);
    }
    _vision = model?.supportsVision ?? false;
    _reasoning = model?.includeReasoning ?? false;
    _stream = model?.stream ?? true;
    _protocol = model?.protocol ?? AgentProtocol.chat;
    _defaultThinking = model?.defaultThinking ?? 'default';
    _native = {
      ...model == null || model.protocol == AgentProtocol.chat
          ? AgentThinkingLevel.nativeDefaults
          : model.thinkingLevels.map((e) => e.id),
    };
    _updateLevels();
    _fields['thinking']!.addListener(_thinkingChanged);
  }

  static const _defaultUrls = {
    AgentProtocol.chat: 'https://api.openai.com/v1',
    AgentProtocol.responses: 'https://api.openai.com/v1',
    AgentProtocol.messages: 'https://api.anthropic.com/v1',
  };

  void _selectProtocol(AgentProtocol protocol) {
    final url = _fields['url']!;
    // Only replace an untouched official address; never a custom gateway.
    if (url.text.trim() == _defaultUrls[_protocol]) {
      url.text = _defaultUrls[protocol]!;
    }
    setState(() {
      _protocol = protocol;
      _updateLevels();
    });
  }

  bool get _isNative => _protocol != AgentProtocol.chat;

  List<AgentThinkingLevel> get _nativeLevels => AgentThinkingLevel.native(
    _protocol,
  ).where((level) => _native.contains(level.id)).toList();

  void _toggleNative(String id, bool selected) {
    if (!selected && _nativeLevels.length == 1 && _native.contains(id)) return;
    setState(() {
      selected ? _native.add(id) : _native.remove(id);
      _updateLevels();
    });
  }

  List<AgentThinkingLevel> _readLevels() {
    if (_isNative) {
      final levels = _nativeLevels;
      if (levels.isEmpty) throw const FormatException('请至少选择一个思考深度');
      return levels;
    }
    try {
      final raw = jsonDecode(_value('thinking'));
      if (raw is! List) throw const FormatException();
      final levels = raw
          .map((e) => AgentThinkingLevel.fromJson(agentObject(e)))
          .toList();
      if (levels.isEmpty ||
          levels.any((e) => e.id.trim().isEmpty || e.label.trim().isEmpty) ||
          levels.map((e) => e.id).toSet().length != levels.length) {
        throw const FormatException();
      }
      return levels;
    } catch (_) {
      throw const FormatException('思考深度需要合法的 JSON 数组，每项包含唯一 ID、显示名称和参数对象');
    }
  }

  void _updateLevels() {
    if (_isNative && _nativeLevels.isEmpty) {
      _native = {...AgentThinkingLevel.nativeDefaults};
    }
    try {
      _levels = _readLevels();
      if (!_levels.any((level) => level.id == _defaultThinking)) {
        _defaultThinking = _levels.first.id;
      }
    } catch (_) {
      _levels = [];
    }
  }

  void _thinkingChanged() => setState(_updateLevels);

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  String _value(String key) => _fields[key]!.text.trim();
  AgentJson _object(String key, String label) {
    try {
      return agentObject(jsonDecode(_value(key)));
    } catch (_) {
      throw FormatException('$label 需要合法的 JSON 对象');
    }
  }

  Future<void> _pasteKey() async {
    if (_saving || _pastingKey) return;
    final field = _fields['key']!;
    final previousText = field.text;
    setState(() => _pastingKey = true);
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      // A delayed clipboard response must not replace a newer manual edit.
      if (field.text != previousText) return;
      if (text == null || text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪贴板中没有可粘贴的文本')));
        return;
      }
      field.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } catch (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取剪贴板，请长按输入框粘贴')));
      }
    } finally {
      if (mounted) setState(() => _pastingKey = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _pastingKey) return;
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final levels = _readLevels();
      final contextWindow = agentParseTokens(_value('context'));
      if (contextWindow == null) {
        throw const FormatException('上下文容量需要是正整数，可写作 128k');
      }
      final temperature = _value('temperature');
      if (temperature.isNotEmpty && double.tryParse(temperature) == null) {
        throw const FormatException('temperature 需要数字，或留空');
      }
      final maxOutput = _value('max_output');
      final maxOutputTokens = maxOutput.isEmpty
          ? null
          : agentParseTokens(maxOutput);
      if (maxOutput.isNotEmpty && maxOutputTokens == null) {
        throw const FormatException('最大输出 tokens 需要正整数（可写作 32k），或留空');
      }
      final model = AgentModel(
        id: widget.original?.id ?? agentId(),
        name: _value('name'),
        baseUrl: _value('url'),
        model: _value('model'),
        supportsVision: _vision,
        includeReasoning: _reasoning,
        stream: _stream,
        thinkingLevels: levels,
        defaultThinking: _defaultThinking!,
        extraBody: _object('body', '额外请求体'),
        headers: Map<String, String>.from(_object('headers', '请求头')),
        contextWindowTokens: contextWindow,
        temperature: temperature.isEmpty ? null : double.parse(temperature),
        protocol: _protocol,
        maxOutputTokens: maxOutputTokens,
      );
      model.validate();
      final old = widget.store.settings;
      final models = [...old.models];
      final index = models.indexWhere((m) => m.id == model.id);
      if (index < 0) {
        models.add(model);
      } else {
        models[index] = model;
      }
      await widget.store.saveSettings(
        AgentSettings(
          models: models,
          defaultModelId: old.defaultModelId ?? model.id,
          confirmPolicy: old.confirmPolicy,
          autoBackupLimit: old.autoBackupLimit,
          manualBackupLimit: old.manualBackupLimit,
        ),
        {...widget.store.secrets, model.id: _value('key')},
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is FormatException ? e.message : '配置无效或保存失败，请检查各项内容';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    int lines = 1,
    String? hint,
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('agent-model-$key'),
      controller: _fields[key],
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 5,
      autocorrect: false,
      // Android maps disabled suggestions to a visible-password input type.
      enableSuggestions: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      validator: required
          ? (text) => text?.trim().isEmpty != false ? '请填写此项' : null
          : null,
    ),
  );

  Widget _nativeThinking() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: '可选思考深度',
        border: const OutlineInputBorder(),
        helperText: _protocol == AgentProtocol.responses
            ? '通过 reasoning.effort 设置，并请求思考摘要；“默认”不发送该参数。可用档位以模型为准'
            : '通过自适应思考和 output_config.effort 设置，并显示思考摘要；“默认”不发送该参数。可用档位以模型为准',
        helperMaxLines: 3,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final level in AgentThinkingLevel.native(_protocol))
            FilterChip(
              key: ValueKey('agent-model-thinking-${level.id}'),
              label: Text(level.label),
              selected: _native.contains(level.id),
              onSelected: _saving
                  ? null
                  : (selected) => _toggleNative(level.id, selected),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.original == null ? '添加模型' : '编辑模型')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _field('name', '显示名称', required: true),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '接口协议',
                    border: OutlineInputBorder(),
                    helperText: '按服务商支持的接口选择，三者任选其一',
                    helperMaxLines: 2,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AgentProtocol>(
                      key: const ValueKey('agent-model-protocol'),
                      isExpanded: true,
                      isDense: true,
                      value: _protocol,
                      items: [
                        for (final protocol in AgentProtocol.values)
                          DropdownMenuItem(
                            value: protocol,
                            child: Text(protocol.label),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) _selectProtocol(value);
                            },
                    ),
                  ),
                ),
              ),
              _field(
                'url',
                'API 地址',
                required: true,
                hint:
                    '填写 /v1 基础地址或完整的 ${_protocol.path} 地址；'
                    '${_protocol == AgentProtocol.messages ? '使用 x-api-key 认证' : '使用 Bearer 认证'}',
              ),
              _field('model', '模型 ID', required: true, hint: '填写服务商提供的准确模型名称'),
              TextFormField(
                key: const ValueKey('agent-model-key'),
                controller: _fields['key'],
                keyboardType: TextInputType.text,
                autocorrect: false,
                enableSuggestions: true,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  helperText: '只保存在本机；无需密钥的本地服务可留空',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('agent-model-paste-key'),
                  onPressed: _saving || _pastingKey ? null : _pasteKey,
                  icon: _pastingKey
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.content_paste),
                  label: const Text('粘贴 API Key'),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('流式输出'),
                subtitle: const Text('服务不支持流式工具调用时可关闭'),
                value: _stream,
                onChanged: (v) => setState(() => _stream = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                key: const ValueKey('agent-model-vision'),
                title: const Text('模型支持视觉'),
                subtitle: const Text('启用图片输入；请确认所选模型和服务商接口支持识图'),
                value: _vision,
                onChanged: (v) => setState(() => _vision = v),
              ),
              // Anthropic signed thinking is always returned as required.
              if (_protocol != AgentProtocol.messages)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('将思考内容回传模型'),
                  subtitle: Text(
                    _protocol == AgentProtocol.chat
                        ? '仅对要求 reasoning_content 的服务开启'
                        : '请求加密推理内容并在工具调用之间回传，适用于推理模型',
                  ),
                  value: _reasoning,
                  onChanged: (v) => setState(() => _reasoning = v),
                ),
              const SizedBox(height: 16),
              if (_isNative)
                _nativeThinking()
              else
                _field(
                  'thinking',
                  '思考深度列表（JSON）',
                  lines: 4,
                  hint:
                      '每项包含 id、label 和 params；例如 params: {"reasoning_effort":"low"}，以服务商支持为准',
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: '默认思考深度',
                    border: const OutlineInputBorder(),
                    helperText: _levels.isEmpty
                        ? '请先填写有效的思考深度列表'
                        : '对话中可随时切换，选项来自上方思考深度',
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('agent-model-default'),
                      isExpanded: true,
                      isDense: true,
                      value: _levels.isEmpty ? null : _defaultThinking,
                      items: _levels
                          .map(
                            (level) => DropdownMenuItem(
                              value: level.id,
                              child: Text(level.label),
                            ),
                          )
                          .toList(),
                      onChanged: _levels.isEmpty || _saving
                          ? null
                          : (value) => setState(() => _defaultThinking = value),
                    ),
                  ),
                ),
              ),
              _field(
                'context',
                '模型上下文容量（tokens）',
                required: true,
                hint: '可写作 128k 或 1m（k = 1000）；达到90%时自动压缩，也可在对话中手动压缩',
              ),
              _field('temperature', 'temperature（可选，0–2）'),
              _field(
                'max_output',
                _protocol == AgentProtocol.messages
                    ? '最大输出 tokens（可选，默认 32k）'
                    : '最大输出 tokens（可选）',
                hint: _protocol == AgentProtocol.messages
                    ? '该协议必填，思考与回答共用此上限；可写作 32k 或 64k'
                    : '可写作 32k 等；留空时由服务商决定',
              ),
              ExpansionTile(
                title: const Text('高级请求配置'),
                children: [
                  _field(
                    'body',
                    '额外请求体（JSON）',
                    lines: 3,
                    hint: '可配置服务商参数；模型、消息、工具和 stream 由应用管理',
                  ),
                  _field(
                    'headers',
                    '自定义请求头（JSON）',
                    lines: 3,
                    hint: '字符串键值；和 API Key 一样仅保存在本机',
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving || _pastingKey ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(_saving ? '保存中…' : '保存模型'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Backups of source code made by the agent, so they cannot grow unnoticed.
class _SourceBackupsSection extends StatefulWidget {
  final AgentSourceBackups backups;
  final AgentSettings settings;
  final ValueChanged<AgentSettings>? onChanged;
  const _SourceBackupsSection(
    this.backups, {
    required this.settings,
    required this.onChanged,
  });
  @override
  State<_SourceBackupsSection> createState() => _SourceBackupsSectionState();
}

class _SourceBackupsSectionState extends State<_SourceBackupsSection> {
  List<AgentSourceBackup>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await widget.backups.list();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _delete(Iterable<AgentSourceBackup> items, String title) async {
    final list = items.toList();
    if (list.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text('将删除 ${list.length} 个备份，删除后无法用它们还原漫画源。'),
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
    if (confirmed != true) return;
    for (final item in list) {
      await widget.backups.delete(item.id);
    }
    await _load();
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  void _setLimits({int? automatic, int? manual}) {
    final s = widget.settings;
    widget.onChanged?.call(
      AgentSettings(
        models: s.models,
        defaultModelId: s.defaultModelId,
        confirmPolicy: s.confirmPolicy,
        autoBackupLimit: automatic ?? s.autoBackupLimit,
        manualBackupLimit: manual ?? s.manualBackupLimit,
      ),
    );
  }

  Widget _limit(
    String label,
    int value,
    List<int> options,
    ValueChanged<int> onChanged,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: DropdownButtonFormField<int>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final option in {...options, value}.toList()..sort())
          DropdownMenuItem(
            value: option,
            child: Text(option == 0 ? '不限' : '每个源 $option 个'),
          ),
      ],
      onChanged: widget.onChanged == null
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final settings = widget.settings;
    final total = items?.fold<int>(0, (sum, b) => sum + b.bytes) ?? 0;
    return Card(
      child: ExpansionTile(
        key: const ValueKey('agent-source-backups'),
        leading: const Icon(Icons.settings_backup_restore),
        title: const Text('漫画源代码备份'),
        subtitle: Text(
          items == null
              ? '读取中'
              : items.isEmpty
              ? 'Agent 修改或还原漫画源前会自动备份，目前没有备份'
              : '${items.length} 个，共 ${_size(total)}',
        ),
        children: [
          _limit(
            '自动备份上限（超出时删除最旧的自动备份）',
            settings.autoBackupLimit,
            const [3, 5, 10, 20, 50],
            (v) => _setLimits(automatic: v),
          ),
          _limit(
            '手动备份上限（不会自动删除，达到后 Agent 需先删旧备份）',
            settings.manualBackupLimit,
            const [0, 10, 20, 50, 100],
            (v) => _setLimits(manual: v),
          ),
          if (items != null && items.isNotEmpty) ...[
            for (final item in items)
              ListTile(
                dense: true,
                title: Text(item.sourceKey),
                subtitle: Text(
                  [
                    item.createdAt.toLocal().toString().substring(0, 19),
                    item.automatic ? '自动' : '手动',
                    _size(item.bytes),
                    if (item.note.isNotEmpty) item.note,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete([item], '删除备份？'),
                ),
              ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      _delete(items.where((b) => b.automatic), '删除全部自动备份？'),
                  child: const Text('删除自动备份'),
                ),
                TextButton(
                  onPressed: () => _delete(items, '删除全部备份？'),
                  child: const Text('全部删除'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
