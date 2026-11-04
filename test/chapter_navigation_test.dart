import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/utils/chapter_navigation.dart';

// Verified against the site's chapter 89 links on 2026-10-17.
const chapters = ComicChapters.grouped({
  '连载': {
    'https://www.manhuaren.com/m103988/': '第90话',
    'https://www.manhuaren.com/m103987/': '第89话',
    'https://www.manhuaren.com/m103986/': '第88话',
  },
});
const page = '''
<a href="javascript:pushHistory('/m103986/');">上一章</a>
<a href="javascript:prevPage();">上一页</a>
<a href="javascript:nextPage();">下一页</a>
<a href="javascript:pushHistory('/m103988/');">下一章</a>
''';

void main() {
  test(
    'Manhuaren 89 resolves previous 88 and next 90 by exact chapter URLs',
    () {
      final nav = ChapterNavigation.fromHtml(page, chapters, 2)!;
      expect(nav.previous, 3);
      expect(nav.next, 1);
      expect(nav.descendingFrom(2), isTrue);
      expect(
        chapters.ids.elementAt(nav.previous! - 1),
        'https://www.manhuaren.com/m103986/',
      );
      expect(
        chapters.ids.elementAt(nav.next! - 1),
        'https://www.manhuaren.com/m103988/',
      );
    },
  );

  test('uses source-fetched cached HTML including double trailing slash', () {
    final uri = Uri.parse('https://www.manhuaren.com/m103987//');
    NetworkCacheManager().setCache(
      NetworkCache(
        uri: uri,
        requestHeaders: {},
        responseHeaders: {},
        data: page,
        time: DateTime.now(),
        size: page.length,
      ),
    );
    addTearDown(NetworkCacheManager().clear);
    final nav = ChapterNavigation.fromCache(chapters, 2)!;
    expect(nav.previous, 3);
    expect(nav.next, 1);
  });

  test('page links and numeric IDs never imply chapter order', () {
    expect(
      ChapterNavigation.fromHtml('<a href="/m103988/">下一章</a>', chapters, 2),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml('<a href="http://[">下一章</a>', chapters, 2),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml(
        '<a href="data:text/plain,next">下一章</a>',
        chapters,
        2,
      ),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml(
        '<a rel="next" href="/m103988/">下一页</a>',
        chapters,
        2,
      ),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml(
        '<script>nextChapter=103988</script>',
        chapters,
        2,
      ),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml('<a href="/m999999/">下一章</a>', chapters, 2),
      isNull,
    );
    expect(
      ChapterNavigation.fromHtml('<a href="/m103987/">下一章</a>', chapters, 2),
      isNull,
    );
    expect(ChapterNavigation.fromCache(chapters, 2), isNull);
  });

  test(
    'rejects ambiguous links, cross-group links and arbitrary JavaScript',
    () {
      expect(
        ChapterNavigation.fromHtml(
          '$page<a href="/m103986/">下一章</a>',
          chapters,
          2,
        ),
        isNull,
      );
      const grouped = ComicChapters.grouped({
        'one': {'https://www.manhuaren.com/m103987/': 'Current'},
        'two': {'https://www.manhuaren.com/m103988/': 'Other group'},
      });
      expect(
        ChapterNavigation.fromHtml('<a href="/m103988/">下一章</a>', grouped, 1),
        isNull,
      );
      expect(
        ChapterNavigation.fromHtml(
          '<a href="javascript:evil()">下一章</a>',
          chapters,
          2,
        ),
        isNull,
      );
    },
  );

  test(
    'handles boundaries and non-monotonic IDs without numeric inference',
    () {
      const mixed = ComicChapters({
        'https://example.com/z': '序章',
        'https://example.com/a': '番外',
        'https://example.com/x': '结局',
      });
      final nav = ChapterNavigation.fromHtml(
        '<a title="" href="/a">上一章</a><a href="#">下一章</a>',
        mixed,
        3,
      )!;
      expect(nav.previous, 2);
      expect(nav.next, isNull);
      expect(nav.descendingFrom(3), isFalse);
      expect(
        ChapterNavigation.fromHtml(
          '<a href="/z">Previous chapter</a><a href="/x">Next chapter</a>',
          mixed,
          2,
        )!.next,
        3,
      );
    },
  );
}
