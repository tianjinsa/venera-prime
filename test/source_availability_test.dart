import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/availability.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';
import 'support/source_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test(
    'readability job survives listeners leaving and deduplicates its key',
    () async {
      final tasks = BackgroundTasks();
      final entered = Completer<void>();
      final image = Completer<void>();
      var calls = 0;
      final source = sourceFixture(
        details: (id) async => Res(detailsFixture(id)),
        pages: (_, _) async => const Res(['image']),
      );
      final manager = SourceCheckManager(
        tasks: tasks,
        checker: SourceAvailabilityChecker(
          loadImage: (_, _, _, _) {
            calls++;
            entered.complete();
            return image.future;
          },
        ),
      );
      addTearDown(manager.dispose);
      addTearDown(tasks.dispose);
      void listener() {}
      manager.addListener(listener);
      final check = manager.check(source, comicId: '1');
      expect(identical(manager.check(source, comicId: '2'), check), isTrue);
      await entered.future;
      final task = tasks.latest(SourceCheckManager.taskKey(source.key))!;
      expect(tasks.activeCount, 1);
      expect(task.cancellable, isFalse);
      expect(manager.stageFor(source.key), SourceCheckStage.image);
      expect(task.message, SourceCheckStage.image.label);
      manager.removeListener(listener);
      image.complete();
      final result = await check;
      expect(calls, 1);
      expect(result.readable, isTrue);
      expect(result.imageKey, 'image');
      expect(manager.resultFor(source), same(result));
      expect(manager.isChecking(source.key), isFalse);
      expect(task.status, BackgroundTaskStatus.completed);
      expect(tasks.activeCount, 0);
    },
  );

  test(
    'failed and timed out checks preserve copyable stage diagnostics',
    () async {
      for (final timeout in [false, true]) {
        final tasks = BackgroundTasks();
        final pending = Completer<Res<ComicDetails>>();
        final source = sourceFixture(
          details: (id) => timeout
              ? pending.future
              : Future.value(const Res.error('Login required')),
          pages: (_, _) async => const Res(['image']),
        );
        final manager = SourceCheckManager(
          tasks: tasks,
          checker: SourceAvailabilityChecker(
            timeout: const Duration(milliseconds: 10),
          ),
        );
        final result = await manager.check(source, comicId: '1');
        final task = tasks.latest(SourceCheckManager.taskKey(source.key))!;
        expect(result.stage, SourceCheckStage.details);
        expect(result.readable, isFalse);
        expect(task.status, BackgroundTaskStatus.failed);
        expect(task.errors.single, contains(SourceCheckStage.details.label));
        expect(
          task.errors.single,
          contains(timeout ? 'TimeoutException' : 'Login required'),
        );
        expect(manager.isChecking(source.key), isFalse);
        if (timeout) {
          // Timeout does not cancel the underlying callback; late completion
          // must not turn the task into success or advance to page loading.
          pending.complete(Res(detailsFixture('1')));
          await Future<void>.delayed(Duration.zero);
          expect(task.status, BackgroundTaskStatus.failed);
          expect(manager.resultFor(source), same(result));
        }
        manager.dispose();
        tasks.dispose();
      }
    },
  );

  test(
    'clearing a source invalidates results without duplicating active work',
    () async {
      final tasks = BackgroundTasks();
      final entered = Completer<void>();
      final details = Completer<Res<ComicDetails>>();
      final source = sourceFixture(
        details: (_) {
          entered.complete();
          return details.future;
        },
        pages: (_, _) async => const Res(['image']),
      );
      final manager = SourceCheckManager(
        tasks: tasks,
        checker: SourceAvailabilityChecker(loadImage: (_, _, _, _) async {}),
      );
      final future = manager.check(source, comicId: '1');
      await entered.future;
      manager.clear(source.key);
      expect(manager.isChecking(source.key), isTrue);
      expect(manager.check(source), same(future));
      details.complete(Res(detailsFixture('1')));
      await future;
      expect(manager.resultFor(source), isNull);
      expect(tasks.tasks, hasLength(1));
      manager.dispose();
      tasks.dispose();
    },
  );

  test(
    'replacement sources wait for active checks and retain their own result',
    () async {
      final tasks = BackgroundTasks();
      final entered = Completer<void>();
      final details = Completer<Res<ComicDetails>>();
      final oldSource = sourceFixture(
        details: (_) {
          entered.complete();
          return details.future;
        },
        pages: (_, _) async => const Res(['old-image']),
      );
      var newCalls = 0;
      final newSource = sourceFixture(
        details: (id) async {
          newCalls++;
          return Res(detailsFixture(id));
        },
        pages: (_, _) async => const Res(['new-image']),
      );
      final manager = SourceCheckManager(
        tasks: tasks,
        checker: SourceAvailabilityChecker(loadImage: (_, _, _, _) async {}),
      );
      final oldCheck = manager.check(oldSource, comicId: '1');
      await entered.future;
      final newCheck = manager.check(newSource, comicId: '2');
      final duplicate = manager.check(newSource, comicId: '2');
      expect(tasks.activeCount, 1);
      expect(newCalls, 0);
      details.complete(Res(detailsFixture('1')));
      await oldCheck;
      final result = await newCheck;
      expect(await duplicate, same(result));
      expect(newCalls, 1);
      expect(result.imageKey, 'new-image');
      expect(manager.resultFor(newSource), same(result));
      expect(manager.resultFor(oldSource), isNull);
      expect(tasks.tasks, hasLength(2));
      manager.dispose();
      tasks.dispose();
    },
  );

  test(
    'image checks decode real pixels and reject HTML and empty responses',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await SourceAvailabilityChecker.validateImageBytes(png);
      await expectLater(
        SourceAvailabilityChecker.validateImageBytes(
          Uint8List.fromList(utf8.encode('<html>Login required</html>')),
        ),
        throwsA(anything),
      );
      await expectLater(
        SourceAvailabilityChecker.validateImageBytes(Uint8List(0)),
        throwsStateError,
      );
    },
  );

  test('catalog failure falls back to an available catalog', () async {
    final source = sourceFixture(
      explore: [
        ExplorePageData(
          'Failed',
          ExplorePageType.multiPageComicList,
          (_) async => const Res.error('Catalog unavailable'),
          null,
          null,
          null,
        ),
        ExplorePageData(
          'Available',
          ExplorePageType.singlePageWithMultiPart,
          null,
          null,
          () async => Res([
            ExplorePagePart('Part', [comicFixture('1')], null),
          ]),
          null,
        ),
      ],
      details: (id) async => Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {},
    ).check(source);
    expect(result.readable, isTrue);
  });

  test(
    'a readable result requires details, chapter pages and decoded image',
    () async {
      final calls = <String>[];
      final source = sourceFixture(
        explore: [
          ExplorePageData(
            'Catalog',
            ExplorePageType.multiPageComicList,
            (_) async => Res([comicFixture('1')]),
            null,
            null,
            null,
          ),
        ],
        details: (id) async {
          calls.add('details:$id');
          return Res(detailsFixture(id));
        },
        pages: (id, ep) async {
          calls.add('pages:$id:$ep');
          return const Res(['image']);
        },
      );
      final result = await SourceAvailabilityChecker(
        loadImage: (image, source, cid, ep) async {
          calls.add('image:$image:$cid:$ep');
        },
      ).check(source);
      expect(result.readable, isTrue);
      expect(result.comic!.title, 'Sample 1');
      expect(calls, ['details:1', 'pages:1:ep', 'image:image:1:ep']);
    },
  );

  test('reachable catalog with failed image is not readable', () async {
    final source = sourceFixture(
      details: (id) async => Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {
        throw StateError('Invalid image data');
      },
    ).check(source, comicId: '1');
    expect(result.readable, isFalse);
    expect(result.stage, SourceCheckStage.image);
    expect(result.error, contains('Invalid image data'));
  });

  test('removed first sample falls back to another comic', () async {
    final source = sourceFixture(
      explore: [
        ExplorePageData(
          'Catalog',
          ExplorePageType.multiPageComicList,
          (_) async => Res([comicFixture('removed'), comicFixture('ok')]),
          null,
          null,
          null,
        ),
      ],
      details: (id) async => id == 'removed'
          ? const Res.error('Not found')
          : Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {},
    ).check(source);
    expect(result.readable, isTrue);
    expect(result.comic!.id, 'ok');
  });

  test(
    'grouped chapters and sources without chapters use correct episode',
    () async {
      for (final chapters in [
        null,
        {
          'group': {'group-ep': 'Chapter'},
        },
      ]) {
        String? loadedEpisode;
        final source = sourceFixture(
          details: (id) async => Res(detailsFixture(id, chapters: chapters)),
          pages: (_, ep) async {
            loadedEpisode = ep;
            return const Res(['image']);
          },
        );
        final result = await SourceAvailabilityChecker(
          loadImage: (_, _, _, ep) async {
            expect(ep, chapters == null ? '0' : 'group-ep');
          },
        ).check(source, comicId: 'explicit');
        expect(result.readable, isTrue);
        expect(loadedEpisode, chapters == null ? null : 'group-ep');
      }
    },
  );

  test(
    'empty pages and timed out details report the actual failing stage',
    () async {
      final empty =
          await SourceAvailabilityChecker(
            loadImage: (_, _, _, _) async {},
          ).check(
            sourceFixture(
              details: (id) async => Res(detailsFixture(id)),
              pages: (_, _) async => const Res([]),
            ),
            comicId: '1',
          );
      expect(empty.stage, SourceCheckStage.pages);
      expect(empty.readable, isFalse);
      final timed =
          await SourceAvailabilityChecker(
            timeout: const Duration(milliseconds: 10),
          ).check(
            sourceFixture(
              details: (_) => Completer<Res<ComicDetails>>().future,
              pages: (_, _) async => const Res(['image']),
            ),
            comicId: '1',
          );
      expect(timed.stage, SourceCheckStage.details);
      expect(timed.error, contains('TimeoutException'));
    },
  );

  test(
    'sources with no discoverable sample can be checked by comic ID',
    () async {
      final result = await SourceAvailabilityChecker().check(sourceFixture());
      expect(result.stage, SourceCheckStage.catalog);
      expect(result.readable, isFalse);
      expect(result.error, contains('Enter a comic ID'));
    },
  );
}
