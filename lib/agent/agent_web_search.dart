import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'agent_http_adapter.dart';
import 'agent_models.dart';
import 'agent_search_browser.dart';
import 'agent_web_links.dart';

typedef AgentSearchPageLoader = Future<String> Function(Uri url, AgentRun run);

/// Independent from AppDio: no logging, account cookies or model API headers.
class AgentWebSearchClient {
  static const maxResponseBytes = 2 * 1024 * 1024;
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  final Dio Function() createDio;
  final AgentSearchPageLoader? loadPage;
  final Duration timeout;
  final Duration modelSearchTimeout;
  const AgentWebSearchClient({
    this.createDio = _defaultDio,
    this.loadPage = loadAgentSearchPage,
    this.timeout = const Duration(seconds: 25),
    this.modelSearchTimeout = const Duration(seconds: 60),
  });

  static Dio _defaultDio() => Dio()..httpClientAdapter = AgentHttpAdapter();

  static Uri searchUrl(AgentSearchEngine engine, String query, int count) =>
      switch (engine) {
        AgentSearchEngine.bing => Uri.https('www.bing.com', '/search', {
          'q': query,
          'count': '$count',
        }),
        AgentSearchEngine.google => Uri.https('www.google.com', '/search', {
          'q': query,
          'num': '$count',
          'udm': '14',
        }),
        AgentSearchEngine.tavily => Uri.https('api.tavily.com', '/search'),
        AgentSearchEngine.deepseek => Uri.parse(
          '${AgentWebSearchSettings.defaultDeepseekBaseUrl}/messages',
        ),
      };

