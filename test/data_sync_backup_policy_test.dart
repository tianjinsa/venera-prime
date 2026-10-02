import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  test('does not prune the file just uploaded when its name already exists', () {
    final prune = backupFilesToPrune(
      existingNames: [
        '20000-4.venera',
        '20000-5.venera',
        '19999-9.venera',
      ],
      dayPrefix: '20000-',
      uploadedFilename: '20000-5.venera',
    );

    expect(prune, ['20000-4.venera']);
    expect(prune, isNot(contains('20000-5.venera')));
  });

  test('prunes the oldest remaining backup only when over the limit', () {
    final prune = backupFilesToPrune(
      existingNames: [
        '19990-1.venera',
        '19991-1.venera',
        '19992-1.venera',
        '19993-1.venera',
        '19994-1.venera',
        '19995-1.venera',
        '19996-1.venera',
        '19997-1.venera',
        '19998-1.venera',
        '19999-1.venera',
      ],
      dayPrefix: '20000-',
      uploadedFilename: '20000-1.venera',
    );

    expect(prune, ['19990-1.venera']);
    expect(prune, isNot(contains('20000-1.venera')));
  });

  test('prunes every excess backup when the existing set is over the limit', () {
    final prune = backupFilesToPrune(
      existingNames: List.generate(
        11,
        (index) => '${19989 + index}-1.venera',
      ),
      dayPrefix: '20000-',
      uploadedFilename: '20000-1.venera',
    );

    expect(prune, ['19989-1.venera', '19990-1.venera']);
  });

  test('retains prior files when ten or fewer remain after upload', () {
    final prune = backupFilesToPrune(
      existingNames: List.generate(9, (index) => '1999$index-1.venera'),
      dayPrefix: '20000-',
      uploadedFilename: '20000-1.venera',
    );

    expect(prune, isEmpty);
  });
}
