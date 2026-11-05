import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_search_browser.dart';
import 'package:venera/agent/agent_web_search.dart';
import 'package:venera/foundation/app.dart';

void expectProjectSource(List sources) {
  expect(
    sources.any((source) {
      final uri = Uri.tryParse(source['url'] as String? ?? '');
      final text = '${source['title']} ${source['url']}'.toLowerCase();
      return uri?.host == 'github.com' &&
          text.contains('venera') &&
          text.contains('prime');
    }),
    isTrue,
    reason: '不相关链接不能作为 Venera Prime 查询成功的证据',
  );
}

/// Opt in explicitly: this suite sends only the public query below, uses no
/// account keys, and keeps its WebView profile in a new temporary directory.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('PRIME_SEARCH_LIVE_TEST');
  const query = 'Venera Prime GitHub';
  late Directory directory;

  setUpAll(() async {
    if (!live) return;
    directory = await Directory.systemTemp.createTemp('prime-search-live-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await Rhttp.init();
  });

  tearDownAll(() async {
    if (!live) return;
    // WebView2 releases its profile asynchronously after disposal.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  testWidgets('Bing official search returns a source for the queried project', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final result = await const AgentWebSearchClient(loadPage: null).search(
      engine: AgentSearchEngine.bing,
      query: query,
      run: AgentRun(),
      maxResults: 3,
    );
    final sources = result['results'] as List;
    expect(sources, isNotEmpty);
    expect(sources.length, lessThanOrEqualTo(3));
    expect(sources.every((s) => Uri.parse(s['url']).hasAuthority), true);
    expectProjectSource(sources);
    debugPrint('Bing live search: ${sources.length} public sources');
  }, skip: !live);

  testWidgets(
    'Google temporary WebView renders a source for the queried project',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final page = await loadAgentSearchPage(
        AgentWebSearchClient.searchUrl(AgentSearchEngine.google, query, 3),
        AgentRun(),
      );
      final sources = AgentWebSearchClient.parseWebsite(
        AgentSearchEngine.google,
        page,
        3,
      );
      expect(sources, isNotEmpty);
      expect(sources.length, lessThanOrEqualTo(3));
      expectProjectSource(sources);
      debugPrint('Google live WebView: ${sources.length} public sources');
    },
    skip: !live || Platform.isLinux,
  );
}
