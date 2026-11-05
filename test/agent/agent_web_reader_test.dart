import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_store.dart';
import 'package:venera/agent/agent_tools.dart';
import 'package:venera/agent/agent_web_reader.dart';

import 'agent_test_support.dart';
import 'agent_web_search_fixtures.dart';

const article = '''
<html><head><title>Title &amp; source</title></head><body>
<nav>Unrelated navigation</nav><aside>Ad</aside>
<main><h1>A useful article</h1><p>Read <a href="../guide?q=1">the guide</a> and <strong>important</strong> text.</p>
<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
<ol start="3"><li>Third</li></ol><blockquote>A quotation</blockquote>
<pre><code class="language-dart">a &lt; b;\n  print(`value`);</code></pre>
<table><tr><th>Name</th><th>Value</th></tr><tr><td>A</td><td>1 | 2</td></tr></table>
<p hidden>Hidden</p><script>untrusted script</script><img alt="封面描述" src="/cover.png">
</main><footer>Footer links</footer></body></html>
''';

ResponseBody pageBody(
  String text, {
  String mime = 'text/html; charset=utf-8',
}) => searchBody(
  text,
  headers: {
    'content-type': [mime],
  },
);
TypeMatcher<AgentException> webError(String code) =>
    isA<AgentException>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'extracts readable Markdown with resolved links, structure and no page chrome',
    () {
      final data = AgentWebReader.extract(
        article,
        Uri.parse('https://example.org/posts/one'),
      );
      expect(data['title'], 'Title & source');
      final md = data['markdown'] as String;
      for (final text in [
        '# A useful article',
        '[the guide](<https://example.org/guide?q=1>)',
        '**important**',
        '- One',
        '- Nested',
        '3. Third',
        '> A quotation',
        '```dart',
        'a < b;',
        '| Name | Value |',
        '| A | 1 \\| 2 |',
        '封面描述',
      ]) {
        expect(md, contains(text));
      }
      for (final text in [
        'Unrelated',
        'Footer',
        'untrusted script',
        'Hidden',
        '/cover.png',
      ]) {
        expect(md, isNot(contains(text)));
      }
    },
  );

  test('keeps code fences valid and rejects unsafe link schemes', () {
    final md = AgentWebReader.extract(
      '<article><pre><code>```\nx\n```</code></pre><a href="javascript:alert(1)">text</a></article>',
      Uri.parse('https://example.org'),
    )['markdown'];
    expect(md, contains('````\n```\nx\n```\n````'));
    expect(md, isNot(contains('javascript:')));
  });

  test('distinguishes challenge pages and pages requiring JavaScript', () {
    expect(
      () => AgentWebReader.extract(
        '<div id="challenge-form">Verify</div>',
        Uri.parse('https://example.org'),
      ),
      throwsA(webError('WEB_BLOCKED')),
    );
    expect(
      () => AgentWebReader.extract(
        '<script>app()</script><noscript>Enable JavaScript</noscript>',
        Uri.parse('https://example.org'),
      ),
      throwsA(webError('WEB_JS_REQUIRED')),
    );
  });

  test(
    'follows public redirects, keeps final source and caches continuation without credentials',
    () async {
      final adapter = SearchTestAdapter(
        (_, index) => index == 0
            ? searchBody(
                '',
                status: 302,
                headers: {
                  'location': ['/posts/one'],
                },
              )
            : pageBody(article),
      );
      final reader = AgentWebReader(createDio: adapter.dio);
      final first = await reader.read(
        'https://example.org/start',
        AgentRun(),
        maxChars: 35,
      );
      expect(first['url'], 'https://example.org/posts/one');
      expect(first['has_more'], true);
      final second = await reader.read(
        'https://example.org/start',
        AgentRun(),
        startChar: first['next_start_char'],
        maxChars: 30000,
      );
      expect(second['has_more'], false);
      expect(
        '${first['markdown']}${second['markdown']}',
        AgentWebReader.extract(
          article,
          Uri.parse('https://example.org/posts/one'),
        )['markdown'],
      );
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(
            anyOf(
              contains('authorization'),
              contains('cookie'),
              contains('x-api-key'),
            ),
          ),
        );
      }
      expect(adapter.closed, true);
    },
  );

  test('pagination never corrupts non-BMP characters', () async {
    final adapter = SearchTestAdapter(
      (_, _) => pageBody('A😀B', mime: 'text/plain'),
    );
    final reader = AgentWebReader(createDio: adapter.dio);
    final first = await reader.read(
      'https://example.org',
      AgentRun(),
      maxChars: 2,
    );
    expect(first['markdown'], 'A');
    final second = await reader.read(
      'https://example.org',
      AgentRun(),
      startChar: first['next_start_char'],
      maxChars: 1,
    );
    expect(second['markdown'], '😀');
    expect(second['next_start_char'], 3);
  });

  test('preserves native Markdown documents and text', () async {
    final adapter = SearchTestAdapter(
      (_, _) => pageBody('# Title\n\nText', mime: 'text/markdown'),
    );
    final data = await AgentWebReader(
      createDio: adapter.dio,
    ).read('https://example.org/doc.md', AgentRun());
    expect(data['markdown'], '# Title\n\nText');
    expect(data['content_type'], 'text/markdown');
  });

  test('decodes Chinese legacy charsets without garbling the body', () async {
    for (final (charset, bytes) in [
      ('gbk', const GbkCodec().encode('<p>漫画封面</p>')),
      ('big5', const Big5Codec().encode('<p>漫畫封面</p>')),
    ]) {
      final adapter = SearchTestAdapter(
        (_, _) => ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            'content-type': ['text/html; charset=$charset'],
          },
        ),
      );
      final data = await AgentWebReader(
        createDio: adapter.dio,
      ).read('https://example.org', AgentRun());
      expect(data['markdown'], anyOf('漫画封面', '漫畫封面'));
    }
  });

  test(
    'invalid arguments and cancelled runs do not open a connection',
    () async {
      final adapter = SearchTestAdapter((_, _) => pageBody(article));
      final reader = AgentWebReader(createDio: adapter.dio);
      for (final url in ['file:///private', 'https://user:pass@example.org']) {
        await expectLater(
          reader.read(url, AgentRun()),
          throwsA(webError('INVALID_ARGUMENT')),
        );
      }
      await expectLater(
        reader.read('https://example.org', AgentRun(), startChar: -1),
        throwsA(webError('INVALID_ARGUMENT')),
      );
      await expectLater(
        reader.read('https://example.org', AgentRun(), maxChars: 30001),
        throwsA(webError('INVALID_ARGUMENT')),
      );
      final run = AgentRun()..cancel();
      await expectLater(
        reader.read('https://example.org', run),
        throwsA(webError('CANCELLED')),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test('rejects binary files, invalid redirects and access failures', () async {
    for (final (body, code) in [
      (pageBody('binary', mime: 'application/pdf'), 'WEB_UNSUPPORTED_CONTENT'),
      (
        searchBody(
          '',
          status: 302,
          headers: {
            'location': ['file:///secret'],
          },
        ),
        'WEB_REDIRECT',
      ),
      (searchBody('', status: 403), 'WEB_BLOCKED'),
      (searchBody('', status: 429), 'WEB_BLOCKED'),
      (searchBody('', status: 404), 'WEB_HTTP_ERROR'),
    ]) {
      final adapter = SearchTestAdapter((_, _) => body);
      await expectLater(
        AgentWebReader(
          createDio: adapter.dio,
        ).read('https://example.org', AgentRun()),
        throwsA(webError(code)),
      );
      expect(adapter.closed, true);
    }
  });

  test('bounds streaming size and cancels stalled transports', () async {
    final large = SearchTestAdapter(
      (_, _) => ResponseBody(
        Stream.value(Uint8List(AgentWebReader.maxResponseBytes + 1)),
        200,
      ),
    );
    await expectLater(
      AgentWebReader(
        createDio: large.dio,
      ).read('https://example.org', AgentRun()),
      throwsA(webError('WEB_RESPONSE_TOO_LARGE')),
    );
    final pending = Completer<ResponseBody>();
    final stalled = SearchTestAdapter((_, _) => pending.future);
    await expectLater(
      AgentWebReader(
        createDio: stalled.dio,
        timeout: const Duration(milliseconds: 20),
      ).read('https://example.org', AgentRun()),
      throwsA(webError('TIMEOUT')),
    );
    await stalled.cancelled.future;
    expect(stalled.closed, true);
    pending.complete(pageBody(article));
  });

  test('stop cancels an active read and releases its transport', () async {
    final pending = Completer<ResponseBody>();
    final adapter = SearchTestAdapter((_, _) => pending.future);
    final run = AgentRun();
    final future = AgentWebReader(
      createDio: adapter.dio,
    ).read('https://example.org', run);
    await adapter.started.future;
    run.cancel();
    await expectLater(future, throwsA(webError('CANCELLED')));
    await adapter.cancelled.future;
    expect(adapter.closed, true);
    pending.complete(pageBody(article));
  });

  test(
    'batch tool keeps ordered partial results and validates each entry',
    () async {
      final root = await Directory.systemTemp.createTemp('agent-reader-');
      configureAgentTestPaths(root.path);
      final store = await AgentStore.open('${root.path}/agent');
      addTearDown(() async {
        store.close();
        await root.delete(recursive: true);
      });
      final adapter = SearchTestAdapter((_, _) => pageBody(article));
      final tools = AgentTools(
        store,
        webReader: AgentWebReader(createDio: adapter.dio),
      );
      final result = await tools.execute('read_web', {
        'pages': [
          {'url': 'https://example.org/doc', 'max_chars': 20},
          {'url': 'file:///private'},
          {'url': 'https://example.org/doc', 'start_char': 'bad'},
          {'url': 'https://example.org/doc', 'unknown': true},
          {'url': 'https://example.org/doc'},
        ],
      }, AgentToolContext(store.createConversation().id, AgentRun()));
      expect(result['ok'], true);
      expect(result['data']['summary'], {
        'total': 5,
        'ok': 2,
        'skipped': 0,
        'failed': 3,
      });
      expect((result['data']['results'] as List).map((r) => r['index']), [
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(adapter.requests, hasLength(1));
      expect(AgentTools.writeTools, isNot(contains('read_web')));
      expect(jsonEncode(result), isNot(contains('untrusted script')));
    },
  );
}
