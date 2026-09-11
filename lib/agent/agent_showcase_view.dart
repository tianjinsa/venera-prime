import 'package:flutter/material.dart';
import 'package:venera/components/components.dart' show ComicTile;
import 'package:venera/foundation/appdata.dart';
import 'agent_disclosure.dart';
import 'agent_models.dart';
import 'agent_tools.dart';

class AgentShowcasePanel extends StatelessWidget {
  final String conversationId;
  final List<AgentShowcase> groups;
  final String? focusedGroup;
  final int focusRevision;
  final ScrollController? scroll;
  final VoidCallback? close;
  final VoidCallback clear;
  final void Function(String) hideGroup;
  final void Function(String, AgentComic) hideComic;
  const AgentShowcasePanel({
    super.key,
    required this.conversationId,
    required this.groups,
    this.focusedGroup,
    this.focusRevision = 0,
    this.scroll,
    this.close,
    required this.clear,
    required this.hideGroup,
    required this.hideComic,
  });

  @override
  Widget build(BuildContext context) {
    final discoveries = groups.where((g) => g.kind == 'discovery').toList();
    final favorites = groups.where((g) => g.kind == 'favorites').toList();
    final later = groups.where((g) => g.kind == 'later').toList();
    final focus = discoveries.indexWhere((g) => g.id == focusedGroup);
    if (focus > 0) discoveries.insert(0, discoveries.removeAt(focus));
    return Column(
      children: [
        ListTile(
          title: const Text('展示漫画'),
          trailing: close == null
              ? IconButton(
                  tooltip: '清空展示面板',
                  onPressed: groups.isEmpty ? null : clear,
                  icon: const Icon(Icons.clear_all),
                )
              : IconButton(
                  tooltip: '关闭',
                  onPressed: close,
                  icon: const Icon(Icons.close),
                ),
        ),
        if (close != null && groups.isNotEmpty)
          TextButton(onPressed: clear, child: const Text('清空展示面板')),
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Agent 展示或加入收藏、稍后再看的漫画会出现在这里',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  controller: scroll,
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final group in discoveries) _discovery(context, group),
                    if (favorites.isNotEmpty)
                      _container(
                        context,
                        'favorites-$conversationId',
                        AgentDisclosure(
                          storageId: 'showcase-favorites-$conversationId',
                          label: '收藏',
                          detail:
                              '${favorites.fold<int>(0, (n, g) => n + g.comics.length)} 本',
                          leading: const Icon(Icons.star_border_rounded),
                          initiallyExpanded: favorites.any(
                            (g) => g.id == focusedGroup,
                          ),
                          resetToken: favorites.any((g) => g.id == focusedGroup)
                              ? '$focusRevision'
                              : null,
                          builder: (_) => Column(
                            children: [
                              for (final group in favorites)
                                _operation(context, group),
                            ],
                          ),
                        ),
                      ),
                    for (final group in later)
                      _container(context, group.id, _operation(context, group)),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _container(BuildContext context, String id, Widget child) => Container(
    key: ValueKey(id),
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: id == focusedGroup
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: .35)
          : Theme.of(context).colorScheme.surfaceContainerLow,
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .45),
      ),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );

  Widget _menu(BuildContext context, AgentShowcase group) =>
      PopupMenuButton<String>(
        tooltip: '展示分组选项',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 120),
        icon: Icon(
          Icons.more_horiz,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onSelected: (_) => hideGroup(group.id),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'remove', child: Text('移除此组')),
        ],
      );

  Widget _operation(BuildContext context, AgentShowcase group) =>
      AgentDisclosure(
        storageId: 'showcase-${group.id}',
        label: group.kind == 'later' ? '稍后再看' : group.folder ?? group.title,
        detail: '${group.comics.length} 本',
        leading: Icon(
          group.kind == 'later' ? Icons.bookmark_border : Icons.folder_outlined,
        ),
        initiallyExpanded: group.id == focusedGroup,
        resetToken: group.id == focusedGroup ? '$focusRevision' : null,
        builder: (_) => _grid(context, group),
        trailing: SizedBox(width: 30, height: 40, child: _menu(context, group)),
      );

  Widget _discovery(BuildContext context, AgentShowcase group) => _container(
    context,
    group.id,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 8),
          title: Text(
            group.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${group.comics.length} 本'),
          trailing: _menu(context, group),
        ),
        if (group.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              group.note,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        _grid(context, group),
      ],
    ),
  );

  Widget _grid(BuildContext context, AgentShowcase group) {
    final detailed = appdata.settings['comicDisplayMode'] == 'detailed';
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(4),
      itemCount: group.comics.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: detailed ? 1 : 2,
        mainAxisExtent: detailed ? 136 : null,
        childAspectRatio: .48,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemBuilder: (_, index) {
        final comic = group.comics[index];
        final tile = ComicTile(
          comic: AgentTools.toComic(comic),
          heroID: Object.hash(group.id, comic.identity),
        );
        final remove = IconButton(
          key: ValueKey('remove-${group.id}-${comic.identity}'),
          tooltip: '从展示中移除',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: const EdgeInsets.all(6),
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          onPressed: () => hideComic(group.id, comic),
          icon: const Icon(Icons.close_rounded, size: 15),
        );
        return detailed
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: tile),
                  remove,
                ],
              )
            : Column(
                children: [
                  Expanded(child: tile),
                  Align(alignment: Alignment.centerRight, child: remove),
                ],
              );
      },
    );
  }
}
