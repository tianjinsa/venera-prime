import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'agent_models.dart';

typedef AgentMessageImageLoader =
    Uint8List? Function(AgentMessage message, AgentImageAttachment image);

class AgentImageStrip extends StatelessWidget {
  final List<AgentImageAttachment> images;
  final Uint8List? Function(AgentImageAttachment) readImage;
  final void Function(AgentImageAttachment)? onRemove;
  const AgentImageStrip({
    super.key,
    required this.images,
    required this.readImage,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: onRemove == null ? 122 : 116,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: images.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, index) => _AgentImageTile(
        key: ValueKey('image-${images[index].id}'),
        image: images[index],
        readImage: () => readImage(images[index]),
        onRemove: onRemove == null ? null : () => onRemove!(images[index]),
      ),
    ),
  );
}

class _AgentImageTile extends StatefulWidget {
  final AgentImageAttachment image;
  final Uint8List? Function() readImage;
  final VoidCallback? onRemove;
  const _AgentImageTile({
    super.key,
    required this.image,
    required this.readImage,
    this.onRemove,
  });
  @override
  State<_AgentImageTile> createState() => _AgentImageTileState();
}

class _AgentImageTileState extends State<_AgentImageTile> {
  Uint8List? _bytes;
  ImageProvider? _thumbnail;

  @override
  void initState() {
    super.initState();
    _bytes = widget.readImage();
    if (_bytes != null) {
      _thumbnail = ResizeImage(
        MemoryImage(_bytes!),
        width: 256,
        height: 256,
        policy: ResizeImagePolicy.fit,
      );
    }
  }

  @override
  void dispose() {
    _thumbnail?.evict();
    _bytes = null;
    super.dispose();
  }

  Future<void> _preview() async {
    if (_bytes == null) return;
    final preview = ResizeImage(
      MemoryImage(_bytes!),
      width: 4096,
      height: 4096,
      policy: ResizeImagePolicy.fit,
    );
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            children: [
              ListTile(
                title: Text(
                  widget.image.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(agentFormatBytes(widget.image.byteLength)),
                trailing: IconButton(
                  tooltip: '关闭图片',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 8,
                  child: Center(
                    child: Image(image: preview, fit: BoxFit.contain),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      await preview.evict();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 104,
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
                      onTap: _bytes == null ? null : _preview,
                      child: _thumbnail == null
                          ? const Center(
                              child: Text(
                                '图片已丢失',
                                style: TextStyle(fontSize: 12),
                              ),
                            )
                          : Image(
                              image: _thumbnail!,
                              fit: BoxFit.cover,
                              semanticLabel: '查看图片 ${widget.image.name}',
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                    ),
                  ),
                ),
                if (widget.onRemove != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton.filledTonal(
                      key: ValueKey('remove-image-${widget.image.id}'),
                      tooltip: '移除图片',
                      onPressed: widget.onRemove,
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
            message:
                '${widget.image.name} · ${agentFormatBytes(widget.image.byteLength)}',
            child: Text(
              widget.image.name,
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
