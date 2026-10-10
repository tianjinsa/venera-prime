import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_search_browser.dart';
import 'package:venera/agent/agent_web_search.dart';
import 'package:venera/foundation/app.dart';

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

  testWidgets('Bing official RSS returns usable public sources', (
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
    debugPrint('Bing live search: ${sources.length} public sources');
  }, skip: !live);

  testWidgets(
    'Google temporary WebView renders usable search results',
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
      debugPrint('Google live WebView: ${sources.length} public sources');
    },
    skip: !live || Platform.isLinux,
  );
}
