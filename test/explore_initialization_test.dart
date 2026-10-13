import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/explore_page.dart';

import 'support/source_fixture.dart';
import 'support/test_translations.dart';

Widget _initialExplorePage() => MaterialApp(
  home: NaviPane(
    observer: NaviObserver(),
    navigatorKey: GlobalKey<NavigatorState>(),
    initialPage: 2,
    paneItems: [
      for (final label in ['Home', 'Favorites', 'Explore'])
        PaneItemEntry(
          label: label,
          icon: Icons.explore,
          activeIcon: Icons.explore,
        ),
    ],
    paneActions: const [],
    pageBuilder: (_) => const ExplorePage(),
  ),
);

ExplorePageData _page(String title) => ExplorePageData(
  title,
  ExplorePageType.singlePageWithMultiPart,
  null,
  null,
  () async => Res([ExplorePagePart('$title content', const [], null)]),
  null,
);

void main() {
  setUp(() async => ensureTestTranslations());

  testWidgets('initial explore page reacts to delayed source readiness', (
    tester,
  ) async {
    final previous = appdata.settings['explore_pages'];
    final manager = ComicSourceManager();
    final source = sourceFixture(explore: [_page('Startup catalog')]);
    final ready = Completer<void>();
    final initialization = ready.future.then((_) => manager.add(source));
    appdata.settings['explore_pages'] = ['Startup catalog'];
    addTearDown(() {
      appdata.settings['explore_pages'] = previous;
      manager.remove(source.key);
    });

    await tester.pumpWidget(_initialExplorePage());
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ExplorePage));
    expect(find.byType(TabBarView), findsNothing);
    // Tapping the selected navigation item while sources load must be safe.
    tester.state<NaviPaneState>(find.byType(NaviPane)).updatePage(2);
    expect(tester.takeException(), isNull);

    ready.complete();
    await initialization;
    // The startup path publishes this after initialization and migration.
    manager.notifyStateChange();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ExplorePage)), same(state));
    expect(find.text('Startup catalog content'), findsOneWidget);
    expect(appdata.settings['explore_pages'], ['Startup catalog']);

    manager.remove(source.key);
    await tester.pumpAndSettle();
    expect(find.byType(TabBarView), findsNothing);
    manager.add(source);
    await tester.pumpAndSettle();
    expect(find.text('Startup catalog content'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    manager.notifyStateChange();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source changes preserve the selected catalog and update emptiness',
    (tester) async {
      final previous = appdata.settings['explore_pages'];
      final manager = ComicSourceManager();
      final source = sourceFixture(explore: [_page('First'), _page('Second')]);
      appdata.settings['explore_pages'] = ['First', 'Second'];
      manager.add(source);
      addTearDown(() {
        appdata.settings['explore_pages'] = previous;
        manager.remove(source.key);
      });

      await tester.pumpWidget(_initialExplorePage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      source.explorePages.add(_page('Third'));
      appdata.settings['explore_pages'] = ['First', 'Second', 'Third'];
      await tester.pumpAndSettle();
      expect(
        tester.widget<TabBarView>(find.byType(TabBarView)).controller!.index,
        1,
      );
      expect(find.text('Second content'), findsOneWidget);

      manager.remove(source.key);
      await tester.pumpAndSettle();
      expect(find.textContaining('Please add some sources'), findsOneWidget);
      manager.add(sourceFixture());
      await tester.pumpAndSettle();
      expect(find.textContaining('Please check your settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
