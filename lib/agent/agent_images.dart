import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:mime/mime.dart';
import 'package:venera/utils/io.dart' show IO;
import 'agent_models.dart';

const agentImageMaxBytes = 20 * 1024 * 1024;

Future<List<AgentImageDraft>> pickAgentImages() async {
  final files = await IO.withFileSelection(
    () => openFiles(
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
    ),
  );
  final images = <AgentImageDraft>[];
  for (final file in files) {
    images.add(await readAgentImage(file));
  }
  return images;
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
