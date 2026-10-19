import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/reader_page_layout.dart';

void main() {
  test('single-image shifts retain reading order and cover every image', () {
    for (final count in [1, 2, 3, 5, 14, 30]) {
      for (final perPage in [1, 2, 4, 8]) {
        for (final cover in [true, false]) {
          final base = ReaderPageLayout(
            imageCount: count,
            imagesPerPage: perPage,
            singleCover: cover,
          );
          for (var target = 0; target < count; target++) {
            final layout = ReaderPageLayout(
              imageCount: count,
              imagesPerPage: perPage,
              singleCover: cover,
              offset: base.offsetForStart(target),
            );
            expect(layout.range(layout.pageForImage(target + 1)).$1, target);
            final indices = <int>[];
            for (var page = 1; page <= layout.pageCount; page++) {
              final (start, end) = layout.range(page);
              expect(end, greaterThan(start));
              expect(end - start, lessThanOrEqualTo(perPage));
              indices.addAll(List.generate(end - start, (i) => start + i));
            }
            expect(indices, List.generate(count, (i) => i));
          }
        }
      }
    }
  });
}
