part of 'agent_settings_page.dart';

class _AgentBackupSettingsPage extends StatefulWidget {
  final AgentStore store;
  const _AgentBackupSettingsPage({required this.store});
  @override
  State<_AgentBackupSettingsPage> createState() =>
      _AgentBackupSettingsPageState();
}

class _AgentBackupSettingsPageState extends State<_AgentBackupSettingsPage>
    with _AgentSettingsSaver<_AgentBackupSettingsPage> {
  @override
  AgentStore get store => widget.store;
  late final _backups = AgentSourceBackups(
    Directory('${store.directory.path}/source_backups'),
  );
  List<AgentSourceBackup>? _items;
  String? _loadError;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _backups.list();
      if (mounted) {
        setState(() {
          _items = items;
          _loadError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadError = '无法读取备份，请稍后重试');
    }
  }

  Future<void> _delete(Iterable<AgentSourceBackup> items) async {
    final list = items.toList();
    if (list.isEmpty || _deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除备份？'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      for (final item in list) {
        await _backups.delete(item.id);
      }
      await _load();
    } catch (_) {
      if (mounted) setState(() => _loadError = '部分备份未能删除，请刷新后重试');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final settings = store.settings;
    final items = _items;
    return _AgentSettingsScaffold(
      title: '源代码备份',
      children: [
        const _AgentHelpText(
          'Agent 修改或还原漫画源前会自动备份。手动备份单独保留，便于找回需要的版本。',
          padding: EdgeInsets.all(16),
        ),
        const _AgentSectionTitle('保留数量'),
        _AgentSettingsGroup(
          padding: const EdgeInsets.all(16),
          children: [
            _AgentChoiceField<int>(
              key: const ValueKey('agent-backup-auto-limit'),
              label: '自动备份上限',
              hint: '每个漫画源分别计数，超出上限时删除最旧的自动备份。',
              value: settings.autoBackupLimit,
              options: [
                for (final value in ({
                  3,
                  5,
                  10,
                  20,
                  50,
                  settings.autoBackupLimit,
                }.toList()..sort()))
                  (value, '每个源 $value 个'),
              ],
              onChanged: _saving
                  ? null
                  : (value) => _saveSettings(
                      store.settings.copyWith(autoBackupLimit: value),
                    ),
            ),
            const SizedBox(height: 24),
            _AgentChoiceField<int>(
              key: const ValueKey('agent-backup-manual-limit'),
              label: '手动备份上限',
              hint: '不会自动删除。达到上限后，需先删除旧备份再创建新的备份。',
              value: settings.manualBackupLimit,
              options: [
                for (final value in ({
                  0,
                  10,
                  20,
                  50,
                  100,
                  settings.manualBackupLimit,
                }.toList()..sort()))
                  (value, value == 0 ? '不限' : '每个源 $value 个'),
              ],
              onChanged: _saving
                  ? null
                  : (value) => _saveSettings(
                      store.settings.copyWith(manualBackupLimit: value),
                    ),
            ),
          ],
        ),
        if (_saveError != null) _AgentErrorText(_saveError!),
        const SizedBox(height: 8),
        _AgentSectionTitle(items == null ? '备份记录' : '备份记录 · ${items.length} 个'),
        if (_loadError != null) ...[
          _AgentErrorText(_loadError!),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重新读取'),
          ),
        ] else if (items == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (items.isEmpty)
          const _AgentEmptyState(
            icon: Icons.restore_rounded,
            title: '还没有备份',
            message: 'Agent 修改漫画源或创建备份后，会显示在这里。',
          )
        else ...[
          _AgentSettingsGroup(
            children: [
              for (final item in items) ...[
                ListTile(
                  title: Text(item.sourceKey),
                  subtitle: Text(
                    [
                      item.createdAt.toLocal().toString().substring(0, 19),
                      '${item.automatic ? '自动' : '手动'} · ${_size(item.bytes)}',
                      if (item.note.isNotEmpty) item.note,
                    ].join('\n'),
                  ),
                  trailing: IconButton(
                    tooltip: '删除备份',
                    onPressed: _deleting ? null : () => _delete([item]),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _deleting || !items.any((item) => item.automatic)
                    ? null
                    : () => _delete(items.where((item) => item.automatic)),
                child: const Text('删除自动备份'),
              ),
              TextButton(
                onPressed: _deleting ? null : () => _delete(items),
                child: const Text('全部删除'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
