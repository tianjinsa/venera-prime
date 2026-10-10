import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_blocking.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

Comic comic({
  String title = 'A comic',
  String? author,
  String description = '',
  List<String>? tags,
}) => Comic(title, '', '1', author, tags, description, 'test', null, null);

class _CountedComic implements Comic {
  int descriptionReads = 0;
  int tagReads = 0;
  @override
  String get title => 'Unrelated comic';
  @override
  String get subtitle => 'Unrelated author';
  @override
  String get description {
    descriptionReads++;
    return 'Unrelated description';
  }

  @override
  List<String> get tags {
    tagReads++;
    return ['genre:unrelated', 'artist:unrelated'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<dynamic> originalWords;
  late List<dynamic> originalAuthors;

  setUp(() {
    originalWords = appdata.settings['blockedWords'];
    originalAuthors = appdata.settings['blockedAuthors'];
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['blockedAuthors'] = <String>['sun'];
  });

  tearDown(() {
    appdata.settings['blockedWords'] = originalWords;
    appdata.settings['blockedAuthors'] = originalAuthors;
  });

  test('author blocks never match titles, descriptions or ordinary tags', () {
    expect(isBlocked(comic(author: 'sun')), 'sun');
    expect(isBlocked(comic(title: 'sun', author: 'someone')), isNull);
    expect(isBlocked(comic(description: 'sun', author: 'someone')), isNull);
    expect(isBlocked(comic(tags: ['sun', 'genre:sun'])), isNull);
    expect(isBlocked(comic(title: 'sun')), isNull);
  });

  test(
    'author matching uses the entire name and ignores surrounding spaces',
    () {
      expect(isBlocked(comic(author: 'sunshine')), isNull);
      expect(isBlocked(comic(author: ' sun ')), 'sun');
      appdata.settings['blockedAuthors'] = <String>[' ', ' sun '];
      expect(isBlocked(comic(author: '')), isNull);
      expect(isBlocked(comic(author: 'sun')), ' sun ');
    },
  );

  test(
    'explicit author and artist tags match independently of the subtitle',
    () {
      expect(isBlocked(comic(author: 'other', tags: ['artist:sun'])), 'sun');
      expect(isBlocked(comic(tags: ['author:sun'])), 'sun');
      expect(isBlocked(comic(tags: ['Artist: sun '])), 'sun');
      expect(isBlocked(comic(tags: ['artist:sunshine'])), isNull);
      expect(isBlocked(comic(tags: ['artist:'])), isNull);
    },
  );

  test('legacy keywords still match all previously supported fields', () {
    appdata.settings['blockedAuthors'] = <String>[];
    appdata.settings['blockedWords'] = <String>['sun'];
    expect(isBlocked(comic(title: 'sunshine')), 'sun');
    expect(isBlocked(comic(author: 'sunshine')), 'sun');
    expect(isBlocked(comic(description: 'sunshine')), 'sun');
    expect(isBlocked(comic(tags: ['sun'])), 'sun');
    expect(isBlocked(comic(tags: ['genre:sun'])), 'sun');
    expect(isBlocked(comic(title: 'other')), isNull);
  });

  test('keyword filtering can be skipped without disabling author rules', () {
    appdata.settings['blockedWords'] = <String>['blocked'];
    expect(
      isBlocked(comic(title: 'blocked'), filterBlockedWords: false),
      isNull,
    );
    expect(
      isBlocked(
        comic(title: 'blocked', author: 'sun'),
        filterBlockedWords: false,
      ),
      'sun',
    );
    expect(isBlocked(comic(title: 'blocked')), 'blocked');
  });

  test(
    'removing an author rule restores comics without deleting keyword rules',
    () {
      appdata.settings['blockedWords'] = <String>['other'];
      appdata.settings['blockedAuthors'].remove('sun');
      expect(isBlocked(comic(author: 'sun')), isNull);
      expect(isBlocked(comic(title: 'other')), 'other');
    },
  );

  test(
    'compiled rules retain literal, case-sensitive and exact-tag matching',
    () {
      for (final word in ['sun', 'a.b', '[x]', 'a+b', r'$5', '书名', '']) {
        final filter = ComicBlockFilter(words: [word], authors: []);
        for (final item in [
          comic(title: 'prefix ${word}suffix'),
          comic(author: word),
          comic(description: word),
          comic(tags: [word]),
          comic(tags: ['genre:$word:tail']),
          comic(title: 'Unrelated', tags: ['other']),
        ]) {
          appdata.settings['blockedAuthors'] = <String>[];
          appdata.settings['blockedWords'] = [word];
          expect(filter.blocks(item), isBlocked(item) != null);
        }
      }
      final filter = ComicBlockFilter(words: ['sun'], authors: []);
      expect(
        filter.blocks(comic(title: 'SUN', tags: ['genre:sunshine'])),
        isFalse,
      );
      expect(filter.blocks(comic(tags: ['genre: sun '])), isFalse);
      expect(filter.blocks(comic(tags: ['genre:sun:tail'])), isTrue);
      expect(
        ComicBlockFilter(
          words: ['tail'],
          authors: [],
        ).blocks(comic(tags: ['genre:sun:tail'])),
        isFalse,
      );
      expect(
        ComicBlockFilter(
          words: ['a.b'],
          authors: [],
        ).blocks(comic(title: 'axb')),
        isFalse,
      );
    },
  );

  test(
    'first reason follows rule order even for overlapping text and authors',
    () {
      final filter = ComicBlockFilter(
        words: ['late', 'sunshine', 'sun'],
        authors: [' other ', 'sun'],
      );
      expect(
        filter.firstReason(comic(title: 'sunshine', description: 'late')),
        'late',
      );
      expect(filter.firstReason(comic(title: 'sunshine')), 'sunshine');
      expect(
        filter.firstReason(comic(author: 'sun', tags: ['author:other'])),
        ' other ',
      );
      expect(
        filter.blocks(comic(author: 'sun'), filterBlockedWords: false),
        isTrue,
      );
    },
  );

  test(
    '1200 comics with 300 keywords compute metadata only once per comic',
    () {
      final words = List.generate(300, (i) => 'missing keyword $i');
      final filter = ComicBlockFilter(
        words: words,
        authors: ['missing author'],
      );
      final comics = List.generate(1200, (_) => _CountedComic());
      expect(comics.any(filter.blocks), isFalse);
      expect(comics.fold(0, (sum, item) => sum + item.descriptionReads), 1200);
      expect(comics.fold(0, (sum, item) => sum + item.tagReads), 1200);
      final item = _CountedComic();
      expect(filter.firstReason(item), isNull);
      expect(item.descriptionReads, 1);
      expect(item.tagReads, 1);
      final unfiltered = _CountedComic();
      expect(
        ComicBlockFilter(
          words: words,
          authors: [],
        ).blocks(unfiltered, filterBlockedWords: false),
        isFalse,
      );
      expect(unfiltered.descriptionReads, 0);
      expect(unfiltered.tagReads, 0);
    },
  );

  test('cached rules detect in-place edits without changing list lengths', () {
    final words = <String>['sun'];
    final authors = <String>['moon'];
    appdata.settings['blockedWords'] = words;
    appdata.settings['blockedAuthors'] = authors;
    expect(isBlocked(comic(title: 'sun')), 'sun');
    words[0] = 'star';
    expect(isBlocked(comic(title: 'sun')), isNull);
    expect(isBlocked(comic(title: 'star')), 'star');
    authors[0] = 'earth';
    expect(isBlocked(comic(author: 'moon')), isNull);
    expect(isBlocked(comic(author: 'earth')), 'earth');
  });
}
