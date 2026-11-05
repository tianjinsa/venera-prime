import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'agent_http_adapter.dart';
import 'agent_models.dart';
import 'agent_web_links.dart';
import 'agent_web_search.dart';

/// Fetches public documents with the app's transport preferences, without
/// account cookies, model credentials, logging interceptors or remote readers.
class AgentWebReader {
  static const maxResponseBytes = 4 * 1024 * 1024;
  final Dio Function() createDio;
  final Duration timeout;
  final _cache = <String, (DateTime, AgentJson)>{};

  AgentWebReader({
    this.createDio = _defaultDio,
    this.timeout = const Duration(seconds: 25),
  });

  static Dio _defaultDio() => Dio()..httpClientAdapter = AgentHttpAdapter();

  Future<AgentJson> read(
    String url,
    AgentRun run, {
    int startChar = 0,
    int maxChars = 12000,
  }) async {
    final uri = agentWebUri(url);
    if (uri == null || startChar < 0 || maxChars < 1 || maxChars > 30000) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        '需要有效的 HTTP(S) URL，start_char ≥ 0，max_chars 为 1–30000',
      );
    }
    run.check();
    final key = uri.replace(fragment: '').toString();
    final cached = _cache[key];
    late AgentJson data;
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 2)) {
      data = cached.$2;
    } else {
      final dio = createDio();
      dio.options.connectTimeout = timeout;
      final cancel = CancelToken();
      unawaited(run.whenCancelled.then((_) => cancel.cancel('Stopped')));
      try {
        data = await run.wait(_fetch(dio, uri, cancel, run), timeout: timeout);
        run.check();
        if (_cache.length >= 8) _cache.remove(_cache.keys.first);
        _cache[key] = (DateTime.now(), data);
      } on FormatException {
        throw const AgentException('WEB_INVALID_TEXT', '网页文本编码无法解析');
      } on DioException {
        run.check();
        throw const AgentException(
          'WEB_REQUEST_FAILED',
          '网页连接失败或超时，请检查网络和代理设置',
        );
      } finally {
        if (!cancel.isCancelled) cancel.cancel('Read finished');
        dio.close(force: true);
      }
    }
    final markdown = data['markdown'] as String;
    if (startChar > markdown.length) {
      throw const AgentException('INVALID_ARGUMENT', 'start_char 超出正文长度');
    }
    // Do not split UTF-16 surrogate pairs at a page boundary.
    var start = startChar;
    if (start > 0 &&
        start < markdown.length &&
        _lowSurrogate(markdown.codeUnitAt(start))) {
      start--;
    }
    var end = (start + maxChars).clamp(0, markdown.length);
    if (end > start &&
        end < markdown.length &&
        _lowSurrogate(markdown.codeUnitAt(end))) {
      end--;
    }
    if (end == start && end < markdown.length) {
      end = (end + 2).clamp(0, markdown.length);
    }
    return {
      ...data,
      'markdown': markdown.substring(start, end),
      'start_char': start,
      'total_chars': markdown.length,
      'has_more': end < markdown.length,
      if (end < markdown.length) 'next_start_char': end,
    };
  }

  static bool _lowSurrogate(int code) => code >= 0xdc00 && code <= 0xdfff;

  Future<AgentJson> _fetch(
    Dio dio,
    Uri url,
    CancelToken cancel,
    AgentRun run,
  ) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      run.check();
      final response = await dio.getUri<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          headers: {
            'User-Agent': AgentWebSearchClient.userAgent,
            'Accept':
                'text/html,text/markdown,text/plain,application/xhtml+xml;q=0.9',
          },
        ),
      );
      final body = response.data;
      if (body == null) throw const AgentException('WEB_EMPTY', '网页返回空响应');
      final status = response.statusCode ?? 0;
      if ([301, 302, 303, 307, 308].contains(status)) {
        await body.stream.listen((_) {}).cancel();
        final next = agentWebUri(
          response.headers.value('location') ?? '',
          base: url,
        );
        if (next == null || redirects == 5) {
          throw const AgentException('WEB_REDIRECT', '网页重定向无效或次数过多');
        }
        url = next;
        continue;
      }
      final contentType = response.headers.value('content-type') ?? '';
      final mime = contentType.split(';').first.trim().toLowerCase();
      if (status != 200 ||
          (mime.isNotEmpty &&
              !mime.startsWith('text/') &&
              !['application/xhtml+xml', 'application/json'].contains(mime))) {
        await body.stream.listen((_) {}).cancel();
        if ([401, 403, 429].contains(status)) {
          throw AgentException('WEB_BLOCKED', '网页要求登录、验证或限制访问（HTTP $status）');
        }
        if (status != 200) {
          throw AgentException('WEB_HTTP_ERROR', '网页返回 HTTP $status');
        }
        throw const AgentException(
          'WEB_UNSUPPORTED_CONTENT',
          '只支持 HTML、Markdown 和文本网页，不支持 PDF、图片或下载文件',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        run.check();
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const AgentException(
            'WEB_RESPONSE_TOO_LARGE',
            '网页超过4 MB，请读取更具体的页面',
          );
        }
        bytes.add(chunk);
      }
      final raw = bytes.takeBytes();
      final prefix = latin1.decode(raw.take(2048).toList());
      final charset = RegExp(
        r'charset\s*=\s*["\x27]?([\w-]+)',
        caseSensitive: false,
      );
      // A body discussing charset=... is not an encoding declaration.
      final meta = RegExp(
        r'<meta\b[^>]*>',
        caseSensitive: false,
      ).allMatches(prefix).map((m) => m[0]!).join(' ');
      final encoding =
          (charset.firstMatch(contentType)?.group(1) ??
                  charset.firstMatch(meta)?.group(1))
              ?.toLowerCase();
      final text = switch (encoding) {
        'gb2312' || 'gbk' => const GbkCodec().decode(raw),
        'big5' || 'big5-hkscs' => const Big5Codec().decode(raw),
        'iso-8859-1' || 'latin1' => latin1.decode(raw),
        _ => utf8.decode(raw, allowMalformed: true),
      };
      final data = await compute(_extractWebDocument, (
        text,
        url.toString(),
        mime,
      ));
      return {
        ...data,
        'retrieved_at': DateTime.now().toUtc().toIso8601String(),
      };
    }
    throw const AgentException('WEB_REDIRECT', '网页重定向次数过多');
  }

  static AgentJson extract(String body, Uri url, {String mime = 'text/html'}) {
    if (mime.isNotEmpty &&
        mime != 'text/html' &&
        mime != 'application/xhtml+xml') {
      if (body.trim().isEmpty) {
        throw const AgentException('WEB_EMPTY', '网页没有可读正文');
      }
      return {
        'url': url.toString(),
        'title': url.host,
        'markdown': body.trim(),
        'content_type': mime,
      };
    }
    final document = html.parse(body);
    if (document.querySelector(
              'form[action*="/sorry"], #captcha-form, #b_captcha, .g-recaptcha, #challenge-form',
            ) !=
            null ||
        RegExp(
          r'verify you are human|checking your browser|unusual traffic from your computer network|请完成验证',
          caseSensitive: false,
        ).hasMatch(document.body?.text ?? '')) {
      throw const AgentException('WEB_BLOCKED', '网页需要验证，未取得正文');
    }
    final title =
        document
            .querySelector('meta[property="og:title"]')
            ?.attributes['content'] ??
        document.querySelector('title')?.text ??
        url.host;
    final description = document
        .querySelector('meta[name="description"]')
        ?.attributes['content'];
    for (final node in document.querySelectorAll(
      'script, style, noscript, svg, canvas, iframe, form, nav, footer, aside, [role="navigation"], .mw-editsection, .noprint, [hidden], [aria-hidden="true"]',
    )) {
      node.remove();
    }
    final contentBodies = document.querySelectorAll(
      '.post-content, .entry-content, .article-body, .mw-parser-output, [itemprop="articleBody"]',
    );
    final candidates = contentBodies.isNotEmpty
        ? contentBodies
        : document.querySelectorAll('article, main, [role="main"], #content');
    // Prefer the content-rich semantic root. Retain body as a fallback for
    // forums and small documents with no article markup.
    Element? root;
    var score = 0;
    for (final candidate in candidates) {
      final length = candidate.text.trim().length;
      if (length > score) {
        root = candidate;
        score = length;
      }
    }
    root ??= document.body;
    final markdown = _WebMarkdown(url)
        .render(root)
        .replaceAll(RegExp(r'\n[ \t]+\n'), '\n\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (markdown.isEmpty ||
        (markdown.length < 200 &&
            RegExp(
              r'enable javascript|需要启用\s*javascript',
              caseSensitive: false,
            ).hasMatch(markdown))) {
      throw const AgentException(
        'WEB_JS_REQUIRED',
        '网页没有可读取的静态正文，可能需要 JavaScript 或登录',
      );
    }
    String metadata(String value, int limit) {
      final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      return clean.length > limit ? '${clean.substring(0, limit)}…' : clean;
    }

    return {
      'url': url.toString(),
      'title': metadata(title, 500),
      if (description != null) 'description': metadata(description, 2000),
      'content_type': 'text/html',
      'markdown': markdown,
    };
  }
}

