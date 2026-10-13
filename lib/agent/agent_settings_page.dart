import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart' show Appbar;
import 'agent_models.dart';
import 'agent_source_backups.dart';
import 'agent_store.dart';

part 'agent_settings_widgets.dart';
part 'agent_model_settings.dart';
part 'agent_search_settings.dart';
part 'agent_backup_settings.dart';

mixin _AgentSettingsSaver<T extends StatefulWidget> on State<T> {
  AgentStore get store;
  bool _saving = false;
  String? _saveError;

  Future<bool> _saveSettings(
    AgentSettings settings, {
    Map<String, String> keys = const {},
  }) async {
    if (_saving) return false;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await store.saveSettings(settings, keys);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => _saveError = '保存失败，请检查数据目录是否可写后重试');
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class AgentSettingsPage extends StatefulWidget {
  final AgentStore store;
  const AgentSettingsPage({super.key, required this.store});
  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage>
    with _AgentSettingsSaver<AgentSettingsPage> {
  @override
  AgentStore get store => widget.store;

  Future<void> _open(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = store.settings;
    final engines = settings.webSearch.engines;
    return _AgentSettingsScaffold(
      title: 'Agent 设置',
      children: [
        const _AgentSectionTitle('配置与管理'),
        _AgentSettingsGroup(
          children: [
            _AgentSettingsTile(
              key: const ValueKey('agent-settings-models'),
              icon: Icons.tune_rounded,
              title: '模型管理',
              subtitle: settings.models.isEmpty
                  ? '添加模型，开始对话'
                  : '${settings.models.length} 个模型 · 默认 ${settings.defaultModel?.name ?? '未设置'}',
              onTap: _saving
                  ? null
                  : () => _open(AgentModelsPage(store: store)),
            ),
            _AgentSettingsTile(
              key: const ValueKey('agent-settings-search'),
              icon: Icons.travel_explore_rounded,
              title: '网络搜索',
              subtitle: engines.isEmpty
                  ? '管理搜索服务与模型原生搜索'
                  : '已启用 ${engines.map((e) => e.label).join('、')}',
              onTap: _saving
                  ? null
                  : () => _open(_AgentSearchSettingsPage(store: store)),
            ),
            _AgentSettingsTile(
              key: const ValueKey('agent-source-backups'),
              icon: Icons.restore_rounded,
              title: '源代码备份',
              subtitle: '管理漫画源备份与保留数量',
              onTap: _saving
                  ? null
                  : () => _open(_AgentBackupSettingsPage(store: store)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _AgentSectionTitle('操作偏好'),
        _AgentSettingsGroup(
          padding: const EdgeInsets.all(16),
          children: [
            _AgentChoiceField<String>(
              key: const ValueKey('agent-confirm-policy'),
              label: '写操作确认',
              value: settings.confirmPolicy,
              options: const [
                ('never', '全自动执行（默认）'),
                ('destructive', '删除和移动前确认'),
                ('all', '全部写操作前确认'),
              ],
              onChanged: _saving
                  ? null
                  : (value) =>
                        _saveSettings(settings.copyWith(confirmPolicy: value)),
            ),
            const SizedBox(height: 12),
            const _AgentHelpText(
              'Agent 可以管理收藏、稍后再看、阅读历史和下载。删除收藏、稍后再看或历史后，可在工具卡片中撤销。',
            ),
          ],
        ),
        if (_saveError != null) _AgentErrorText(_saveError!),
        const SizedBox(height: 24),
        const _AgentHelpText(
          '模型配置、密钥和对话历史仅保存在本机，不随应用备份或 WebDAV 同步。',
          padding: EdgeInsets.symmetric(horizontal: 16),
        ),
      ],
    );
  }
}

class AgentModelsPage extends StatefulWidget {
  final AgentStore store;
  const AgentModelsPage({super.key, required this.store});
  @override
  State<AgentModelsPage> createState() => _AgentModelsPageState();
}

class _AgentModelsPageState extends State<AgentModelsPage>
    with _AgentSettingsSaver<AgentModelsPage> {
  @override
  AgentStore get store => widget.store;

  Future<void> _edit([AgentModel? model]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AgentModelEditor(store: store, original: model),
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
    if (confirm != true || !mounted) return;
    final settings = store.settings;
    final models = settings.models.where((m) => m.id != model.id).toList();
    await _saveSettings(
      settings.copyWith(
        models: models,
        defaultModelId: settings.defaultModelId == model.id
            ? (models.isEmpty ? null : models.first.id)
            : settings.defaultModelId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = store.settings;
    return _AgentSettingsScaffold(
      title: '模型管理',
      footer: FilledButton.icon(
        key: const ValueKey('agent-add-model'),
        onPressed: _saving ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('添加模型'),
      ),
      children: [
        const _AgentHelpText(
          '连接自己的模型服务，分别配置能力与思考深度。默认模型用于新对话。',
          padding: EdgeInsets.all(16),
        ),
        if (settings.models.isEmpty)
          const _AgentEmptyState(
            icon: Icons.auto_awesome_outlined,
            title: '还没有模型',
            message: '添加一个模型，连接你的服务商或本地服务。',
          )
        else
          _AgentSettingsGroup(
            children: [
              for (final model in settings.models) ...[
                _AgentSettingsTile(
                  key: ValueKey('agent-managed-model-${model.id}'),
                  icon: settings.defaultModel?.id == model.id
                      ? Icons.star_outline_rounded
                      : Icons.auto_awesome_outlined,
                  title: model.name,
                  subtitle:
                      '${model.model}${settings.defaultModel?.id == model.id ? ' · 默认模型' : ''}',
                  onTap: _saving ? null : () => _edit(model),
                  trailing: PopupMenuButton<String>(
                    tooltip: '管理 ${model.name}',
                    enabled: !_saving,
                    onSelected: (action) {
                      if (action == 'delete') {
                        _delete(model);
                      } else {
                        _saveSettings(
                          store.settings.copyWith(defaultModelId: model.id),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'default', child: Text('设为默认模型')),
                      PopupMenuItem(value: 'delete', child: Text('删除模型')),
                    ],
                  ),
                ),
              ],
            ],
          ),
        if (_saveError != null) _AgentErrorText(_saveError!),
      ],
    );
  }
}
