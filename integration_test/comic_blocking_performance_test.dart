import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_blocking.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';

// Keep the pre-optimization keyword loop as a benchmark baseline. All inputs
// are generated; History is used only to exercise its computed description.
bool _legacyBlocks(Comic comic, List<String> words) {
  for (final word in words) {
    if (comic.title.contains(word) ||
        (comic.subtitle?.contains(word) ?? false) ||
        comic.description.contains(word)) {
      return true;
    }
    for (var tag in comic.tags ?? <String>[]) {
      if (tag == word) return true;
      if (tag.contains(':') && tag.split(':')[1] == word) return true;
    }
  }
  return false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compare literal blocking on 1200 generated comics', (
    tester,
  ) async {
    await App.init();
    await AppTranslation.init();
    appdata.settings['language'] = 'zh-CN';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Keyword matching benchmark'))),
      ),
    );

    final words = List.generate(300, (i) => 'unmatched-rule-$i');
    final histories = List.generate(
      1200,
      (i) => History.fromMap({
        'id': 'generated-$i',
        'type': 42,
        'title': 'Generated comic $i',
        'subtitle': 'Example author',
        'cover': '',
        'time': 1700000000000 + i,
        'ep': 2,
        'page': 3,
        'max_page': 100,
      }),
    );
    final comics = List.generate(
      1200,
      (i) => Comic(
        'Generated comic $i',
        '',
        '$i',
        'Example author',
        List.generate(20, (tag) => 'genre:example-$tag'),
        List.filled(8, 'Ordinary generated description.').join(' '),
        'test',
        null,
        null,
      ),
    );
    final results = <String, Object>{};
    for (final entry in {
      'computedDescriptions': histories,
      'taggedComics': comics,
    }.entries) {
      final filter = ComicBlockFilter(words: words, authors: []);
      int measure(bool Function(Comic) blocks, Iterable<Comic> items) {
        final watch = Stopwatch()..start();
        final blocked = items.where(blocks).length;
        watch.stop();
        expect(blocked, 0);
        return watch.elapsedMicroseconds;
      }

      final cold = measure(filter.blocks, entry.value);
      measure((comic) => _legacyBlocks(comic, words), entry.value.take(60));
      final legacy = <int>[];
      final optimized = <int>[];
      for (var round = 0; round < 5; round++) {
        void runLegacy() => legacy.add(
          measure((comic) => _legacyBlocks(comic, words), entry.value),
        );
        void runOptimized() =>
            optimized.add(measure(filter.blocks, entry.value));
        if (round.isEven) {
          runLegacy();
          runOptimized();
        } else {
          runOptimized();
          runLegacy();
        }
        await tester.pump();
      }
      results[entry.key] = {
        'coldOptimizedMicroseconds': cold,
        'legacyMicroseconds': legacy,
        'optimizedMicroseconds': optimized,
      };
    }
    binding.reportData = {
      'comicCount': 1200,
      'keywordCount': words.length,
      'blockingBenchmark': results,
    };
  });
}
