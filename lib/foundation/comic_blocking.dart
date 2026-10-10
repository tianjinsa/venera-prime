import 'package:venera/foundation/comic_source/comic_source.dart';

/// An immutable rule snapshot shared by every item in a list update.
class ComicBlockFilter {
  ComicBlockFilter({
    required Iterable<String> words,
    required Iterable<String> authors,
  }) : words = List.unmodifiable(words),
       authors = List.unmodifiable(authors);

  final List<String> words;
  final List<String> authors;

  late final _authorSet = authors
      .map((author) => author.trim())
      .where((author) => author.isNotEmpty)
      .toSet();
  late final _wordSet = words.toSet();
  // Escape every rule: keywords are literal, case-sensitive substrings.
  // History skips keywords, so it never needs to compile this pattern.
  late final _wordPattern = RegExp(words.map(RegExp.escape).join('|'));

  bool blocks(Comic comic, {bool filterBlockedWords = true}) {
    if (_authorSet.isEmpty && (!filterBlockedWords || words.isEmpty)) {
      return false;
    }
    final data = _BlockingData(comic);
    if (_authorSet.isNotEmpty && data.authors.any(_authorSet.contains)) {
      return true;
    }
    if (!filterBlockedWords || words.isEmpty) return false;
    return _wordPattern.hasMatch(data.title) ||
        (data.subtitle != null && _wordPattern.hasMatch(data.subtitle!)) ||
        _wordPattern.hasMatch(data.description) ||
        data.tagWords.any(_wordSet.contains);
  }

  /// Preserve rule order when a caller needs the original blocking reason.
  String? firstReason(Comic comic, {bool filterBlockedWords = true}) {
    final data = _BlockingData(comic);
    for (final author in authors) {
      final normalized = author.trim();
      if (normalized.isNotEmpty && data.authors.contains(normalized)) {
        return author;
      }
    }
    if (!filterBlockedWords) return null;
    for (final word in words) {
      if (data.title.contains(word) ||
          (data.subtitle?.contains(word) ?? false) ||
          data.description.contains(word) ||
          data.tagWords.contains(word)) {
        return word;
      }
    }
    return null;
  }

  static Set<String> authorsOf(Comic comic) => _BlockingData(comic).authors;

  static String? authorFromTag(String tag) => _BlockingData._authorFromTag(tag);
}

class _BlockingData {
  _BlockingData(this.comic);

  final Comic comic;
  late final String title = comic.title;
  late final String? subtitle = comic.subtitle;
  late final String description = comic.description;
  late final List<String> tags = comic.tags ?? const [];
  late final Set<String> authors = {
    if (subtitle?.trim().isNotEmpty ?? false) subtitle!.trim(),
    for (final tag in tags)
      if (_authorFromTag(tag) case final String author) author,
  };
  late final Set<String> tagWords = {
    for (final tag in tags) ...[
      tag,
      // Keep the legacy tag.split(':')[1] semantics, including empty values.
      if (tag.contains(':')) tag.split(':')[1],
    ],
  };

  static String? _authorFromTag(String tag) {
    final separator = tag.indexOf(':');
    if (separator < 0) return null;
    final namespace = tag.substring(0, separator).trim().toLowerCase();
    if (namespace != 'artist' && namespace != 'author') return null;
    final author = tag.substring(separator + 1).trim();
    return author.isEmpty ? null : author;
  }
}
