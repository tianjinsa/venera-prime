import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

Comic comic({
  String title = 'A comic',
  String? author,
  String description = '',
  List<String>? tags,
}) => Comic(title, '', '1', author, tags, description, 'test', null, null);

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

  test(
    'removing an author rule restores comics without deleting keyword rules',
    () {
      appdata.settings['blockedWords'] = <String>['other'];
      appdata.settings['blockedAuthors'].remove('sun');
      expect(isBlocked(comic(author: 'sun')), isNull);
      expect(isBlocked(comic(title: 'other')), 'other');
    },
  );
}
