import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/import_comic.dart';

void main() {
  test(
    'a rescan or path change waits for an in-flight import to finish',
    () async {
      final finishCopy = Completer<void>();
      final events = <String>[];
      final import = ImportComic.withLibraryLock(() async {
        events.add('copy');
        await finishCopy.future;
        events.add('register');
      });
      final scan = ImportComic.withLibraryLock(() async => events.add('scan'));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['copy']);
      finishCopy.complete();
      await Future.wait([import, scan]);
      expect(events, ['copy', 'register', 'scan']);
    },
  );

  test(
    'a failed local operation does not prevent the next operation',
    () async {
      final failure = ImportComic.withLibraryLock<void>(() async {
        throw StateError('copy failed');
      });
      final next = ImportComic.withLibraryLock(() async => 'rescanned');
      await expectLater(failure, throwsStateError);
      expect(await next, 'rescanned');
    },
  );
}
