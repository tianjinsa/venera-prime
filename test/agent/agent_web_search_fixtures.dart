import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/agent/agent_models.dart';

const searchRss = '''<?xml version="1.0"?>
<rss version="2.0"><channel>
<item><title>Venera &amp; Prime</title><link>https://example.org/prime?a=1&amp;b=2</link><description>A &lt;b&gt;comic&lt;/b&gt; reader</description></item>
<item><title>Duplicate</title><link>https://example.org/prime?a=1&amp;b=2#top</link><description>Duplicate</description></item>
<item><title>Another result</title><link>https://example.org/other</link><description>Second page</description></item>
<item><title>Unsafe</title><link>javascript:alert(1)</link></item>
</channel></rss>''';

const googleSearchHtml = '''
<html><body>
<script>unusual traffic from your computer network</script>
<div class="g"><a href="/url?q=https%3A%2F%2Fexample.org%2Fprime&amp;sa=U"><h3>Venera Prime</h3></a><div class="VwiC3b">A comic reader &amp; more</div></div>
<div class="g"><a href="https://example.org/prime#duplicate"><h3>Duplicate</h3></a></div>
<div class="g"><a href="https://example.org/other"><h3>Another result</h3></a><div class="VwiC3b">Second snippet</div></div>
<a href="/search?q=internal"><h3>Related searches</h3></a>
<a href="javascript:alert(1)"><h3>Unsafe</h3></a>
<a href="https://user:password@example.org/"><h3>Credential URL</h3></a>
</body></html>
''';

const nativeSearchUse = <String, dynamic>{
  'type': 'server_tool_use',
  'id': 'srv_search',
  'name': 'web_search',
  'input': {'query': 'Venera Prime'},
};

const nativeSearchResult = <String, dynamic>{
  'type': 'web_search_tool_result',
  'tool_use_id': 'srv_search',
  'content': [
    {
      'type': 'web_search_result',
      'url': 'https://example.org/prime',
      'title': 'Venera Prime',
      'encrypted_content': 'opaque-search-content',
      'page_age': 'October 11, 2026',
    },
    {
      'type': 'web_search_result',
      'url': 'https://example.org/prime',
      'title': 'Duplicate',
      'encrypted_content': 'opaque-duplicate',
    },
  ],
};

const nativeCitedText = <String, dynamic>{
  'type': 'text',
  'text': '找到漫画阅读器。',
  'citations': [
    {
      'type': 'web_search_result_location',
      'url': 'https://example.org/prime',
      'title': 'Venera Prime',
      'encrypted_index': 'opaque-citation-index',
      'cited_text': 'A comic reader.',
    },
  ],
};

const deepseekSearchReply = <String, dynamic>{
  'type': 'message',
  'role': 'assistant',
  'stop_reason': 'end_turn',
  'content': [nativeSearchUse, nativeSearchResult, nativeCitedText],
};

ResponseBody searchBody(
  Object body, {
  int status = 200,
  Map<String, List<String>>? headers,
}) => ResponseBody.fromString(
  body is String ? body : jsonEncode(body),
  status,
  headers:
      headers ??
      {
        'content-type': ['application/json; charset=utf-8'],
      },
);

class SearchTestAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions, int) respond;
  final requests = <RequestOptions>[];
  final payloads = <Object?>[];
  final started = Completer<void>();
  final cancelled = Completer<void>();
  bool closed = false;
  SearchTestAdapter(this.respond);

  Dio dio() => Dio()..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    payloads.add(
      options.data is Map ? jsonDecode(jsonEncode(options.data)) : options.data,
    );
    if (!started.isCompleted) started.complete();
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then((_) {
          if (!cancelled.isCompleted) cancelled.complete();
        }),
      );
    }
    return respond(options, requests.length - 1);
  }

  @override
  void close({bool force = false}) => closed = true;
}

AgentJson deepseekReplyWith(
  List<AgentJson> blocks, {
  String stop = 'end_turn',
}) => {
  'type': 'message',
  'role': 'assistant',
  'stop_reason': stop,
  'content': blocks,
};
