part of 'agent_settings_page.dart';

IconData _searchIcon(AgentSearchEngine engine) => switch (engine) {
  AgentSearchEngine.bing => Icons.public_rounded,
  AgentSearchEngine.google => Icons.language_rounded,
  AgentSearchEngine.tavily => Icons.manage_search_rounded,
  AgentSearchEngine.deepseek => Icons.travel_explore_rounded,
};

String _searchDescription(AgentSearchEngine engine) => switch (engine) {
  AgentSearchEngine.bing => '搜索 Bing 网页，无需 API Key',
  AgentSearchEngine.google => '搜索 Google 网页，无需 API Key',
  AgentSearchEngine.tavily => '使用搜索 API，需要独立密钥',
  AgentSearchEngine.deepseek => '独立调用搜索模型，需要单独配置',
};

class _AgentSearchSettingsPage extends StatefulWidget {
  final AgentStore store;
  const _AgentSearchSettingsPage({required this.store});
  @override
  State<_AgentSearchSettingsPage> createState() =>
      _AgentSearchSettingsPageState();
}

class _AgentSearchSettingsPageState extends State<_AgentSearchSettingsPage> {
  Future<void> _open(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.store.settings;
    final nativeCount = settings.models
        .where(
          (model) =>
              model.nativeWebSearch && model.protocol.supportsNativeWebSearch,
        )
        .length;
    return _AgentSettingsScaffold(
      title: '网络搜索',
      children: [
        const _AgentHelpText(
          '选择 Agent 可以使用的搜索来源。只有对话需要联网并调用搜索时，才会发送搜索词。',
          padding: EdgeInsets.all(16),
        ),
        const _AgentSectionTitle('搜索服务'),
        _AgentSettingsGroup(
          children: [
            for (final engine in AgentSearchEngine.values) ...[
              _AgentSettingsTile(
                key: ValueKey('agent-search-provider-${engine.name}'),
                icon: _searchIcon(engine),
                title: engine.label,
                subtitle:
                    '${settings.webSearch.enabled(engine) ? '已启用' : '未启用'} · ${_searchDescription(engine)}',
                onTap: () => _open(
                  _AgentSearchProviderPage(store: widget.store, engine: engine),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const _AgentSectionTitle('跟随模型'),
        _AgentSettingsGroup(
          children: [
            _AgentSettingsTile(
              key: const ValueKey('agent-search-native-models'),
              icon: Icons.auto_awesome_outlined,
              title: '模型原生搜索',
              subtitle: nativeCount == 0
                  ? '在模型的能力设置中启用'
                  : '$nativeCount 个模型已启用',
              onTap: () => _open(AgentModelsPage(store: widget.store)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const _AgentHelpText(
          '仅在模型服务商支持时可用，使用该模型的 API Key。与上面的独立搜索服务分别配置。',
          padding: EdgeInsets.symmetric(horizontal: 16),
        ),
      ],
    );
  }
}

class _AgentSearchProviderPage extends StatefulWidget {
  final AgentStore store;
  final AgentSearchEngine engine;
  const _AgentSearchProviderPage({required this.store, required this.engine});
  @override
  State<_AgentSearchProviderPage> createState() =>
      _AgentSearchProviderPageState();
}

class _AgentSearchProviderPageState extends State<_AgentSearchProviderPage>
    with _AgentSettingsSaver<_AgentSearchProviderPage> {
  @override
  AgentStore get store => widget.store;
  final _form = GlobalKey<FormState>();
  late bool _enabled = store.settings.webSearch.enabled(widget.engine);
  bool _pasting = false;
  String? _error;
  bool get _needsKey =>
      widget.engine == AgentSearchEngine.tavily ||
      widget.engine == AgentSearchEngine.deepseek;
  bool get _deepseek => widget.engine == AgentSearchEngine.deepseek;
  String get _secretId => _deepseek
      ? AgentWebSearchSettings.deepseekSecretId
      : AgentWebSearchSettings.tavilySecretId;
  late final _key = TextEditingController(
    text: _needsKey ? store.secrets[_secretId] ?? '' : '',
  );
  late final _url = TextEditingController(
    text: store.settings.webSearch.deepseekBaseUrl,
  );
  late final _model = TextEditingController(
    text: store.settings.webSearch.deepseekModel,
  );

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (_pasting || _saving) return;
    final previous = _key.text;
    setState(() {
      _pasting = true;
      _error = null;
    });
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted || ModalRoute.of(context)?.isCurrent != true || !_enabled) {
        return;
      }
      if (_key.text != previous) return;
      if (text == null || text.trim().isEmpty) {
        setState(() => _error = '剪贴板中没有可粘贴的文本');
        return;
      }
      _key.value = TextEditingValue(
        text: text.trim(),
        selection: TextSelection.collapsed(offset: text.trim().length),
      );
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取剪贴板，请长按输入框粘贴');
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _pasting || !_form.currentState!.validate()) return;
    setState(() => _error = null);
    final settings = store.settings;
    var search = settings.webSearch.withEngine(widget.engine, _enabled);
    if (_enabled && _deepseek) {
      search = search.withDeepseek(
        baseUrl: _url.text.trim(),
        model: _model.text.trim(),
        enabled: true,
      );
      try {
        search.deepseekSearchModel.validate();
      } on FormatException catch (error) {
        setState(() => _error = error.message);
        return;
      }
    }
    final saved = await _saveSettings(
      settings.copyWith(webSearch: search),
      // Disabling a service retains its saved key for the next use. Hidden
      // fields cannot silently erase or overwrite credentials.
      keys: _enabled && _needsKey ? {_secretId: _key.text.trim()} : const {},
    );
    if (saved && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: _AgentSettingsScaffold(
      title: '${widget.engine.label} 搜索',
      footer: FilledButton.icon(
        key: ValueKey(
          _deepseek
              ? 'agent-deepseek-save'
              : widget.engine == AgentSearchEngine.tavily
              ? 'agent-tavily-save-key'
              : 'agent-${widget.engine.name}-save',
        ),
        onPressed: _saving || _pasting ? null : _save,
        icon: const Icon(Icons.check_rounded),
        label: Text(_saving ? '保存中…' : '保存设置'),
      ),
      children: [
        _AgentSettingsGroup(
          children: [
            SwitchListTile(
              key: ValueKey('agent-search-${widget.engine.name}'),
              title: Text('启用 ${widget.engine.label}'),
              subtitle: Text(_searchDescription(widget.engine)),
              value: _enabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _enabled = value;
                      _error = null;
                    }),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (!_enabled)
          _AgentHelpText(
            _needsKey
                ? '启用后可填写 API Key${_deepseek ? '与搜索模型' : ''}。关闭服务会保留已保存的配置。'
                : '启用后，Agent 可在需要时使用此服务搜索网页。',
            padding: const EdgeInsets.symmetric(horizontal: 16),
          )
        else if (_needsKey) ...[
          const _AgentSectionTitle('连接配置'),
          _AgentSettingsGroup(
            padding: const EdgeInsets.all(16),
            children: [
              _agentField(
                fieldKey: ValueKey(
                  _deepseek ? 'agent-deepseek-key' : 'agent-tavily-key-input',
                ),
                label: 'API Key',
                controller: _key,
                required: true,
                secret: true,
                enabled: !_saving,
                hint: '仅保存在本机，按服务账户的额度或 API 用量计费。',
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: ValueKey('agent-${widget.engine.name}-paste-key'),
                  onPressed: _saving || _pasting ? null : _paste,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: const Text('粘贴 API Key'),
                ),
              ),
              if (_deepseek) ...[
                const SizedBox(height: 12),
                _agentField(
                  fieldKey: const ValueKey('agent-deepseek-url'),
                  label: 'API 地址',
                  controller: _url,
                  required: true,
                  enabled: !_saving,
                  hint: '填写服务的 Messages 基础地址或完整接口地址。',
                ),
                _agentField(
                  fieldKey: const ValueKey('agent-deepseek-model'),
                  label: '搜索模型',
                  controller: _model,
                  required: true,
                  enabled: !_saving,
                  hint: '此模型专门用于搜索，可与当前聊天模型不同。',
                ),
              ],
            ],
          ),
        ] else
          const _AgentHelpText(
            '网页服务可能要求验证或限制请求；遇到此类情况，可选择其他已启用的搜索服务。',
            padding: EdgeInsets.symmetric(horizontal: 16),
          ),
        if (_error != null) _AgentErrorText(_error!),
        if (_saveError != null) _AgentErrorText(_saveError!),
      ],
    ),
  );
}
