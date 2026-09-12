import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'agent_files.dart';
import 'agent_image_view.dart';
import 'agent_models.dart';

typedef AgentMessageTextFileLoader =
    Uint8List? Function(AgentMessage message, AgentTextAttachment file);

class AgentAttachmentStrip extends StatelessWidget {
  final List<AgentImageAttachment> images;
  final List<AgentTextAttachment> files;
  final Uint8List? Function(AgentImageAttachment) readImage;
  final Uint8List? Function(AgentTextAttachment) readFile;
  final void Function(AgentImageAttachment)? onRemoveImage;
  final void Function(AgentTextAttachment)? onRemoveFile;
  const AgentAttachmentStrip({
    super.key,
    this.images = const [],
    this.files = const [],
    required this.readImage,
    required this.readFile,
    this.onRemoveImage,
    this.onRemoveFile,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: onRemoveImage == null && onRemoveFile == null ? 122 : 116,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: images.length + files.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, index) {
        if (index < images.length) {
          final image = images[index];
          return AgentImageTile(
            key: ValueKey('image-${image.id}'),
            image: image,
            readImage: () => readImage(image),
            onRemove: onRemoveImage == null
                ? null
                : () => onRemoveImage!(image),
          );
        }
        final file = files[index - images.length];
        return _AgentTextFileTile(
          key: ValueKey('file-${file.id}'),
          file: file,
          readFile: () => readFile(file),
          onRemove: onRemoveFile == null ? null : () => onRemoveFile!(file),
        );
      },
    ),
  );
}

class _AgentTextFileTile extends StatelessWidget {
  final AgentTextAttachment file;
  final Uint8List? Function() readFile;
  final VoidCallback? onRemove;
  const _AgentTextFileTile({
    super.key,
    required this.file,
    required this.readFile,
    this.onRemove,
  });

  Future<void> _preview(BuildContext context) async {
    try {
      final bytes = readFile();
      if (bytes == null) {
        throw AgentException('FILE_MISSING', '文件“${file.name}”无法读取，请重新添加');
      }
      final text = decodeAgentTextFile(bytes, encoding: file.encoding);
      await showDialog<void>(
        context: context,
        builder: (_) => _AgentTextFilePreview(file: file, text: text),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is AgentException ? error.message : '文件无法读取，请重新添加',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 160,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Material(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _preview(context),
                      child: Semantics(
                        label: '查看文件 ${file.name}',
                        button: true,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.description_outlined, size: 30),
                              const SizedBox(height: 6),
                              Text(
                                agentFormatBytes(file.byteLength),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (onRemove != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton.filledTonal(
                      key: ValueKey('remove-file-${file.id}'),
                      tooltip: '移除文件',
                      onPressed: onRemove,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Tooltip(
            message: '${file.name} · ${agentFormatBytes(file.byteLength)}',
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTextFilePreview extends StatefulWidget {
  final AgentTextAttachment file;
  final String text;
  const _AgentTextFilePreview({required this.file, required this.text});

  @override
  State<_AgentTextFilePreview> createState() => _AgentTextFilePreviewState();
}

class _AgentTextFilePreviewState extends State<_AgentTextFilePreview> {
  final _scroll = ScrollController();
  final _boundaries = <int>[0];

  @override
  void initState() {
    super.initState();
    final text = widget.text;
    // Lay out long files in bounded chunks as they scroll into view. Keep the
    // complete source text and avoid splitting CRLF or a UTF-16 surrogate pair.
    while (_boundaries.last < text.length) {
      final start = _boundaries.last;
      var end = math.min(start + 4096, text.length);
      if (end < text.length) {
        final lineEnd = text.lastIndexOf('\n', end - 1);
        if (lineEnd >= start + 2048) end = lineEnd + 1;
        final next = text.codeUnitAt(end);
        final previous = text.codeUnitAt(end - 1);
        if (previous == 13 && next == 10 ||
            previous >= 0xd800 &&
                previous <= 0xdbff &&
                next >= 0xdc00 &&
                next <= 0xdfff) {
          end--;
        }
      }
      _boundaries.add(end);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 880),
      child: Column(
        children: [
          ListTile(
            title: Text(
              widget.file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(agentFormatBytes(widget.file.byteLength)),
            trailing: IconButton(
              tooltip: '关闭文件',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.text.isEmpty
                ? const Center(child: Text('文件为空'))
                : SelectionArea(
                    child: Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: _boundaries.length - 1,
                        itemBuilder: (_, index) {
                          var end = _boundaries[index + 1];
                          // The next Text begins on a new line already. Avoid
                          // rendering an extra blank line at chunk boundaries.
                          if (end < widget.text.length &&
                              widget.text.codeUnitAt(end - 1) == 10) {
                            end--;
                            if (end > _boundaries[index] &&
                                widget.text.codeUnitAt(end - 1) == 13) {
                              end--;
                            }
                          }
                          return Text(
                            widget.text.substring(_boundaries[index], end),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}
