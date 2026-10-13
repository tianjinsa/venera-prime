import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/utils/translations.dart';

class _ExploreSource implements ComicSource {
  @override
  final key = 'explore_scroll_test';
  @override
  final name = 'Explore scroll test';
  @override
  final List<ExplorePageData> explorePages;
  @override
  Map<String, Map<String, String>>? get translations => null;

  _ExploreSource(this.explorePages);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('refresh visibility does not rebuild tabs and still refreshes', (
    tester,
  ) async {
    await AppTranslation.init();
    var loads = 0;
    final previous = appdata.settings['explore_pages'];
    final source = _ExploreSource([
      ExplorePageData(
        'Scroll test',
        ExplorePageType.singlePageWithMultiPart,
        null,
        null,
        () async {
          loads++;
          return Res([
            for (var i = 0; i < 20; i++)
              ExplorePagePart('Section $i', const [], null),
          ]);
        },
        null,
      ),
    ]);
    ComicSourceManager().add(source);
    appdata.settings['explore_pages'] = ['Scroll test'];
    addTearDown(() {
      appdata.settings['explore_pages'] = previous;
      ComicSourceManager().remove(source.key);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          observer: NaviObserver(),
          navigatorKey: GlobalKey<NavigatorState>(),
          paneItems: [
            PaneItemEntry(
              label: 'Explore',
              icon: Icons.explore,
              activeIcon: Icons.explore,
            ),
          ],
          paneActions: const [],
          pageBuilder: (_) => const ExplorePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBarView>(find.byType(TabBarView));
    final scrollContext = tester.element(find.byType(CustomScrollView));
    void notify(double pixels, AxisDirection direction) {
      ScrollUpdateNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 2000,
          pixels: pixels,
          viewportDimension: 600,
          axisDirection: direction,
          devicePixelRatio: 1,
        ),
        context: scrollContext,
        scrollDelta: 0,
      ).dispatch(scrollContext);
    }

    notify(120, AxisDirection.down);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(identical(tabs, tester.widget(find.byType(TabBarView))), isTrue);
    notify(40, AxisDirection.down);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(identical(tabs, tester.widget(find.byType(TabBarView))), isTrue);
    notify(160, AxisDirection.down);
    await tester.pumpAndSettle();
    notify(10, AxisDirection.right);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(identical(tabs, tester.widget(find.byType(TabBarView))), isTrue);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
