import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  History history() => History.fromMap({
    'id': 'deleted-123',
    'type': ComicType.local.value,
    'title': 'A Lost Comic',
    'subtitle': 'An Author',
    'cover': '',
    'time': DateTime(2026, 10, 2, 9, 5).millisecondsSinceEpoch,
    'ep': 2,
    'page': 3,
  });

  test('history searches saved metadata without consulting a website', () {
    final comic = history();
    for (final query in [
      '',
      '  ',
      'LOST',
      'author',
      'lost AUTHOR',
      'deleted-123',
      'local',
    ]) {
      expect(comic.matchesQuery(query), isTrue, reason: query);
    }
    expect(comic.matchesQuery('lost missing'), isFalse);
    comic.title = 'Updated title';
    expect(comic.matchesQuery('updated'), isTrue);
    expect(comic.matchesQuery('lost'), isFalse);
  });

  test('history description includes the last read local date and time', () {
    final comic = history();
    expect(comic.lastReadTime, '2026-10-02 09:05');
    expect(comic.description, endsWith('\n2026-10-02 09:05'));
    comic.ep = 0;
    comic.page = 0;
    expect(comic.description, '2026-10-02 09:05');
    comic.time = DateTime(2026, 10, 7, 20, 30).toUtc();
    expect(comic.lastReadTime, '2026-10-07 20:30');
  });

  test('history index preserves matching across saved metadata fields', () {
    final comic = history();
    final index = HistorySearchIndex([comic]);
    for (final query in [
      '',
      '  ',
      'LOST',
      'lost AUTHOR',
      'deleted-123',
      'local',
    ]) {
      expect(index.search(query), [comic], reason: query);
    }
    expect(index.search('lost missing'), isEmpty);
    comic.title = 'Updated title';
    final refreshed = HistorySearchIndex([comic]);
    expect(refreshed.search('updated AUTHOR'), [comic]);
    expect(refreshed.search('lost'), isEmpty);
  });
}