AgentJson _extractWebDocument((String, String, String) input) =>
    AgentWebReader.extract(input.$1, Uri.parse(input.$2), mime: input.$3);

class _WebMarkdown {
  final Uri base;
  _WebMarkdown(this.base);
  String escape(String value) =>
      value.replaceAllMapped(RegExp(r'[\\`*_[\]<>]'), (m) => '\\${m[0]}');
  String children(Node node) => node.nodes.map(render).join();
  String render(Node? node) {
    if (node is Text) return escape(node.data.replaceAll(RegExp(r'\s+'), ' '));
    if (node is! Element) return '';
    final tag = node.localName ?? '';
    if (tag == 'pre') {
      final code = node.querySelector('code');
      final text = (code ?? node).text.trimRight();
      final fences = RegExp(r'`+')
          .allMatches(text)
          .map((m) => m[0]!.length)
          .fold(2, (int a, int b) => a > b ? a : b);
      final fence = '`' * (fences + 1);
      final language =
          RegExp(
            r'language-([\w+-]+)',
          ).firstMatch(code?.className ?? '')?.group(1) ??
          '';
      return '\n\n$fence$language\n$text\n$fence\n\n';
    }
    late final text = children(node);
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      return '\n\n${'#' * int.parse(tag[1])} ${text.trim()}\n\n';
    }
    switch (tag) {
      case 'br':
        return '\n';
      case 'hr':
        return '\n\n---\n\n';
      case 'strong' || 'b':
        return '**${text.trim()}**';
      case 'em' || 'i':
        return '*${text.trim()}*';
      case 'code':
        final raw = node.text;
        final longest = RegExp(r'`+')
            .allMatches(raw)
            .map((m) => m[0]!.length)
            .fold(0, (int a, int b) => a > b ? a : b);
        final fence = '`' * (longest + 1);
        return '$fence $raw $fence';
      case 'a':
        final uri = agentWebUri(node.attributes['href'] ?? '', base: base);
        return uri == null || text.trim().isEmpty
            ? text
            : '[${text.trim()}](<${uri.toString().replaceAll('>', '%3E')}>)';
      case 'img':
        // Alt text is useful to the reader; images are never downloaded.
        final alt = node.attributes['alt'] ?? '';
        return alt.isEmpty ? '' : ' 图片：${escape(alt)} ';
      case 'ul' || 'ol':
        var index = int.tryParse(node.attributes['start'] ?? '') ?? 1;
        return '\n\n${node.children.where((e) => e.localName == 'li').map((e) {
          final prefix = tag == 'ol' ? '${index++}. ' : '- ';
          return '$prefix${children(e).trim().replaceAll('\n', '\n  ')}';
        }).join('\n')}\n\n';
      case 'blockquote':
        return '\n\n${text.trim().split('\n').map((line) => '> $line').join('\n')}\n\n';
      case 'table':
        final rows = node
            .querySelectorAll('tr')
            .map(
              (row) => row.children
                  .where((cell) => ['td', 'th'].contains(cell.localName))
                  .map(
                    (cell) => children(cell)
                        .trim()
                        .replaceAll('|', '\\|')
                        .replaceAll(RegExp(r'\s+'), ' '),
                  )
                  .toList(),
            )
            .where((row) => row.isNotEmpty)
            .toList();
        if (rows.isEmpty) return '';
        final width = rows
            .map((row) => row.length)
            .reduce((a, b) => a > b ? a : b);
        String line(List<String> row) =>
            '| ${List.generate(width, (i) => i < row.length ? row[i] : '').join(' | ')} |';
        return '\n\n${[line(rows.first), line(List.filled(width, '---')), ...rows.skip(1).map(line)].join('\n')}\n\n';
      case 'p' ||
          'div' ||
          'section' ||
          'article' ||
          'main' ||
          'header' ||
          'details' ||
          'summary':
        return '\n\n${text.trim()}\n\n';
      default:
        return text;
    }
  }
}
