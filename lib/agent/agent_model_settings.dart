part of 'agent_settings_page.dart';

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
  final _draftRevision = ValueNotifier<int>(0);
  late String _initialDraft;
  bool _allowLeave = false;
  bool _askingToLeave = false;
  late bool _vision;
  late bool _reasoning;
  late bool _stream;
  late bool _nativeWebSearch;
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
    _nativeWebSearch = model?.nativeWebSearch ?? false;
    _protocol = model?.protocol ?? AgentProtocol.chat;
    _defaultThinking = model?.defaultThinking ?? 'default';
    _native = {
      ...model == null || model.protocol == AgentProtocol.chat
          ? AgentThinkingLevel.nativeDefaults
          : model.thinkingLevels.map((e) => e.id),
    };
    _updateLevels();
    for (final field in _fields.values) {
      field.addListener(_draftChanged);
    }
    _initialDraft = _snapshot();
  }

  String _snapshot() => jsonEncode({
    'fields': {
      for (final field in _fields.entries) field.key: field.value.text,
    },
    'protocol': _protocol.id,
    'vision': _vision,
    'reasoning': _reasoning,
    'stream': _stream,
    'search': _nativeWebSearch,
    'defaultThinking': _defaultThinking,
    'levels': _native.toList()..sort(),
  });

  Future<void> _confirmLeave() async {
    if (_saving || _askingToLeave) return;
    _askingToLeave = true;
    try {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          content: const Text('本次模型配置尚未保存，可以返回继续编辑。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (discard == true && mounted) _leave();
    } finally {
      _askingToLeave = false;
    }
  }

  void _leave() {
    setState(() => _allowLeave = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
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
    _change(() {
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
    _change(() {
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

  void _draftChanged() => _change();

  void _change([VoidCallback? change]) {
    if (!mounted) return;
    setState(() {
      change?.call();
      _updateLevels();
    });
    _draftRevision.value++;
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.removeListener(_draftChanged);
      field.dispose();
    }
    _draftRevision.dispose();
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
        nativeWebSearch: _protocol.supportsNativeWebSearch && _nativeWebSearch,
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
        old.copyWith(
          models: models,
          defaultModelId: old.defaultModelId ?? model.id,
        ),
        {...widget.store.secrets, model.id: _value('key')},
      );
      if (mounted) _leave();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is FormatException ? e.message : '配置无效或保存失败，请检查各项内容';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error!)));
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
  }) => _agentField(
    fieldKey: ValueKey('agent-model-$key'),
    controller: _fields[key]!,
    label: label,
    lines: lines,
    hint: hint,
    required: required,
    enabled: !_saving,
    secret: key == 'key',
  );

  Future<void> _openSection(
    String title,
    List<Widget> Function() content,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: _draftRevision,
          builder: (context, _) => _AgentSettingsScaffold(
            title: title,
            footer: FilledButton.tonalIcon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded),
              label: const Text('完成配置'),
            ),
            children: [
              ...content(),
              const SizedBox(height: 12),
              const _AgentHelpText(
                '完成后返回编辑模型页，统一保存本次修改。',
                padding: EdgeInsets.symmetric(horizontal: 16),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  List<Widget> _capabilities() => [
    const _AgentSectionTitle('模型能力'),
    _AgentSettingsGroup(
      children: [
        SwitchListTile(
          key: const ValueKey('agent-model-native-search'),
          title: const Text('模型原生网络搜索'),
          subtitle: Text(
            _protocol.supportsNativeWebSearch
                ? '仅在模型服务商支持时可用。使用当前模型的 API Key，搜索可能单独计费。'
                : 'Chat Completions 不提供原生搜索，可在网络搜索设置中配置独立服务。',
          ),
          value: _protocol.supportsNativeWebSearch && _nativeWebSearch,
          onChanged: !_protocol.supportsNativeWebSearch
              ? null
              : (value) => _change(() => _nativeWebSearch = value),
        ),
        SwitchListTile(
          key: const ValueKey('agent-model-vision'),
          title: const Text('图片输入'),
          subtitle: const Text('仅在模型与服务商接口支持识图时开启'),
          value: _vision,
          onChanged: (value) => _change(() => _vision = value),
        ),
        SwitchListTile(
          key: const ValueKey('agent-model-stream'),
          title: const Text('流式输出'),
          subtitle: const Text('边生成边显示；服务不支持流式工具调用时可关闭'),
          value: _stream,
          onChanged: (value) => _change(() => _stream = value),
        ),
        if (_protocol != AgentProtocol.messages) ...[
          SwitchListTile(
            key: const ValueKey('agent-model-reasoning'),
            title: const Text('回传思考内容'),
            subtitle: Text(
              _protocol == AgentProtocol.chat
                  ? '仅对要求 reasoning_content 的服务开启'
                  : '在工具调用之间回传加密推理内容，适用于推理模型',
            ),
            value: _reasoning,
            onChanged: (value) => _change(() => _reasoning = value),
          ),
        ],
      ],
    ),
    const SizedBox(height: 8),
    const _AgentSectionTitle('生成参数'),
    _AgentSettingsGroup(
      padding: const EdgeInsets.all(16),
      children: [
        _field('temperature', 'Temperature', hint: '可选，范围 0–2。留空时使用服务商默认值。'),
        _field(
          'max_output',
          '最大输出 tokens',
          hint: _protocol == AgentProtocol.messages
              ? '默认 32k，思考与回答共用此上限。可写作 32k 或 64k。'
              : '可选，可写作 32k。留空时由服务商决定。',
        ),
      ],
    ),
  ];

  List<Widget> _thinkingSettings() => [
    if (_isNative) const _AgentSectionTitle('可选思考深度'),
    _AgentSettingsGroup(
      padding: const EdgeInsets.all(16),
      children: [
        if (_isNative) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final level in AgentThinkingLevel.native(_protocol))
                FilterChip(
                  key: ValueKey('agent-model-thinking-${level.id}'),
                  label: Text(level.label),
                  selected: _native.contains(level.id),
                  onSelected: (selected) => _toggleNative(level.id, selected),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const _AgentHelpText('只选用模型支持的档位。“默认”不发送思考参数，交由服务商决定。'),
          const SizedBox(height: 24),
        ] else
          _field(
            'thinking',
            '思考深度列表',
            lines: 4,
            hint: 'JSON 数组，每项包含 id、label 和 params；参数以服务商支持为准。',
          ),
        _AgentChoiceField<String>(
          key: const ValueKey('agent-model-default'),
          label: '默认思考深度',
          value: _levels.isEmpty ? null : _defaultThinking,
          options: [for (final level in _levels) (level.id, level.label)],
          hint: _levels.isEmpty ? '请先填写有效的思考深度列表' : '新对话的默认值，也可在对话中随时切换。',
          onChanged: _levels.isEmpty
              ? null
              : (value) => _change(() => _defaultThinking = value),
        ),
      ],
    ),
    const SizedBox(height: 24),
    _AgentSettingsGroup(
      padding: const EdgeInsets.all(16),
      children: [
        _field(
          'context',
          '上下文容量',
          required: true,
          hint: '单位为 tokens，可写作 128k 或 1m。达到 90% 时自动压缩，也可在对话中手动压缩。',
        ),
      ],
    ),
  ];

  List<Widget> _advanced() => [
    const _AgentHelpText('仅在服务商需要特殊参数时配置。', padding: EdgeInsets.all(16)),
    _AgentSettingsGroup(
      padding: const EdgeInsets.all(16),
      children: [
        _field(
          'body',
          '额外请求体',
          lines: 5,
          hint: 'JSON 对象。模型、消息、工具与 stream 由应用管理，其余参数按服务商文档配置。',
        ),
        _field(
          'headers',
          '自定义请求头',
          lines: 4,
          hint: 'JSON 对象，键和值均为字符串。与 API Key 一样仅保存在本机。',
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _allowLeave || (!_saving && _snapshot() == _initialDraft),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _confirmLeave();
    },
    child: Form(
      key: _form,
      child: _AgentSettingsScaffold(
        title: widget.original == null ? '添加模型' : '编辑模型',
        footer: FilledButton.icon(
          onPressed: _saving || _pastingKey ? null : _save,
          icon: const Icon(Icons.check_rounded),
          label: Text(_saving ? '保存中…' : '保存模型'),
        ),
        children: [
          const _AgentSectionTitle('连接信息'),
          _AgentSettingsGroup(
            padding: const EdgeInsets.all(16),
            children: [
              _field('name', '显示名称', required: true),
              _AgentChoiceField<AgentProtocol>(
                key: const ValueKey('agent-model-protocol'),
                label: '接口协议',
                value: _protocol,
                options: [
                  for (final protocol in AgentProtocol.values)
                    (protocol, protocol.label),
                ],
                hint: '选择模型服务商支持的接口。',
                onChanged: _saving ? null : _selectProtocol,
              ),
              const SizedBox(height: 20),
              _field(
                'url',
                'API 地址',
                required: true,
                hint: '填写 /v1 基础地址或完整的 ${_protocol.path} 地址。',
              ),
              _field('model', '模型 ID', required: true, hint: '填写服务商提供的准确模型名称。'),
              _field('key', 'API Key', hint: '只保存在本机；无需密钥的本地服务可留空。'),
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
                      : const Icon(Icons.content_paste_rounded),
                  label: const Text('粘贴 API Key'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _AgentSectionTitle('模型偏好'),
          _AgentSettingsGroup(
            children: [
              _AgentSettingsTile(
                key: const ValueKey('agent-model-capabilities'),
                icon: Icons.auto_awesome_outlined,
                title: '能力与输出',
                subtitle: [
                  if (_stream) '流式输出',
                  if (_vision) '图片输入',
                  if (_protocol.supportsNativeWebSearch && _nativeWebSearch)
                    '原生搜索',
                  '生成参数',
                ].join(' · '),
                onTap: _saving
                    ? null
                    : () => _openSection('能力与输出', _capabilities),
              ),
              _AgentSettingsTile(
                key: const ValueKey('agent-model-thinking-settings'),
                icon: Icons.psychology_outlined,
                title: '思考与上下文',
                subtitle:
                    '${_levels.where((level) => level.id == _defaultThinking).firstOrNull?.label ?? '待配置'} · ${_value('context')} tokens',
                onTap: _saving
                    ? null
                    : () => _openSection('思考与上下文', _thinkingSettings),
              ),
              _AgentSettingsTile(
                key: const ValueKey('agent-model-advanced'),
                icon: Icons.code_rounded,
                title: '高级请求配置',
                subtitle: '额外请求体与自定义请求头',
                onTap: _saving ? null : () => _openSection('高级请求配置', _advanced),
              ),
            ],
          ),
          if (_error != null) _AgentErrorText(_error!),
        ],
      ),
    ),
  );
}