  Future<AgentJson> search({
    required AgentSearchEngine engine,
    required String query,
    required AgentRun run,
    int maxResults = 5,
    String tavilyKey = '',
    String deepseekKey = '',
    AgentModel? deepseekModel,
  }) async {
    query = query.trim();
    if (query.isEmpty ||
        query.length > 500 ||
        maxResults < 1 ||
        maxResults > 10) {
      throw const AgentException(
        'INVALID_ARGUMENT',
        '搜索词需要 1–500 字，结果数量需要是 1–10 的整数',
      );
    }
    final key = engine == AgentSearchEngine.deepseek
        ? deepseekKey.trim()
        : tavilyKey.trim();
    if (_isApi(engine) && key.isEmpty) {
      throw AgentException(
        'SEARCH_KEY_MISSING',
        '请在 Agent 设置中配置 ${engine.label} API Key',
      );
    }
    run.check();
    final searchModel =
        deepseekModel ?? const AgentWebSearchSettings().deepseekSearchModel;
    if (engine == AgentSearchEngine.deepseek) searchModel.validate();
    final url = engine == AgentSearchEngine.deepseek
        ? searchModel.endpoint
        : searchUrl(engine, query, maxResults);
    final dio = createDio();
    dio.options.connectTimeout = timeout;
    final cancel = CancelToken();
    unawaited(run.whenCancelled.then((_) => cancel.cancel('Stopped')));
    try {
      // Bing's public RSS view avoids downloading scripts and images and
      // does not require an API key.
      final requestUrl = engine == AgentSearchEngine.bing
          ? url.replace(
              queryParameters: {...url.queryParameters, 'format': 'rss'},
            )
          : url;
      List<AgentJson> results;
      List<String> warnings = const [];
      if (engine == AgentSearchEngine.deepseek) {
        final data = await run.wait(
          _deepseek(
            dio,
            url,
            searchModel.model,
            query,
            maxResults,
            key,
            cancel,
          ),
          timeout: modelSearchTimeout,
        );
        results = (data['results'] as List).cast<AgentJson>();
        warnings = (data['warnings'] as List).cast<String>();
      } else {
        final body = await run.wait(
          _request(dio, requestUrl, engine, query, maxResults, key, cancel),
          timeout: timeout,
        );
        if (engine == AgentSearchEngine.tavily) {
          results = parseTavily(body, maxResults, secret: key);
        } else {
          try {
            results = await run.wait(
              compute(_parsePage, (engine, body, maxResults)),
              timeout: timeout,
            );
          } on AgentException catch (e) {
            if (e.code != 'SEARCH_BROWSER_REQUIRED' || loadPage == null) {
              rethrow;
            }
            final rendering = AgentRun();
            unawaited(run.whenCancelled.then((_) => rendering.cancel()));
            late String rendered;
            try {
              rendered = await run.wait(
                loadPage!(url, rendering),
                timeout: timeout,
              );
            } finally {
              // Also release a renderer still queued when this search times out.
              // Stopping this search must not stop the whole Agent task.
              rendering.cancel();
            }
            if (rendered.length > maxResponseBytes) {
              throw const AgentException(
                'SEARCH_RESPONSE_TOO_LARGE',
                '搜索页面过大，请缩小搜索范围',
              );
            }
            try {
              results = await run.wait(
                compute(_parsePage, (engine, rendered, maxResults)),
                timeout: timeout,
              );
            } on AgentException catch (e) {
              if (e.code != 'SEARCH_BROWSER_REQUIRED') rethrow;
              throw AgentException(
                'SEARCH_UNAVAILABLE',
                '${engine.label} 未返回可读取的搜索结果，可能需要验证或页面格式已变化；可改用其他已启用的引擎',
              );
            }
          }
        }
      }
      run.check();
      return {
        'engine': engine.name,
        'query': query,
        if (!_isApi(engine)) 'search_url': url.toString(),
        'retrieved_at': DateTime.now().toUtc().toIso8601String(),
        'results': results,
        'returned_count': results.length,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
    } on DioException catch (e) {
      if (run.isCancelled || CancelToken.isCancel(e)) {
        throw const AgentException('CANCELLED', '已停止搜索');
      }
      // No server bodies or request options: either may echo credentials.
      throw AgentException(
        'SEARCH_REQUEST_FAILED',
        '${engine.label} 连接失败或超时，请检查网络和应用代理设置',
      );
    } on FormatException {
      throw AgentException(
        'SEARCH_INVALID_RESPONSE',
        '${engine.label} 返回了无法解析的搜索结果',
      );
    } finally {
      if (!cancel.isCancelled) cancel.cancel('Search finished');
      dio.close(force: true);
    }
  }

  static bool _isApi(AgentSearchEngine engine) =>
      engine == AgentSearchEngine.tavily ||
      engine == AgentSearchEngine.deepseek;

  Future<AgentJson> _deepseek(
    Dio dio,
    Uri url,
    String model,
    String query,
    int count,
    String key,
    CancelToken cancel,
  ) async {
    final messages = <AgentJson>[
      {'role': 'user', 'content': 'Perform a web search for the query: $query'},
    ];
    final blocks = <dynamic>[];
    // A pause is a server-side continuation, never a client function call.
    // Limit one auxiliary search to three responses and one overall timeout.
    for (var turn = 0; turn < 3; turn++) {
      final raw = await _request(
        dio,
        url,
        AgentSearchEngine.deepseek,
        query,
        count,
        key,
        cancel,
        payload: {
          'model': model,
          'max_tokens': 4096,
          'stream': false,
          'messages': messages,
          'tools': [
            {
              'type': 'web_search_20250305',
              'name': 'web_search',
              'max_uses': 5,
            },
          ],
        },
      );
      final data = agentObject(jsonDecode(raw));
      if (data['error'] != null || data['content'] is! List) {
        throw const AgentException(
          'SEARCH_INVALID_RESPONSE',
          'DeepSeek 未返回有效的搜索响应',
        );
      }
      blocks.addAll(data['content'] as List);
      if (data['stop_reason'] == 'pause_turn') {
        messages.add({'role': 'assistant', 'content': data['content']});
        continue;
      }
      return parseDeepseek({'content': blocks}, count, secret: key);
    }
    throw const AgentException(
      'SEARCH_INCOMPLETE',
      'DeepSeek 搜索尚未完成，请缩小搜索范围或稍后再试',
    );
  }

  Future<String> _request(
    Dio dio,
    Uri url,
    AgentSearchEngine engine,
    String query,
    int count,
    String key,
    CancelToken cancel, {
    AgentJson? payload,
  }) async {
    // Never forward Tavily credentials. Public search redirects stay on the
    // selected engine's HTTPS domain.
    for (var redirects = 0; redirects <= 3; redirects++) {
      final response = await dio.requestUri<ResponseBody>(
        url,
        cancelToken: cancel,
        data: _isApi(engine)
            ? payload ??
                  {
                    'query': query,
                    'max_results': count,
                    'search_depth': 'basic',
                    'topic': 'general',
                    'auto_parameters': false,
                    'include_answer': false,
                    'include_raw_content': false,
                    'include_images': false,
                  }
            : null,
        options: Options(
          method: _isApi(engine) ? 'POST' : 'GET',
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: engine == AgentSearchEngine.deepseek
              ? modelSearchTimeout
              : timeout,
          sendTimeout: timeout,
          headers: {
            'Accept': _isApi(engine)
                ? 'application/json'
                : 'text/html,application/xhtml+xml,application/xml,text/xml;q=0.9,*/*;q=0.8',
            if (_isApi(engine)) ...{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${key.trim()}',
              if (engine == AgentSearchEngine.deepseek) ...{
                'x-api-key': key.trim(),
                'anthropic-version': '2023-06-01',
              },
            } else
              'User-Agent': userAgent,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data;
      if (body == null) {
        throw const AgentException('SEARCH_INVALID_RESPONSE', '搜索服务返回了空响应');
      }
      if ([301, 302, 303, 307, 308].contains(status)) {
        await body.stream.listen((_) {}).cancel();
        final location = response.headers.value('location');
        final next = location == null ? null : agentWebUri(location, base: url);
        if (_isApi(engine) ||
            redirects == 3 ||
            next == null ||
            !agentSearchNavigationAllowed(next, engine)) {
          throw const AgentException('SEARCH_REDIRECT', '搜索服务返回了不支持的重定向');
        }
        if (next.host.startsWith('consent.') ||
            next.path.startsWith('/sorry')) {
          throw AgentException(
            'SEARCH_BLOCKED',
            '${engine.label} 需要网页验证，请改用其他已启用的引擎',
          );
        }
        url = next;
        continue;
      }
      if (status != 200) {
        await body.stream.listen((_) {}).cancel();
        if (_isApi(engine) && [401, 403].contains(status)) {
          throw AgentException(
            'SEARCH_AUTH_FAILED',
            '${engine.label} 密钥无效或无权搜索，请检查 API Key',
          );
        }
        if (status == 429) {
          throw AgentException(
            'SEARCH_RATE_LIMITED',
            '${engine.label} 请求过于频繁或额度不足，请稍后再试',
          );
        }
        if ([402, 432, 433].contains(status) && _isApi(engine)) {
          throw AgentException(
            'SEARCH_QUOTA_EXCEEDED',
            '${engine.label} 搜索额度不足，请检查账户额度',
          );
        }
        throw AgentException(
          'SEARCH_HTTP_ERROR',
          '${engine.label} 返回 HTTP $status，搜索未完成',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const AgentException(
            'SEARCH_RESPONSE_TOO_LARGE',
            '搜索响应过大，请缩小搜索范围',
          );
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    }
    throw const AgentException('SEARCH_REDIRECT', '搜索服务重定向次数过多');
  }

  static List<AgentJson> parseTavily(
    String body,
    int limit, {
    String secret = '',
  }) {
    final data = agentObject(jsonDecode(body));
    if (data['results'] is! List || data['error'] != null) {
      throw const AgentException(
        'SEARCH_INVALID_RESPONSE',
        'Tavily 未返回有效的搜索结果',
      );
    }
    final output = <AgentJson>[];
    final seen = <String>{};
    for (final item in data['results'] as List) {
      if (item is! Map) continue;
      var title = item['title'] is String ? item['title'] as String : '';
      var snippet = item['content'] is String ? item['content'] as String : '';
      final url = item['url'] is String ? item['url'] as String : '';
      if (secret.isNotEmpty) {
        if (url.contains(secret)) continue;
        title = title.replaceAll(secret, '[已隐藏]');
        snippet = snippet.replaceAll(secret, '[已隐藏]');
      }
      _addResult(output, seen, title, url, snippet, limit);
    }
    return output;
  }

  /// Match the official DeepSeek harness: require native result blocks,
  /// join snippets from URL citations, and never scrape a prose answer.
  static AgentJson parseDeepseek(
    AgentJson data,
    int limit, {
    String secret = '',
  }) {
    final blocks = data['content'] as List? ?? const [];
    final snippets = <String, String>{};
    final output = <AgentJson>[];
    final seen = <String>{};
    final warnings = <String>[];
    var hasResults = false;
    String redact(String text) =>
        secret.isEmpty ? text : text.replaceAll(secret, '[已隐藏]');
    for (final block in blocks) {
      if (block is! Map || block['type'] != 'text') continue;
      for (final citation in block['citations'] as List? ?? const []) {
        if (citation is Map &&
            citation['url'] is String &&
            citation['cited_text'] is String) {
          snippets.putIfAbsent(
            citation['url'] as String,
            () => citation['cited_text'] as String,
          );
        }
      }
    }
    for (final block in blocks) {
      if (block is! Map || block['type'] != 'web_search_tool_result') continue;
      hasResults = true;
      final content = block['content'];
      if (content is Map) {
        final code = content['error_code'];
        warnings.add(switch (code) {
          'too_many_requests' => 'DeepSeek 搜索请求过于频繁',
          'max_uses_exceeded' => 'DeepSeek 达到本次搜索次数上限',
          'query_too_long' => 'DeepSeek 搜索词过长',
          _ => 'DeepSeek 部分搜索未完成',
        });
        continue;
      }
      if (content is! List) {
        throw const AgentException(
          'SEARCH_INVALID_RESPONSE',
          'DeepSeek 搜索结果格式无效',
        );
      }
      for (final item in content) {
        if (item is! Map || item['type'] != 'web_search_result') continue;
        final url = item['url'] as String? ?? '';
        if (secret.isNotEmpty && url.contains(secret)) continue;
        _addResult(
          output,
          seen,
          redact(item['title'] as String? ?? agentWebUri(url)?.host ?? ''),
          url,
          redact(snippets[url] ?? ''),
          limit,
        );
      }
    }
    if (!hasResults) {
      throw const AgentException(
        'SEARCH_NOT_EXECUTED',
        'DeepSeek 没有返回原生搜索结果，请检查搜索模型和 Messages 地址；普通回答不视为联网成功',
      );
    }
    if (output.isEmpty && warnings.isNotEmpty) {
      throw AgentException('SEARCH_PROVIDER_ERROR', warnings.join('；'));
    }
    return {'results': output, 'warnings': warnings};
  }

  static List<AgentJson> parseWebsite(
    AgentSearchEngine engine,
    String body,
    int limit,
  ) {
    final output = <AgentJson>[];
    final seen = <String>{};
    if (engine == AgentSearchEngine.bing &&
        RegExp(r'<rss[\s>]', caseSensitive: false).hasMatch(body)) {
      final rss = XmlDocument.parse(body);
      for (final item in rss.findAllElements('item')) {
        _addResult(
          output,
          seen,
          item.getElement('title')?.innerText ?? '',
          item.getElement('link')?.innerText ?? '',
          html
                  .parseFragment(
                    item.getElement('description')?.innerText ?? '',
                  )
                  .text ??
              '',
          limit,
        );
      }
      return output;
    }
    final document = html.parse(body);
    for (final element in document.querySelectorAll('script,style,noscript')) {
      element.remove();
    }
    final text = document.body?.text ?? '';
    if (document.querySelector(
              'form[action*="/sorry"], #captcha-form, #b_captcha, .g-recaptcha, #challenge-form',
            ) !=
            null ||
        RegExp(
          r'unusual traffic from your computer network|verify you are human|请输入验证码|请完成验证',
          caseSensitive: false,
        ).hasMatch(text)) {
      throw AgentException(
        'SEARCH_BLOCKED',
        '${engine.label} 需要网页验证，请改用其他已启用的引擎',
      );
    }
    if (engine == AgentSearchEngine.bing) {
      for (final card in document.querySelectorAll('li.b_algo')) {
        final link = card.querySelector('h2 a');
        if (link == null) continue;
        _addResult(
          output,
          seen,
          link.text,
          _resultUrl(link.attributes['href'] ?? '', engine),
          card.querySelector('.b_caption p, .b_snippet, p')?.text ?? '',
          limit,
        );
      }
    } else {
      for (final heading in document.querySelectorAll('h3, .BNeawe.vvjwJb')) {
        Element? link = heading;
        while (link != null && link.localName != 'a') {
          link = link.parent;
        }
        if (link == null) continue;
        final url = _resultUrl(link.attributes['href'] ?? '', engine);
        if (url.isEmpty) continue;
        String snippet = '';
        Element? card = link.parent;
        for (
          var depth = 0;
          card != null && depth < 5;
          depth++, card = card.parent
        ) {
          if (card.querySelectorAll('h3, .BNeawe.vvjwJb').length > 1) break;
          final candidate = card.querySelector(
            '.VwiC3b, .IsZvec, .BNeawe.s3v9rd, [data-sncf]',
          );
          if (candidate != null && candidate.text.trim().isNotEmpty) {
            snippet = candidate.text;
            break;
          }
        }
        _addResult(output, seen, heading.text, url, snippet, limit);
      }
    }
    if (output.isNotEmpty) return output;
    if (RegExp(
      r'did not match any documents|no results found|there are no results for|没有找到.*相关|找不到和您查询|没有与.*相符的|未找到.*结果',
      caseSensitive: false,
    ).hasMatch(text)) {
      return [];
    }
    throw AgentException(
      'SEARCH_BROWSER_REQUIRED',
      '${engine.label} 搜索页面需要 JavaScript 或网页验证',
    );
  }

  static String _resultUrl(String href, AgentSearchEngine engine) {
    final base = searchUrl(engine, '', 5);
    var uri = agentWebUri(href, base: base);
    if (uri == null) return '';
    if (engine == AgentSearchEngine.google &&
        (uri.host == 'google.com' || uri.host.endsWith('.google.com'))) {
      if (uri.path == '/url') {
        uri = agentWebUri(
          uri.queryParameters['q'] ?? uri.queryParameters['url'] ?? '',
        );
      } else if ([
        '/search',
        '/preferences',
        '/setprefs',
        '/imgres',
        '/advanced_search',
      ].contains(uri.path)) {
        return '';
      }
    } else if (engine == AgentSearchEngine.bing &&
        uri.host.endsWith('.bing.com') &&
        uri.path == '/ck/a') {
      var encoded = uri.queryParameters['u'] ?? '';
      if (encoded.startsWith('a1')) {
        try {
          encoded = utf8.decode(
            base64Url.decode(base64Url.normalize(encoded.substring(2))),
          );
        } on FormatException {
          return '';
        }
      }
      uri = agentWebUri(encoded);
    }
    return uri?.toString() ?? '';
  }

  static void _addResult(
    List<AgentJson> output,
    Set<String> seen,
    String title,
    String url,
    String snippet,
    int limit,
  ) {
    if (output.length >= limit) return;
    final uri = agentWebUri(url);
    if (uri == null ||
        title.trim().isEmpty ||
        !seen.add(uri.replace(fragment: '').toString())) {
      return;
    }
    String clean(String text, int max) {
      final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return value.length > max ? '${value.substring(0, max)}…' : value;
    }

    output.add({
      'title': clean(title, 300),
      'url': uri.toString(),
      'snippet': clean(snippet, 2000),
    });
  }
}

List<AgentJson> _parsePage((AgentSearchEngine, String, int) input) =>
    AgentWebSearchClient.parseWebsite(input.$1, input.$2, input.$3);
