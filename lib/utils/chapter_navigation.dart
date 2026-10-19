import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/cache.dart';

enum ChapterReadingOrder {
  automatic('Automatic (chapter links)'),
  source('Source order (earliest first)'),
  reverse('Source order (latest first)');

  const ChapterReadingOrder(this.label);
  final String label;

  static ChapterReadingOrder forComic(String id, String sourceKey) {
    final saved = appdata.settings['comicChapterReadingOrder'];
    final value = saved is Map ? saved['$id@$sourceKey'] : null;
    return values.firstWhere(
      (order) => order.name == value,
      orElse: () => automatic,
    );
  }

  void save(String id, String sourceKey) {
    final saved = appdata.settings['comicChapterReadingOrder'];
    appdata.settings['comicChapterReadingOrder'] = <String, dynamic>{
      if (saved is Map) ...Map<String, dynamic>.from(saved),
      '$id@$sourceKey': name,
    };
    appdata.saveData();
  }
}

/// A verified chapter-ID relation from the page the source already fetched.
/// No title/ID-number inference, script execution or additional requests.
class ChapterNavigation {
  const ChapterNavigation({required this.previous, required this.next});
  final int? previous;
  final int? next;

  static String? pageKey(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return uri
        .replace(fragment: '', path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
        .toString();
  }

  static (int, int) groupRange(ComicChapters chapters, int current) {
    if (!chapters.isGrouped) return (1, chapters.length);
    var start = 1;
    for (final group in chapters.groups) {
      final end = start + chapters.getGroup(group).length - 1;
      if (current >= start && current <= end) return (start, end);
      start = end + 1;
    }
    return (1, 0);
  }

  static ChapterNavigation? fromHtml(
    String document,
    ComicChapters chapters,
    int current,
  ) {
    final ids = chapters.ids.toList();
    if (current < 1 || current > ids.length) return null;
    final base = Uri.tryParse(ids[current - 1]);
    if (base == null || pageKey(base.toString()) == null) return null;
    final range = groupRange(chapters, current);
    final targets = <bool, Set<int?>>{};
    for (final link in html.parse(document).querySelectorAll('a')) {
      final label =
          [link.attributes['aria-label'], link.attributes['title'], link.text]
              .whereType<String>()
              .firstWhere((text) => text.trim().isNotEmpty, orElse: () => '')
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'[\s←→‹›«»]'), '');
      final forward = switch (label) {
        '下一章' || '下一话' || '下一話' || '下一回' || 'nextchapter' => true,
        '上一章' ||
        '上一话' ||
        '上一話' ||
        '上一回' ||
        'previouschapter' ||
        'prevchapter' => false,
        _ => null,
      };
      if (forward == null) continue;
      var href = link.attributes['href']?.trim() ?? '';
      if (href.isEmpty || href == '#' || href == 'javascript:void(0);') {
        targets.putIfAbsent(forward, () => {}).add(null);
        continue;
      }
      if (href.toLowerCase().startsWith('javascript:')) {
        // Literal navigation URL only. Never evaluate source page scripts.
        final match = RegExp(
          r'''^javascript:\s*pushHistory\(\s*['"]([^'"]+)['"]\s*\);?\s*$''',
          caseSensitive: false,
        ).firstMatch(href);
        if (match == null) continue;
        href = match.group(1)!;
      }
      final target = Uri.tryParse(href);
      if (target == null) return null;
      final key = pageKey(base.resolveUri(target).toString());
      if (key == null) return null;
      final matches = [
        for (var i = range.$1; i <= range.$2; i++)
          if (pageKey(ids[i - 1]) == key) i,
      ];
      if (matches.length != 1 || matches.single == current) return null;
      targets.putIfAbsent(forward, () => {}).add(matches.single);
    }
    // An absent link is not evidence that the current chapter is a boundary.
    if (!targets.containsKey(false) ||
        !targets.containsKey(true) ||
        targets.values.any((values) => values.length != 1)) {
      return null;
    }
    final previous = targets[false]?.single;
    final next = targets[true]?.single;
    if (previous == null && next == null ||
        previous != null && previous == next) {
      return null;
    }
    return ChapterNavigation(previous: previous, next: next);
  }

  static ChapterNavigation? fromCache(ComicChapters? chapters, int current) {
    if (chapters == null || current < 1 || current > chapters.length) {
      return null;
    }
    final id = chapters.ids.elementAt(current - 1);
    final uri = Uri.tryParse(id);
    if (uri == null || pageKey(id) == null) return null;
    // Some sources append a slash to an ID which already ends in a slash.
    for (final path in {
      uri.path,
      '${uri.path}/',
      uri.path.replaceFirst(RegExp(r'/+$'), ''),
    }) {
      final cached = NetworkCacheManager().getCache(uri.replace(path: path));
      if (cached == null) continue;
      final data = cached.data;
      final body = data is String
          ? data
          : data is List<int>
          ? utf8.decode(data, allowMalformed: true)
          : null;
      if (body != null) {
        final result = fromHtml(body, chapters, current);
        if (result != null) return result;
      }
    }
    return null;
  }

  /// Learn a group direction only when explicit links identify adjacent raw IDs.
  bool? descendingFrom(int current) {
    final deltas = [
      if (previous != null) current - previous!,
      if (next != null) next! - current,
    ];
    if (deltas.isEmpty ||
        deltas.any((d) => d.abs() != 1) ||
        deltas.toSet().length != 1) {
      return null;
    }
    return deltas.first < 0;
  }
}
