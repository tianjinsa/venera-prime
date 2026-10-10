import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_search_browser.dart';
import 'package:venera/agent/agent_web_search.dart';

import 'agent_web_search_fixtures.dart';

TypeMatcher<AgentException> searchError(String code) =>
    isA<AgentException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'RSS decodes text, deduplicates URLs and respects the requested count',
    () {
      final results = AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.bing,
        searchRss,
        5,
      );
      expect(results, hasLength(2));
      expect(results.first, {
        'title': 'Venera & Prime',
        'url': 'https://example.org/prime?a=1&b=2',
        'snippet': 'A comic reader',
      });
      expect(
        AgentWebSearchClient.parseWebsite(AgentSearchEngine.bing, searchRss, 1),
        hasLength(1),
      );
    },
  );

  test(
    'Google extracts real result headings and snippets without search navigation',
    () {
      final results = AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.google,
        googleSearchHtml,
        5,
      );
      expect(results.map((r) => r['url']), [
        'https://example.org/prime',
        'https://example.org/other',
      ]);
      expect(results.first['snippet'], 'A comic reader & more');
    },
  );

  test('Bing HTML unwraps encoded tracking links', () {
    final encoded = base64Url
        .encode(utf8.encode('https://example.org/prime'))
        .replaceAll('=', '');
    final results = AgentWebSearchClient.parseWebsite(
      AgentSearchEngine.bing,
      '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1$encoded">Prime</a></h2><div class="b_caption"><p>Snippet</p></div></li>',
      5,
    );
    expect(results.single['url'], 'https://example.org/prime');
    expect(results.single['snippet'], 'Snippet');
  });

  test('empty results, JavaScript pages and CAPTCHA are distinct outcomes', () {
    expect(
      AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.google,
        '<p>Your search did not match any documents.</p>',
        5,
      ),
      isEmpty,
    );
    expect(
      () => AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.google,
        '<html><body><script>render()</script></body></html>',
        5,
      ),
      throwsA(searchError('SEARCH_BROWSER_REQUIRED')),
    );
    expect(
      () => AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.google,
        '<form action="/sorry/index">unusual traffic from your computer network</form>',
        5,
      ),
      throwsA(searchError('SEARCH_BLOCKED')),
    );
  });

  test(
    'public requests contain no API credentials and encode the query',
    () async {
      final adapter = SearchTestAdapter((_, _) => searchBody(searchRss));
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        loadPage: null,
      );
      final result = await client.search(
        engine: AgentSearchEngine.bing,
        query: '漫画 & 作者?',
        run: AgentRun(),
        tavilyKey: 'tavily-secret',
        deepseekKey: 'deepseek-secret',
      );
      expect(adapter.requests.single.uri.queryParameters['q'], '漫画 & 作者?');
      expect(adapter.requests.single.uri.queryParameters['format'], 'rss');
      expect(
        adapter.requests.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(adapter.payloads.single, isNull);
      expect(result['returned_count'], 2);
      expect(result['engine'], 'bing');
      expect(adapter.closed, true);
    },
  );

  test(
    'Tavily uses bearer authentication and the predictable basic search budget',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody({
          'results': [
            {
              'title': 'Prime',
              'url': 'https://example.org/prime',
              'content': 'Snippet',
            },
          ],
          'answer': 'Do not expose this unrequested field',
        }),
      );
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        loadPage: null,
      );
      final result = await client.search(
        engine: AgentSearchEngine.tavily,
        query: 'Prime',
        run: AgentRun(),
        maxResults: 3,
        tavilyKey: 'tvly-test-only',
      );
      expect(
        adapter.requests.single.uri.toString(),
        'https://api.tavily.com/search',
      );
      expect(adapter.requests.single.method, 'POST');
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer tvly-test-only',
      );
      final body = adapter.payloads.single as Map;
      expect(body['max_results'], 3);
      expect(body['search_depth'], 'basic');
      expect(body['auto_parameters'], false);
      expect(body['include_raw_content'], false);
      expect(body, isNot(contains('api_key')));
      expect(jsonEncode(result), isNot(contains('tvly-test-only')));
      expect(jsonEncode(result), isNot(contains('unrequested')));
    },
  );

  test(
    'DeepSeek is an independent Messages search with a separate key and model',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody(deepseekSearchReply),
      );
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        loadPage: null,
      );
      final result = await client.search(
        engine: AgentSearchEngine.deepseek,
        query: 'Prime',
        run: AgentRun(),
        deepseekKey: 'ds-test-only',
      );
      expect(
        adapter.requests.single.uri.toString(),
        'https://api.deepseek.com/anthropic/v1/messages',
      );
      expect(adapter.requests.single.headers['x-api-key'], 'ds-test-only');
      expect(
        adapter.requests.single.headers['anthropic-version'],
        '2023-06-01',
      );
      final body = adapter.payloads.single as Map;
      expect(body['model'], 'deepseek-v4-flash');
      expect(body['stream'], false);
      expect(body['max_tokens'], 4096);
      expect(body['tools'], [
        {'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': 5},
      ]);
      final results = result['results'] as List;
      expect(results, hasLength(1));
      expect(results.single['snippet'], 'A comic reader.');
      expect(jsonEncode(result), isNot(contains('opaque-search')));
      expect(jsonEncode(result), isNot(contains('ds-test-only')));
    },
  );

  test(
    'DeepSeek search supports an explicitly configured Messages address and model',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody(deepseekSearchReply),
      );
      await AgentWebSearchClient(createDio: adapter.dio).search(
        engine: AgentSearchEngine.deepseek,
        query: 'Prime',
        run: AgentRun(),
        deepseekKey: 'ds-key',
        deepseekModel: const AgentWebSearchSettings(
          deepseekBaseUrl: 'https://search.example.org/messages',
          deepseekModel: 'search-model',
        ).deepseekSearchModel,
      );
      expect(
        adapter.requests.single.uri.toString(),
        'https://search.example.org/messages',
      );
      expect((adapter.payloads.single as Map)['model'], 'search-model');
    },
  );

  test(
    'DeepSeek pause_turn resumes unchanged server blocks without executing them locally',
    () async {
      final adapter = SearchTestAdapter(
        (_, index) => searchBody(
          index == 0
              ? deepseekReplyWith([nativeSearchUse], stop: 'pause_turn')
              : deepseekReplyWith([nativeSearchResult, nativeCitedText]),
        ),
      );
      final result = await AgentWebSearchClient(createDio: adapter.dio).search(
        engine: AgentSearchEngine.deepseek,
        query: 'Prime',
        run: AgentRun(),
        deepseekKey: 'ds-key',
      );
      expect(adapter.requests, hasLength(2));
      final resumed = (adapter.payloads.last as Map)['messages'] as List;
      expect(resumed.last, {
        'role': 'assistant',
        'content': [nativeSearchUse],
      });
      expect(result['returned_count'], 1);
    },
  );

  test(
    'DeepSeek never treats an ordinary model answer as a search result',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody(
          deepseekReplyWith([
            {'type': 'text', 'text': 'I know the answer but did not search.'},
          ]),
        ),
      );
      await expectLater(
        AgentWebSearchClient(createDio: adapter.dio).search(
          engine: AgentSearchEngine.deepseek,
          query: 'Prime',
          run: AgentRun(),
          deepseekKey: 'ds-key',
        ),
        throwsA(searchError('SEARCH_NOT_EXECUTED')),
      );
    },
  );

  test('DeepSeek distinguishes an empty search from a server search error', () {
    expect(
      AgentWebSearchClient.parseDeepseek(
        deepseekReplyWith([
          {
            'type': 'web_search_tool_result',
            'tool_use_id': 's',
            'content': <dynamic>[],
          },
        ]),
        5,
      )['results'],
      isEmpty,
    );
    const error = {
      'type': 'web_search_tool_result',
      'tool_use_id': 's2',
      'content': {
        'type': 'web_search_tool_result_error',
        'error_code': 'max_uses_exceeded',
      },
    };
    expect(
      () => AgentWebSearchClient.parseDeepseek(deepseekReplyWith([error]), 5),
      throwsA(searchError('SEARCH_PROVIDER_ERROR')),
    );
    final partial = AgentWebSearchClient.parseDeepseek(
      deepseekReplyWith([nativeSearchResult, error]),
      5,
    );
    expect(partial['results'], hasLength(1));
    expect(partial['warnings'], hasLength(1));
  });

  test('DeepSeek limits endless pause continuations', () async {
    final adapter = SearchTestAdapter(
      (_, _) =>
          searchBody(deepseekReplyWith([nativeSearchUse], stop: 'pause_turn')),
    );
    await expectLater(
      AgentWebSearchClient(createDio: adapter.dio).search(
        engine: AgentSearchEngine.deepseek,
        query: 'Prime',
        run: AgentRun(),
        deepseekKey: 'ds-key',
      ),
      throwsA(searchError('SEARCH_INCOMPLETE')),
    );
    expect(adapter.requests, hasLength(3));
    expect(adapter.closed, true);
  });

  for (final engine in [AgentSearchEngine.tavily, AgentSearchEngine.deepseek]) {
    test(
      '${engine.name} rejects missing credentials before creating a client',
      () async {
        var created = false;
        final client = AgentWebSearchClient(
          createDio: () {
            created = true;
            return Dio();
          },
        );
        await expectLater(
          client.search(engine: engine, query: 'Prime', run: AgentRun()),
          throwsA(searchError('SEARCH_KEY_MISSING')),
        );
        expect(created, false);
      },
    );
    test(
      '${engine.name} credentials never follow redirects or appear in errors',
      () async {
        final adapter = SearchTestAdapter(
          (_, _) => searchBody(
            'secret-key echoed',
            status: 302,
            headers: {
              'location': ['https://another.example.org/search'],
            },
          ),
        );
        await expectLater(
          AgentWebSearchClient(createDio: adapter.dio).search(
            engine: engine,
            query: 'Prime',
            run: AgentRun(),
            tavilyKey: 'secret-key',
            deepseekKey: 'secret-key',
          ),
          throwsA(
            searchError('SEARCH_REDIRECT').having(
              (e) => e.toString(),
              'message',
              isNot(contains('secret-key')),
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.closed, true);
      },
    );
  }

  for (final status in [401, 429, 402, 500]) {
    test(
      'HTTP $status produces a useful error without echoing a secret',
      () async {
        final adapter = SearchTestAdapter(
          (_, _) => searchBody('Key=secret-key', status: status),
        );
        await expectLater(
          AgentWebSearchClient(createDio: adapter.dio).search(
            engine: AgentSearchEngine.tavily,
            query: 'Prime',
            run: AgentRun(),
            tavilyKey: 'secret-key',
          ),
          throwsA(
            isA<AgentException>().having(
              (e) => e.message,
              'message',
              isNot(contains('secret-key')),
            ),
          ),
        );
      },
    );
  }

  test(
    'JavaScript fallback stays with the selected engine and releases its own run',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody('<html><script>render()</script></html>'),
      );
      Uri? loaded;
      AgentRun? rendering;
      final run = AgentRun();
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        loadPage: (url, activeRun) async {
          loaded = url;
          rendering = activeRun;
          expect(activeRun.isCancelled, false);
          return googleSearchHtml;
        },
      );
      final result = await client.search(
        engine: AgentSearchEngine.google,
        query: 'Prime',
        run: run,
      );
      expect(loaded!.host, 'www.google.com');
      expect(result['returned_count'], 2);
      expect(adapter.requests, hasLength(1));
      expect(rendering!.isCancelled, true);
      expect(run.isCancelled, false);
    },
  );

  test(
    'a timed-out browser fallback is cancelled without cancelling the Agent task',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody('<html>Enable JavaScript</html>'),
      );
      final cancelled = Completer<void>();
      final run = AgentRun();
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        timeout: const Duration(milliseconds: 500),
        loadPage: (_, pageRun) async {
          unawaited(pageRun.whenCancelled.then((_) => cancelled.complete()));
          return pageRun.wait(Completer<String>().future);
        },
      );
      await expectLater(
        client.search(
          engine: AgentSearchEngine.google,
          query: 'Prime',
          run: run,
        ),
        throwsA(searchError('TIMEOUT')),
      );
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(run.isCancelled, false);
      expect(adapter.closed, true);
    },
  );

  test(
    'CAPTCHA does not launch hidden browsers or try another engine',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => searchBody('<form id="captcha-form">Verify</form>'),
      );
      var loaded = false;
      final client = AgentWebSearchClient(
        createDio: adapter.dio,
        loadPage: (_, _) async {
          loaded = true;
          return googleSearchHtml;
        },
      );
      await expectLater(
        client.search(
          engine: AgentSearchEngine.google,
          query: 'Prime',
          run: AgentRun(),
        ),
        throwsA(searchError('SEARCH_BLOCKED')),
      );
      expect(loaded, false);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('public redirects permit only the same engine over HTTPS', () {
    for (final url in [
      'https://www.google.com/search?q=x',
      'https://google.com/search?q=x',
    ]) {
      expect(
        agentSearchNavigationAllowed(Uri.parse(url), AgentSearchEngine.google),
        true,
      );
    }
    for (final url in [
      'http://www.google.com/search',
      'https://google.com.attacker.org/search',
      'https://user:pass@www.google.com/search',
      'https://www.google.com:444/search',
      'https://www.bing.com/search',
    ]) {
      expect(
        agentSearchNavigationAllowed(Uri.parse(url), AgentSearchEngine.google),
        false,
      );
    }
  });

  test(
    'cancellation while waiting for headers cancels transport and closes the client',
    () async {
      final stalled = Completer<ResponseBody>();
      final adapter = SearchTestAdapter((_, _) => stalled.future);
      final run = AgentRun();
      final future = AgentWebSearchClient(
        createDio: adapter.dio,
      ).search(engine: AgentSearchEngine.bing, query: 'Prime', run: run);
      final check = expectLater(future, throwsA(searchError('CANCELLED')));
      await adapter.started.future;
      run.cancel();
      await check;
      await adapter.cancelled.future;
      expect(adapter.closed, true);
    },
  );

  test('a header timeout also cancels the underlying transport', () async {
    final stalled = Completer<ResponseBody>();
    final adapter = SearchTestAdapter((_, _) => stalled.future);
    await expectLater(
      AgentWebSearchClient(
        createDio: adapter.dio,
        timeout: const Duration(milliseconds: 20),
      ).search(engine: AgentSearchEngine.bing, query: 'Prime', run: AgentRun()),
      throwsA(searchError('TIMEOUT')),
    );
    await adapter.cancelled.future;
    expect(adapter.closed, true);
  });

  test(
    'oversized response is stopped before it can become model context',
    () async {
      final adapter = SearchTestAdapter(
        (_, _) => ResponseBody(
          Stream.value(Uint8List(AgentWebSearchClient.maxResponseBytes + 1)),
          200,
        ),
      );
      await expectLater(
        AgentWebSearchClient(createDio: adapter.dio).search(
          engine: AgentSearchEngine.bing,
          query: 'Prime',
          run: AgentRun(),
        ),
        throwsA(searchError('SEARCH_RESPONSE_TOO_LARGE')),
      );
      expect(adapter.closed, true);
    },
  );

  test('an already cancelled run performs no HTTP request', () async {
    final adapter = SearchTestAdapter((_, _) => searchBody(searchRss));
    final run = AgentRun()..cancel();
    await expectLater(
      AgentWebSearchClient(
        createDio: adapter.dio,
      ).search(engine: AgentSearchEngine.bing, query: 'Prime', run: run),
      throwsA(searchError('CANCELLED')),
    );
    expect(adapter.requests, isEmpty);
  });
}
