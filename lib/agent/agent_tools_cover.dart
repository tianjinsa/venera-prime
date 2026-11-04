part of 'agent_tools.dart';

extension _AgentCoverTools on AgentTools {
  Future<AgentJson> _readCover(AgentJson args, AgentToolContext c) async {
    if (!c.supportsVision) {
      throw const AgentException(
        'VISION_UNSUPPORTED',
        '请切换到支持识图的模型，并在模型设置中开启“图片输入”后读取封面',
      );
    }
    if (c.messageId == null) {
      throw const AgentException('INVALID_ARGUMENT', '封面需要关联当前工具消息');
    }
    String? sourceKey = args.containsKey('source_key')
        ? AgentTools._text(args, 'source_key')
        : null;
    String? comicId = args.containsKey('comic_id')
        ? AgentTools._text(args, 'comic_id')
        : null;
    if (comicId != null && sourceKey == null) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'comic_id 需要同时提供 source_key',
      );
    }
    AgentComic? comic;
    String url;
    if (args.containsKey('cover_url')) {
      url = AgentTools._text(args, 'cover_url');
    } else {
      if (sourceKey == null || comicId == null) {
        throw const AgentException(
          'INVALID_ARGUMENT',
          '请提供 source_key + comic_id 或 cover_url',
        );
      }
      comic = await _metadata((sourceKey, comicId), c);
      sourceKey = comic.sourceKey;
      comicId = comic.comicId;
      url = comic.cover;
    }
    if (url.startsWith('//')) url = 'https:$url';
    final uri = Uri.tryParse(url);
    final virtual =
        url.startsWith('cover.') && sourceKey != null && comicId != null;
    if (!virtual &&
        (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty)) {
      throw const AgentException('INVALID_ARGUMENT', '封面地址需要有效的 HTTP(S) 图片地址');
    }
    if (sourceKey != null) await _source(sourceKey, c);
    try {
      final bytes = await c.run.wait(
        coverLoader(url, sourceKey, comicId, c.run),
        timeout: sourceTimeout,
      );
      final image = await c.run.wait(
        validateAgentImage(
          bytes,
          comic == null ? '漫画封面' : '${comic.title} · 封面',
        ),
      );
      c.run.check();
      store.saveToolImage(c.conversationId, c.messageId!, image);
      return {
        if (sourceKey != null) 'source_key': sourceKey,
        if (comicId != null) 'comic_id': comicId,
        if (comic != null) 'title': comic.title,
        'cover_url': url,
        'image': image.attachment.toJson(),
      };
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException(
        'COVER_LOAD_FAILED',
        '封面读取失败，请检查封面地址、网络或漫画源状态',
      );
    }
  }
}
