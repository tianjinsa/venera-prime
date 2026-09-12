import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/agent/agent_showcase_view.dart';
import 'package:venera/components/components.dart' show ComicTile;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';

import 'agent_test_support.dart';

const _conversation = 'large-showcase';
const _comicCount = 600;

AgentShowcase _group(
  String id, {
  String kind = 'discovery',
  int count = _comicCount,
}) => AgentShowcase(
  id: id,
  title: '分组 $id',
  note: kind == 'discovery' ? '完整结果可以滚动查看' : '',
  createdAt: 1,
  kind: kind,
  folder: kind == 'favorites' ? '收藏夹 $id' : null,
  comics: [
    for (var i = 0; i < count; i++)
      AgentComic(
        sourceKey: 'local',
        comicId: '$id-$i',
        title: '$id 的漫画 $i',
        subtitle: '漫画简介',
      ),
  ],
);

/// Count actual ComicTile builds, including any transient work that would be
/// invisible to a final mounted-widget count after a viewport correction.
class _CardBuilds {
  final ids = <String>{};
  int calls = 0;
  int maxMounted = 0;
  int maxDistinctBuilds = 0;
  int maxBuildCalls = 0;

  void record(Element element, bool builtOnce) {
    final widget = element.widget;
    if (widget is ComicTile) {
      ids.add(widget.comic.id);
      calls++;
    }
  }

  void reset() {
    ids.clear();
    calls = 0;
  }

  void expectBounded(WidgetTester tester, String action) {
    final mounted = find
        .byType(ComicTile, skipOffstage: false)
        .evaluate()
        .length;
    if (mounted > maxMounted) maxMounted = mounted;
    if (ids.length > maxDistinctBuilds) maxDistinctBuilds = ids.length;
    if (calls > maxBuildCalls) maxBuildCalls = calls;
    // Count the complete element tree: offstage slivers and cached cards are
    // still mounted even when visitOnstageChildren hides them from finders.
    // A 304x800 viewport fits fewer than ten cards in either layout. The loose
    // bounds allow several screens of cache and transient layout work, while
    // rejecting eager construction of a 600-item group.
    expect(mounted, inInclusiveRange(1, 32), reason: '$action: mounted cards');
    expect(
      ids.length,
      lessThanOrEqualTo(64),
      reason: '$action: $calls builds across ${ids.length} different cards',
    );
    expect(tester.takeException(), isNull);
  }
}

class _ShowcaseHarness extends StatefulWidget {
  final List<AgentShowcase> groups;
  final ScrollController scroll;

  const _ShowcaseHarness({
    super.key,
    required this.groups,
    required this.scroll,
  });

  @override
  State<_ShowcaseHarness> createState() => _ShowcaseHarnessState();
}

class _ShowcaseHarnessState extends State<_ShowcaseHarness> {
  late List<AgentShowcase> groups = List.of(widget.groups);
  final hiddenComics = <(String, String)>[];
  final hiddenGroups = <String>[];
  String? focusedGroup;
  int focusRevision = 0;

  void focus(String id) {
    setState(() {
      focusedGroup = id;
      focusRevision++;
    });
    // Match AgentPage's explicit navigation to the top of the focused panel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scroll.hasClients) widget.scroll.jumpTo(0);
    });
  }

  void _hideGroup(String id) => setState(() {
    hiddenGroups.add(id);
    groups.removeWhere((group) => group.id == id);
  });

  void _hideComic(String id, AgentComic comic) => setState(() {
    hiddenComics.add((id, comic.identity));
    final index = groups.indexWhere((group) => group.id == id);
    final group = groups[index];
    final remaining = group.comics
        .where((c) => c.identity != comic.identity)
        .toList();
    if (remaining.isEmpty) {
      groups.removeAt(index);
    } else {
      groups[index] = AgentShowcase(
        id: group.id,
        title: group.title,
        note: group.note,
        createdAt: group.createdAt,
        kind: group.kind,
        folder: group.folder,
        comics: remaining,
      );
    }
  });

  @override
  Widget build(BuildContext context) => AgentShowcasePanel(
    conversationId: _conversation,
    groups: groups,
    focusedGroup: focusedGroup,
    focusRevision: focusRevision,
    scroll: widget.scroll,
    clear: () => setState(groups.clear),
    hideGroup: _hideGroup,
    hideComic: _hideComic,
  );
}

Finder _comic(String id) => find.byWidgetPredicate(
  (widget) => widget is ComicTile && widget.comic.id == id,
  skipOffstage: false,
);

Finder _toggle(String id) => find.byKey(ValueKey('toggle-showcase-$id'));

Future<void> _jump(
  WidgetTester tester,
  ScrollController scroll,
  double fraction,
) async {
  scroll.jumpTo(scroll.position.maxScrollExtent * fraction);
  await tester.pumpAndSettle();
}

