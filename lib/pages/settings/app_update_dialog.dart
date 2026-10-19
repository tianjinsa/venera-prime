part of 'settings_page.dart';

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.release});
  final LatestRelease release;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  bool _busy = false;
  bool _selecting = true;
  ReleaseAsset? _asset;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectAsset();
  }

  Future<void> _selectAsset() async {
    try {
      if (App.isAndroid) {
        final abis = await AndroidAppUpdater.supportedAbis();
        if (mounted) _asset = widget.release.androidAsset(abis);
      }
    } catch (error, stack) {
      Log.error('App update', error, stack);
      if (mounted) _error = 'Failed to prepare update'.tl;
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _update() async {
    if (_busy) return;
    final asset = _asset;
    if (asset == null) {
      await launchUrlString(widget.release.url);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final task = await AppUpdateService.instance.startDownload(
        widget.release,
        asset,
      );
      if (!mounted) return;
      Navigator.pop(context);
      final message = switch (task.status) {
        BackgroundTaskStatus.failed =>
          task.message.isNotEmpty ? task.message : 'Update failed'.tl,
        BackgroundTaskStatus.cancelled => 'Cancelled'.tl,
        BackgroundTaskStatus.completed
            when AppUpdateService.instance.readyFile != null =>
          'Update downloaded. Tap Install in Background tasks.'.tl,
        _ =>
          'Update is downloading in background. View progress in Background tasks.'
              .tl,
      };
      App.rootContext.showMessage(message: message);
    } catch (error, stack) {
      Log.error('App update', error, stack);
      if (mounted) setState(() => _error = '${'Update failed'.tl}\n$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    title: '${widget.release.title} (${widget.release.version})',
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('A new version is available. Do you want to update now?'.tl),
          if (_asset != null)
            Text('Download in background, then tap the task to install.'.tl),
          if (widget.release.body.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(widget.release.body),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              _error!,
              style: TextStyle(color: context.colorScheme.error),
            ),
          ],
        ],
      ).paddingHorizontal(16),
    ),
    actions: [
      Button.text(
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'.tl),
      ),
      FilledButton(
        onPressed: _busy || _selecting ? null : _update,
        child: Text(_asset != null ? 'Update'.tl : 'Open release page'.tl),
      ),
    ],
  );
}
