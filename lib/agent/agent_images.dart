import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:venera/utils/io.dart' show IO;
import 'agent_models.dart';

const agentImageMaxBytes = 20 * 1024 * 1024;

const _imagePickerChannel = MethodChannel('venera/method_channel');

Future<List<AgentImageDraft>> pickAgentImages() =>
    IO.withFileSelection(() async {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return _pickAndroidImages();
      }
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '图片',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
            mimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'],
            uniformTypeIdentifiers: [
              'public.jpeg',
              'public.png',
              'org.webmproject.webp',
              'com.compuserve.gif',
            ],
          ),
        ],
      );
      return [for (final file in files) await readAgentImage(file)];
    });

Future<List<AgentImageDraft>> _pickAndroidImages() async {
  List<dynamic>? selected;
  try {
    selected = await _imagePickerChannel.invokeListMethod<dynamic>(
      'pickAgentImages',
    );
  } on PlatformException catch (e) {
    throw AgentException(e.code, e.message ?? '无法读取所选图片');
  }
  if (selected == null || selected.isEmpty) return [];
  final paths = [
    for (final image in selected.whereType<Map>())
      if (image['path'] is String) image['path'] as String,
  ];
  try {
    final files = selected.map((value) {
      final image = value as Map;
      return _SelectedImage(image['path'] as String, image['name'] as String);
    }).toList();
    return [for (final file in files) await readAgentImage(file)];
  } finally {
    // Android only returns private, freshly copied cache files. Never keep a
    // temporary original after validation, including when another image fails.
    for (final path in paths) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // A cleared cache must not hide the original picker/validation result.
      }
    }
    try {
      await _imagePickerChannel.invokeMethod<void>('releaseAgentImages', {
        'paths': paths,
      });
    } on MissingPluginException {
      // Activity/engine detach performs native cleanup even without this reply.
    } on PlatformException {
      // A cleanup acknowledgement must not replace a read/validation result.
    }
  }
}

class _SelectedImage extends XFile {
  _SelectedImage(super.path, this.name);

  // XFile's native implementation ignores its optional name argument.
  @override
  final String name;
}

Future<AgentImageDraft> readAgentImage(XFile file) async {
  if (await file.length() > agentImageMaxBytes) {
    throw AgentException('IMAGE_TOO_LARGE', '图片“${file.name}”超过20 MB，请缩小后添加');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > agentImageMaxBytes) {
    throw AgentException('IMAGE_TOO_LARGE', '图片“${file.name}”超过20 MB，请缩小后添加');
  }
  // Detect the content itself, not a user-supplied filename extension.
  final mime = lookupMimeType('', headerBytes: bytes);
  if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].contains(mime)) {
    throw const AgentException('INVALID_IMAGE', '请选择 JPEG、PNG、WebP 或静态 GIF 图片');
  }
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 1,
      targetHeight: 1,
    );
    if (codec.frameCount > 1) {
      throw const AgentException('ANIMATED_IMAGE', '暂不支持动图，请选择静态图片');
    }
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } on AgentException {
    rethrow;
  } catch (_) {
    throw AgentException('INVALID_IMAGE', '图片“${file.name}”无法解码，请选择有效图片');
  } finally {
    codec?.dispose();
  }
  return AgentImageDraft(
    AgentImageAttachment(
      id: agentId(),
      name: file.name,
      mimeType: mime!,
      byteLength: bytes.length,
    ),
    bytes,
  );
}
