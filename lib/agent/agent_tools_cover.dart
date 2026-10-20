part of 'agent_tools.dart';

/// Brings a comic cover to the model. The bytes stay in the local image table
/// with the response that called the tool, and the receipt describes what was
/// read so a text-only model still learns the cover's source and size.
extension _AgentCoverTools on AgentTools {
  static const _coverTimeout = Duration(seconds: 20);

  /// Either `url`, or `source_key` with `comic_id`, never both and never none.
  static AgentJson _coverTarget(AgentJson a) {
    final rawUrl = a['url'];
    final sourceKey = a['source_key'];
    final comicId = a['comic_id'];
    final hasUrl = rawUrl is String && rawUrl.trim().isNotEmpty;
    final hasKey = sourceKey is String && sourceKey.trim().isNotEmpty;
    final hasId = comicId is String && comicId.trim().isNotEmpty;
    if (hasUrl ? (hasKey || hasId) : !(hasKey && hasId)) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'url 与 source_key + comic_id 需要且只能提供一组',
      );
    }
    if (hasKey && hasId) {
      return {'source_key': (sourceKey).trim(), 'comic_id': (comicId).trim()};
    }
    final uri = Uri.tryParse((rawUrl as String).trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        'url 需要是不含账号信息的 HTTP(S) 图片地址',
      );
    }
    return {'url': uri.toString()};
  }

  Future<AgentJson> _comicCover(AgentJson a, AgentToolContext c) async {
    final target = _coverTarget(a);
    String? imageUrl = target['url'] as String?;
    AgentComic? known;
    ComicSource? source;
    String? comicId;
    String? sourceKey;
    if (imageUrl == null) {
      sourceKey = target['source_key'] as String;
      final requested = target['comic_id'] as String;
      known = store.seen(c.conversationId, sourceKey, requested);
      comicId = known?.comicId ?? requested;
      known ??= store.seen(c.conversationId, sourceKey, comicId);
      var cover = known?.cover ?? '';
      if (cover.trim().isEmpty) {
        // Only an unknown cover needs the source; a remembered one is enough.
        source = await _source(sourceKey, c);
        // Details are cached, so a comic read before is not requested again.
        final details = await _cachedDetails(source, comicId, c);
        _rememberDetails(details, c, alias: requested);
        cover = details.cover;
        known = store.seen(c.conversationId, source.key, comicId);
      }
      if (cover.trim().isEmpty) {
        throw const AgentException('NO_COVER', '该漫画没有可读取的封面地址');
      }
      imageUrl = cover;
    }
    final loaded = await _readCover(imageUrl, source, comicId, c);
    final draft = AgentImageDraft(
      AgentImageAttachment(
        id: agentId(),
        name: _coverName(
          known?.title ?? source?.name,
          loaded.attachment.mimeType,
        ),
        mimeType: loaded.attachment.mimeType,
        byteLength: loaded.attachment.byteLength,
      ),
      loaded.bytes,
    );
    // The controller attaches the bytes to the response after saving the
    // receipt, so a resumed conversation can find them again.
    _rememberPending(draft);
    return {
      'url': imageUrl,
      if (sourceKey != null) ...{'source_key': sourceKey, 'comic_id': comicId},
      if (known != null) ...{
        'title': known.title,
        if (known.subtitle.isNotEmpty) 'author': known.subtitle,
      },
      'image': draft.attachment.toJson(),
      'vision': c.supportsVision
          ? '本回复附带图片，可直接查看'
          : '当前模型未开启图片输入，只能依据这里的信息描述封面',
    };
  }

  static String _coverName(String? title, String mimeType) {
    final extension = switch (mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
    final base =
        (title == null || title.trim().isEmpty ? 'cover' : title.trim())
            .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ')
            .trim();
    return '${base.length > 80 ? base.substring(0, 80) : base}.$extension';
  }

  /// Loads the bytes the same way the app displays a cover, so source headers,
  /// mirroring, cookies and the thumbnail cache apply. Oversized responses are
  /// rejected instead of being sent to the model whole.
  Future<AgentImageDraft> _readCover(
    String url,
    ComicSource? source,
    String? comicId,
    AgentToolContext c,
  ) async {
    Future<AgentImageDraft> load() async {
      final Uint8List data;
      try {
        data = await loadCover(url, source?.key, comicId, c.run.check);
      } on TimeoutException {
        throw const AgentException('TIMEOUT', '下载封面超时，请稍后重试');
      } catch (error) {
        if (error is AgentException) rethrow;
        throw const AgentException(
          'COVER_REQUEST_FAILED',
          '下载封面失败，请检查网络或源是否可用',
        );
      }
      if (data.isEmpty) {
        throw const AgentException('COVER_REQUEST_FAILED', '封面下载结果为空');
      }
      return validateAgentImage(name: 'cover', bytes: data);
    }

    return c.run.wait(load(), timeout: _coverTimeout);
  }
}
