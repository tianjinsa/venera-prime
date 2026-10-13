part of 'comic_source_page.dart';

String _sourceCheckStageLabel(SourceCheckStage stage) => stage.label;

class _SourceCheckTile extends StatelessWidget {
  const _SourceCheckTile({required this.source});
  final ComicSource source;

  @override
  Widget build(BuildContext context) {
    final manager = SourceCheckManager.instance;
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final result = manager.resultFor(source);
        final checking = manager.isChecking(source.key);
        return ListTile(
          title: Text('Check readability'.tl),
          subtitle: Text(
            checking
                ? 'Checking readability…'.tl
                : result == null
                ? 'Not checked'.tl
                : result.readable
                ? 'Readable'.tl
                : 'Check failed at @stage'.tlParams({
                    'stage': _sourceCheckStageLabel(result.stage),
                  }),
          ),
          leading: checking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  result == null
                      ? Icons.help_outline
                      : result.readable
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                ),
          trailing: TextButton(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => _SourceCheckDialog(source: source),
            ),
            child: Text('Check'.tl),
          ),
        );
      },
    );
  }
}

class _SourceCheckDialog extends StatefulWidget {
  const _SourceCheckDialog({required this.source});
  final ComicSource source;

  @override
  State<_SourceCheckDialog> createState() => _SourceCheckDialogState();
}

class _SourceCheckDialogState extends State<_SourceCheckDialog> {
  final _id = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (SourceCheckManager.instance.resultFor(widget.source) == null) {
      unawaited(SourceCheckManager.instance.check(widget.source));
    }
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final manager = SourceCheckManager.instance;
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final result = manager.resultFor(source);
        final checking = manager.isChecking(source.key);
        return AlertDialog(
          title: Text('${'Check readability'.tl} · ${source.name}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Checks a sample comic, its chapter and an image using your current source settings.'
                        .tl,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _id,
                    enabled: !checking,
                    decoration: InputDecoration(
                      labelText: 'Comic ID (optional)'.tl,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (checking) ...[
                    const LinearProgressIndicator(),
                    Text('Checking readability…'.tl),
                    if (manager.stageFor(source.key) case final stage?)
                      Text(_sourceCheckStageLabel(stage)),
                  ] else if (result != null) ...[
                    Text(
                      result.readable
                          ? 'Readable'.tl
                          : 'Check failed at @stage'.tlParams({
                              'stage': _sourceCheckStageLabel(result.stage),
                            }),
                    ),
                    if (result.comic != null) Text(result.comic!.title),
                    if (result.error != null) SelectableText(result.error!),
                    if (result.readable)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Image(
                          height: 200,
                          image: ReaderImageProvider(
                            result.imageKey!,
                            source.key,
                            result.comic!.id,
                            result.episode ?? '0',
                            1,
                          ),
                          errorBuilder: (_, error, _) => Text(error.toString()),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(checking ? 'Continue in background'.tl : 'Close'.tl),
            ),
            FilledButton(
              onPressed: checking
                  ? null
                  : () {
                      unawaited(manager.check(source, comicId: _id.text));
                    },
              child: Text('Check again'.tl),
            ),
          ],
        );
      },
    );
  }
}
