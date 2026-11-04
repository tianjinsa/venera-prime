import 'package:flutter/material.dart';
import 'agent_model_discovery.dart';
import 'agent_models.dart';

class AgentModelPicker extends StatefulWidget {
  final AgentModel connection;
  final String apiKey;
  final String selectedId;
  final AgentModelDiscovery Function()? discoveryFactory;
  const AgentModelPicker({
    super.key,
    required this.connection,
    required this.apiKey,
    required this.selectedId,
    this.discoveryFactory,
  });
  @override
  State<AgentModelPicker> createState() => _AgentModelPickerState();
}

class _AgentModelPickerState extends State<AgentModelPicker> {
  late final _discovery =
      widget.discoveryFactory?.call() ?? AgentModelDiscovery();
  final _search = TextEditingController();
  AgentRun? _run;
  List<AgentProviderModel>? _models;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _run?.cancel();
    final run = AgentRun();
    _run = run;
    setState(() {
      _models = null;
      _error = null;
    });
    try {
      final models = await _discovery.fetch(
        connection: widget.connection,
        apiKey: widget.apiKey,
        run: run,
      );
      if (mounted && !run.isCancelled) setState(() => _models = models);
    } catch (e) {
      if (mounted && !run.isCancelled) {
        setState(
          () => _error = e is AgentException
              ? e.message
              : '获取失败，请检查连接配置或手动填写模型 ID',
        );
      }
    }
  }

  @override
  void dispose() {
    _run?.cancel();
    _discovery.close();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final models = _models
        ?.where(
          (m) =>
              m.id.toLowerCase().contains(query) ||
              (m.name?.toLowerCase().contains(query) ?? false),
        )
        .toList();
    return AlertDialog(
      title: const Text('选择服务商模型'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (constraints.maxHeight > 220) ...[
                Text(
                  widget.connection.endpoint.host,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('agent-model-list-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '搜索名称或模型 ID',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _error != null
                    ? Center(child: SingleChildScrollView(child: Text(_error!)))
                    : models == null
                    ? const Center(child: CircularProgressIndicator())
                    : models.isEmpty
                    ? Center(
                        child: Text(
                          _models!.isEmpty
                              ? '服务未返回模型，可关闭后手动填写模型 ID'
                              : '没有匹配的模型',
                        ),
                      )
                    : ListView.builder(
                        itemCount: models.length,
                        itemBuilder: (context, index) {
                          final model = models[index];
                          return ListTile(
                            title: Text(model.name ?? model.id),
                            subtitle: model.name == null
                                ? null
                                : Text(model.id),
                            selected: model.id == widget.selectedId,
                            trailing: model.id == widget.selectedId
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.pop(context, model),
                          );
                        },
                      ),
              ),
              if (_models != null && constraints.maxHeight > 220)
                Text(
                  '共 ${_models!.length} 个模型 · 能力与上下文请按服务商说明配置',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: _load, child: const Text('重试')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
