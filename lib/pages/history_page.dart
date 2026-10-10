import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_pager.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late final _pager = HistoryPager(manager: HistoryManager());
  final _scrollController = ScrollController();
  final _gridKey = GlobalKey<SliverGridComicsState>();

  String? _dragDate() {
    final comic = _gridKey.currentState?.firstVisibleComic;
    return comic is History ? comic.lastReadTime.split(' ').first : null;
  }

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onPageChanged);
    _scrollController.addListener(_maybeLoadMore);
    unawaited(_reloadHistory());
    HistoryManager().addListener(onUpdate);
    ComicSourceManager().addListener(onUpdate);
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    ComicSourceManager().removeListener(onUpdate);
    _searchTimer?.cancel();
    _reloadTimer?.cancel();
    _pager.dispose();
    _scrollController.dispose();
    searchController.dispose();
    super.dispose();
  }

  void onUpdate() {
    // Cover refreshes can notify once per visible comic. Read one snapshot
    // for the burst instead of reloading the database for every notification.
    _reloadTimer ??= Timer(const Duration(milliseconds: 100), () {
      _reloadTimer = null;
      _searchTimer?.cancel();
      unawaited(_reloadHistory());
    });
  }

  void _onPageChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  void _maybeLoadMore() {
    if (!mounted ||
        !_scrollController.hasClients ||
        (_searchTimer?.isActive ?? false) ||
        _pager.query != query) {
      return;
    }
    final position = _scrollController.position;
    if (position.extentAfter < position.viewportDimension * 2) {
      unawaited(_pager.loadMore());
    }
  }

  Future<bool> _reloadHistory({bool keepLoaded = true}) async {
    final loaded = await _pager.reload(query: query, keepLoaded: keepLoaded);
    if (!mounted || !loaded) return false;
    if (multiSelectMode && selectedComics.isNotEmpty) {
      final revision = _pager.revision;
      final selectionRequest = _selectionRequest;
      try {
        final remaining = await HistoryManager().getMatchingIds(query: query);
        if (!mounted ||
            revision != _pager.revision ||
            selectionRequest != _selectionRequest ||
            !multiSelectMode) {
          return false;
        }
        setState(() {
          selectedComics.retainAll(remaining);
          if (selectedComics.isEmpty) multiSelectMode = false;
        });
      } catch (_) {
        // A later refresh can reconcile selection; the loaded page is usable.
      }
    }
    return true;
  }

  List<History> get comics => _pager.items;
  var controller = FlyoutController();
  final searchController = TextEditingController();
  Timer? _searchTimer;
  Timer? _reloadTimer;
  bool searchMode = false;
  String query = '';

  Future<bool> _applyQuery() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    return _reloadHistory(keepLoaded: false);
  }

  void _search(String value) {
    _searchTimer?.cancel();
    setState(() {
      query = value;
      selectedComics.clear();
      _selectionRequest++;
      _selectingAll = false;
      multiSelectMode = false;
    });
    if (query.trim().isEmpty) {
      unawaited(_applyQuery());
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 200), () {
      _searchTimer = null;
      unawaited(_applyQuery());
    });
  }

  void _closeSearch() {
    _searchTimer?.cancel();
    searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      searchMode = false;
    });
    _search('');
  }

  Future<void> _enterMultiSelect() async {
    final request = ++_selectionRequest;
    _searchTimer?.cancel();
    FocusScope.of(context).unfocus();
    final requestedQuery = query;
    if (_pager.query != query || _pager.isReloading || _pager.error != null) {
      if (!await _applyQuery()) return;
    }
    if (mounted && request == _selectionRequest && query == requestedQuery) {
      setState(() => multiSelectMode = true);
    }
  }

  void _exitMultiSelect() {
    setState(() {
      multiSelectMode = false;
      selectedComics.clear();
      _selectionRequest++;
      _selectingAll = false;
    });
  }

  bool multiSelectMode = false;
  Set<ComicID> selectedComics = {};
  bool _selectingAll = false;
  int _selectionRequest = 0;

  ComicID _identity(History comic) => ComicID(comic.type, comic.id);

  Future<void> _selectAcrossQuery({bool invert = false}) async {
    if (_selectingAll) return;
    final request = ++_selectionRequest;
    final revision = _pager.revision;
    setState(() => _selectingAll = true);
    try {
      final identities = await HistoryManager().getMatchingIds(query: query);
      if (!mounted ||
          request != _selectionRequest ||
          revision != _pager.revision ||
          !multiSelectMode) {
        return;
      }
      setState(() {
        selectedComics = invert
            ? identities.difference(selectedComics)
            : identities;
      });
    } catch (_) {
      if (mounted && request == _selectionRequest) {
        context.showMessage(message: 'Failed to load history'.tl);
      }
    } finally {
      if (mounted && request == _selectionRequest) {
        setState(() => _selectingAll = false);
      }
    }
  }

  Future<void> selectAll() => _selectAcrossQuery();

  void deSelect() {
    setState(() {
      selectedComics.clear();
      _selectionRequest++;
      _selectingAll = false;
    });
  }

  Future<void> invertSelection() => _selectAcrossQuery(invert: true);

  void _removeHistory(History comic) {
    HistoryManager().remove(comic.id, comic.type);
  }

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    await for (var progress in HistoryManager().refreshAllHistoriesStream()) {
      if (isCanceled) {
        return;
      }
      if (progress.total > 0) {
        loadingController.setProgress(progress.current / progress.total);
      }
      success = progress.success;
      failed = progress.failed;
      skipped = progress.skipped;
    }

    loadingController.close();

    if (mounted) {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
                  'success': success,
                  'failed': failed,
                  'skipped': skipped,
                }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: _selectingAll ? null : selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: _selectingAll ? null : invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty || _selectingAll
            ? null
            : () {
                final comicsToDelete = selectedComics.toList();
                _exitMultiSelect();

                HistoryManager().batchDeleteHistories(comicsToDelete);
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.search),
        tooltip: 'Search'.tl,
        onPressed: () => setState(() => searchMode = true),
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: _enterMultiSelect,
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    final searchActions = [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          tooltip: 'Clear'.tl,
          onPressed: () {
            searchController.clear();
            _search('');
          },
        ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: 'Multi-Select'.tl,
        onPressed: _enterMultiSelect,
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          _exitMultiSelect();
        } else if (searchMode) {
          _closeSearch();
        }
      },
      child: Scaffold(
        body: AppScrollBar(
          controller: _scrollController,
          topPadding: MediaQuery.paddingOf(context).top + 52,
          dragLabelBuilder: _dragDate,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _maybeLoadMore(),
              );
              return false;
            },
            child: SmoothCustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverAppbar(
                  leading: Tooltip(
                    message: multiSelectMode || searchMode
                        ? "Cancel".tl
                        : "Back".tl,
                    child: IconButton(
                      onPressed: () {
                        if (multiSelectMode) {
                          _exitMultiSelect();
                        } else if (searchMode) {
                          _closeSearch();
                        } else {
                          context.pop();
                        }
                      },
                      icon: multiSelectMode || searchMode
                          ? const Icon(Icons.close)
                          : const Icon(Icons.arrow_back),
                    ),
                  ),
                  title: multiSelectMode
                      ? Text(selectedComics.length.toString())
                      : searchMode
                      ? TextField(
                          controller: searchController,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: 'Search'.tl,
                            border: InputBorder.none,
                          ),
                          onChanged: _search,
                        )
                      : Text('History'.tl),
                  actions: multiSelectMode
                      ? selectActions
                      : searchMode
                      ? searchActions
                      : normalActions,
                ),
                SliverGridComics(
                  key: _gridKey,
                  comics: comics,
                  listenToHistoryChanges: false,
                  filterBlockedWords: false,
                  selections: {
                    for (final comic in comics)
                      if (selectedComics.contains(_identity(comic)))
                        comic: true,
                  },
                  onLongPressed: null,
                  onTap: multiSelectMode
                      ? (c, heroID) {
                          setState(() {
                            _selectionRequest++;
                            _selectingAll = false;
                            final identity = _identity(c as History);
                            if (selectedComics.contains(identity)) {
                              selectedComics.remove(identity);
                            } else {
                              selectedComics.add(identity);
                            }
                            if (selectedComics.isEmpty) {
                              multiSelectMode = false;
                            }
                          });
                        }
                      : null,
                  badgeBuilder: (c) {
                    return ComicSource.find(c.sourceKey)?.name;
                  },
                  menuBuilder: (c) {
                    return [
                      MenuEntry(
                        icon: Icons.refresh,
                        text: 'Refresh Info'.tl,
                        onClick: () {
                          _refreshHistory(c as History);
                        },
                      ),
                      MenuEntry(
                        icon: Icons.remove,
                        text: 'Remove'.tl,
                        color: context.colorScheme.error,
                        onClick: () {
                          _removeHistory(c as History);
                        },
                      ),
                    ];
                  },
                ),
                if (_pager.error != null)
                  SliverToBoxAdapter(
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () => unawaited(_pager.retry()),
                        icon: const Icon(Icons.refresh),
                        label: Text('Retry'.tl),
                      ),
                    ),
                  )
                else if (_pager.loading)
                  const SliverListLoadingIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": h.ep});
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": h.page});
    }
    return res;
  }
}
