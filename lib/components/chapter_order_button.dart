import 'package:flutter/material.dart';
import 'package:venera/utils/chapter_order.dart';
import 'package:venera/utils/chapter_navigation.dart';
import 'package:venera/utils/translations.dart';

class ChapterOrderButton extends StatelessWidget {
  const ChapterOrderButton({
    super.key,
    required this.comicId,
    required this.sourceKey,
    required this.onChanged,
  });
  final String comicId;
  final String sourceKey;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ChapterOrder>(
    key: const Key('chapter-order'),
    tooltip: 'Directory display order'.tl,
    initialValue: ChapterOrder.forComic(comicId, sourceKey),
    icon: const Icon(Icons.sort),
    itemBuilder: (_) => [
      for (final order in ChapterOrder.values)
        CheckedPopupMenuItem(
          value: order,
          checked: order == ChapterOrder.forComic(comicId, sourceKey),
          child: Text(order.label.tl),
        ),
    ],
    onSelected: (order) {
      order.save(comicId, sourceKey);
      onChanged();
    },
  );
}

class ChapterReadingOrderButton extends StatelessWidget {
  const ChapterReadingOrderButton({
    super.key,
    required this.comicId,
    required this.sourceKey,
    required this.onChanged,
  });
  final String comicId;
  final String sourceKey;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ChapterReadingOrder>(
    key: const Key('chapter-reading-order'),
    tooltip: 'Chapter reading order'.tl,
    initialValue: ChapterReadingOrder.forComic(comicId, sourceKey),
    icon: const Icon(Icons.swap_vert),
    itemBuilder: (_) => [
      for (final order in ChapterReadingOrder.values)
        CheckedPopupMenuItem(
          value: order,
          checked: order == ChapterReadingOrder.forComic(comicId, sourceKey),
          child: Text(order.label.tl),
        ),
    ],
    onSelected: (order) {
      order.save(comicId, sourceKey);
      onChanged();
    },
  );
}