Future<void> _endAt(
  WidgetTester tester,
  ScrollController scroll,
  Finder target,
) async {
  // Variable-height headers may refine an estimated extent after a jump.
  // Follow those finite layout corrections, without polling wall-clock time.
  for (var i = 0; i < 5; i++) {
    await _jump(tester, scroll, 1);
    if (target.hitTestable().evaluate().isNotEmpty) return;
  }
  expect(target.hitTestable(), findsOneWidget);
}

void main() {
  Future<void> withShowcases(
    WidgetTester tester,
    String mode,
    List<AgentShowcase> groups,
    Future<void> Function(_ShowcaseHarnessState, ScrollController, _CardBuilds)
    body,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('venera-showcase-performance-'),
    ))!;
    configureAgentTestPaths(root.path);
    final previousMode = appdata.settings['comicDisplayMode'];
    final previousFavorite = appdata.settings['showFavoriteStatusOnTile'];
    final previousHistory = appdata.settings['showHistoryStatusOnTile'];
    appdata.settings['comicDisplayMode'] = mode;
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    final local = LocalManager()..close();
    await tester.runAsync(() async {
      await local.init();
      await ComicSourceManager().ensureInit();
      await appdata.saveData(false);
    });
    final scroll = ScrollController();
    final key = GlobalKey<_ShowcaseHarnessState>();
    final builds = _CardBuilds();
    final previousBuildCallback = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      builds.record(element, builtOnce);
      previousBuildCallback?.call(element, builtOnce);
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(304, 800);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _ShowcaseHarness(key: key, groups: groups, scroll: scroll),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body(key.currentState!, scroll, builds);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('VENERA_SHOWCASE_METRICS')) {
        debugPrint(
          'Showcase $mode ${groups.first.id}: '
          'mounted max=${builds.maxMounted}, '
          'distinct builds per action max=${builds.maxDistinctBuilds}, '
          'build calls per action max=${builds.maxBuildCalls}',
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugOnRebuildDirtyWidget = previousBuildCallback;
      scroll.dispose();
      local.close();
      appdata.settings['comicDisplayMode'] = previousMode;
      appdata.settings['showFavoriteStatusOnTile'] = previousFavorite;
      appdata.settings['showHistoryStatusOnTile'] = previousHistory;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  }

  for (final mode in ['detailed', 'brief']) {
    testWidgets(
      'large discovery groups build only nearby cards in $mode mode',
      (tester) async {
        final group = _group('discovery');
        await withShowcases(tester, mode, [group], (
          state,
          scroll,
          builds,
        ) async {
          builds.expectBounded(tester, 'initial discovery');
          expect(builds.ids, isNotEmpty);
          expect(_comic(group.comics.first.comicId), findsOneWidget);
          expect(_comic(group.comics.last.comicId), findsNothing);
          final initial = builds.ids.toSet();
          builds.reset();
          await _jump(tester, scroll, .5);
          builds.expectBounded(tester, 'middle of discovery');
          expect(builds.ids.difference(initial), isNotEmpty);
          builds.reset();
          await _endAt(tester, scroll, _comic(group.comics.last.comicId));
          builds.expectBounded(tester, 'end of discovery');
          final last = group.comics.last;
          final remove = find.byKey(
            ValueKey('remove-${group.id}-${last.identity}'),
          );
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          builds.reset();
          await tester.tap(remove);
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'remove last discovery card');
          expect(state.hiddenComics, [(group.id, last.identity)]);
          expect(state.groups.single.comics, hasLength(_comicCount - 1));
          expect(_comic(last.comicId), findsNothing);
          builds.reset();
          await _jump(tester, scroll, 0);
          builds.expectBounded(tester, 'return to discovery start');
          expect(
            _comic(group.comics.first.comicId).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('展示分组选项'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('移除此组'));
          await tester.pumpAndSettle();
          expect(state.hiddenGroups, [group.id]);
          expect(state.groups, isEmpty);
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
        });
      },
    );

    testWidgets(
      'large favorite folders stay lazy through folding and focus in $mode mode',
      (tester) async {
        final first = _group('first-folder', kind: 'favorites');
        final second = _group('second-folder', kind: 'favorites');
        final later = _group('later', kind: 'later');
        await withShowcases(tester, mode, [first, second, later], (
          state,
          scroll,
          builds,
        ) async {
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
          expect(builds.ids, isEmpty);
          expect(find.text(first.folder!), findsNothing);
          await tester.tap(_toggle('favorites-$_conversation'));
          await tester.pumpAndSettle();
          expect(find.text(first.folder!), findsOneWidget);
          expect(find.text(second.folder!), findsOneWidget);
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
          builds.reset();
          await tester.tap(_toggle(first.id));
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'expand first favorite folder');
          expect(_comic(first.comics.first.comicId), findsOneWidget);
          expect(_comic(second.comics.first.comicId), findsNothing);
          expect(_comic(first.comics.last.comicId), findsNothing);
          builds.reset();
          await _jump(tester, scroll, .5);
          builds.expectBounded(tester, 'scroll first favorite folder');
          await _jump(tester, scroll, 0);
          await tester.tap(_toggle(first.id));
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
          builds.reset();
          await tester.tap(_toggle(second.id));
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'expand second favorite folder');
          await tester.tap(_toggle('favorites-$_conversation'));
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
          builds.reset();
          await tester.tap(_toggle('favorites-$_conversation'));
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'restore expanded favorite folder');
          expect(_comic(second.comics.first.comicId), findsOneWidget);
          expect(_comic(first.comics.first.comicId), findsNothing);
          await tester.tap(_toggle(second.id));
          await tester.pumpAndSettle();
          await tester.tap(_toggle('favorites-$_conversation'));
          await tester.pumpAndSettle();
          builds.reset();
          state.focus(second.id);
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'focus closed favorite folder');
          expect(
            _comic(second.comics.first.comicId).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(_toggle(second.id));
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
          builds.reset();
          state.focus(second.id);
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'focus the same folder again');
          expect(
            _comic(second.comics.first.comicId).hitTestable(),
            findsOneWidget,
          );
          builds.reset();
          await _endAt(tester, scroll, _toggle(later.id));
          builds.expectBounded(tester, 'reach later group');
          builds.reset();
          await tester.tap(_toggle(later.id));
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'expand later group');
          builds.reset();
          await _endAt(tester, scroll, _comic(later.comics.last.comicId));
          builds.expectBounded(tester, 'end of later group');
          final last = later.comics.last;
          final remove = find.byKey(
            ValueKey('remove-${later.id}-${last.identity}'),
          );
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          builds.reset();
          await tester.tap(remove);
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'remove later card');
          expect(state.hiddenComics, [(later.id, last.identity)]);
          expect(
            state.groups.firstWhere((g) => g.id == second.id).comics,
            hasLength(_comicCount),
          );
        });
      },
    );

    testWidgets(
      'focus brings a distant discovery forward without building intervening cards in $mode mode',
      (tester) async {
        final first = _group('old-results');
        final target = _group('target-results');
        await withShowcases(tester, mode, [first, target], (
          state,
          scroll,
          builds,
        ) async {
          builds.expectBounded(tester, 'initial multiple discoveries');
          expect(_comic(target.comics.last.comicId), findsNothing);
          builds.reset();
          await _endAt(tester, scroll, _comic(target.comics.last.comicId));
          builds.expectBounded(tester, 'scroll to distant discovery');
          builds.reset();
          state.focus(target.id);
          await tester.pumpAndSettle();
          builds.expectBounded(tester, 'focus distant discovery');
          expect(scroll.offset, 0);
          expect(find.text(target.title).hitTestable(), findsOneWidget);
          expect(
            _comic(target.comics.first.comicId).hitTestable(),
            findsOneWidget,
          );
          expect(
            _comic(first.comics.first.comicId).hitTestable(),
            findsNothing,
          );
          expect(_comic(target.comics.last.comicId), findsNothing);
        });
      },
    );
  }

  testWidgets(
    'many favorite folders scroll correctly without creating collapsed comic content',
    (tester) async {
      final groups = [
        for (var i = 0; i < 160; i++)
          _group('many-folder-$i', kind: 'favorites', count: 1),
      ];
      Finder folderHeaders() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('toggle-showcase-many-folder-');
      }, skipOffstage: false);
      await withShowcases(tester, 'brief', groups, (
        state,
        scroll,
        builds,
      ) async {
        await tester.tap(_toggle('favorites-$_conversation'));
        await tester.pumpAndSettle();
        expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
        if (const bool.fromEnvironment('VENERA_SHOWCASE_METRICS')) {
          debugPrint(
            'Favorite folder headers mounted in full tree: '
            '${folderHeaders().evaluate().length}/${groups.length}',
          );
        }
        // Header slivers currently exist before they enter the viewport. Only
        // comic-card creation is lazy; do not confuse visibility with mounting.
        expect(_toggle(groups.first.id).hitTestable(), findsOneWidget);
        expect(_toggle(groups.last.id).hitTestable(), findsNothing);
        await _endAt(tester, scroll, _toggle(groups.last.id));
        expect(_toggle(groups.last.id).hitTestable(), findsOneWidget);
        expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
        expect(builds.ids, isEmpty);
        builds.reset();
        await tester.tap(_toggle(groups.last.id));
        await tester.pumpAndSettle();
        await _endAt(tester, scroll, _comic(groups.last.comics.single.comicId));
        builds.expectBounded(tester, 'open last of many favorite folders');
        expect(find.byType(ComicTile, skipOffstage: false), findsOneWidget);
        expect(builds.ids, {groups.last.comics.single.comicId});
        await tester.tap(_toggle(groups.last.id));
        await tester.pumpAndSettle();
        expect(find.byType(ComicTile, skipOffstage: false), findsNothing);
      });
    },
  );
}
