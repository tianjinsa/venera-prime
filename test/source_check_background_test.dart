import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

class _Source implements ComicSource {
  _Source(this.key);
  @override
  final String key;
  @override
  String get name => key;
  @override
  String get version => '1.0.0';
  @override
  String get filePath => '/unused/$key.js';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'source-check-background-',
    );
    App.dataPath = directory.path;
    appdata.settings['webdav'] = [];
    appdata.settings['comicSourceLibrariesMigrated'] = true;
    appdata.settings['comicSourceLibraries'] = [
      ComicSourceLibrary(
        id: 'origin',
        name: 'Origin',
        url: 'https://origin.invalid/index.json',
      ).toJson(),
      ComicSourceLibrary(
        id: 'mirror',
        name: 'Mirror',
        url: 'https://mirror.invalid/index.json',
      ).toJson(),
    ];
    appdata.settings['comicSourceProvenance'] = {
      'bound': SourceProvenance(
        originId: 'origin',
        sourceFileName: 'bound.js',
      ).toJson(),
    };
    ComicSourceManager().add(_Source('bound'));
    ComicSourceManager().add(_Source('unbound'));
    BackgroundTasks.instance.configure(history: {});
    BackgroundTasks.instance.clearFinished();
  });
  tearDown(() async {
    ComicSourceManager().remove('bound');
    ComicSourceManager().remove('unbound');
    ComicSourceManager().clearUpdateCandidates();
    await appdata.saveData(false);
    await directory.delete(recursive: true);
  });

  test(
    'partial catalog failure is failed and never changes bound origin',
    () async {
      final count = await ComicSourcePage.checkComicSourceUpdate(
        loadCatalog: (library) async {
          if (library.id == 'origin') throw StateError('offline');
          return [
            {'key': 'bound', 'version': '9.0.0', 'fileName': 'bound.js'},
            {'key': 'unbound', 'version': '2.0.0', 'fileName': 'unbound.js'},
          ];
        },
      );
      expect(count, 1);
      expect(ComicSourceManager().availableUpdates.keys, ['unbound']);
      expect(ComicSourceManager().provenanceFor('bound')!.originId, 'origin');
      expect(ComicSourcePage.automaticUpdateKeys(), isEmpty);
      final task = BackgroundTasks.instance.latest('source-check')!;
      expect(task.status, BackgroundTaskStatus.failed);
      expect(task.completed, 2);
      expect(task.errors.single, contains('offline'));
      expect(task.onOpenResult, isNotNull);
      expect(ComicSourceLibraryManager.find('origin')!.lastChecked, isNull);
      expect(ComicSourceLibraryManager.find('mirror')!.lastChecked, isNotNull);
    },
  );

  test(
    'concurrent checks share one request and auto-update selects only bound sources',
    () async {
      final gate = Completer<List<dynamic>>();
      var requests = 0;
      Future<List<dynamic>> load(ComicSourceLibrary library) async {
        requests++;
        if (library.id == 'origin') return gate.future;
        return [
          {'key': 'unbound', 'version': '2.0.0', 'fileName': 'unbound.js'},
        ];
      }

      final first = ComicSourcePage.checkComicSourceUpdate(loadCatalog: load);
      final second = ComicSourcePage.checkComicSourceUpdate(loadCatalog: load);
      expect(identical(first, second), isTrue);
      gate.complete([
        {'key': 'bound', 'version': '2.0.0', 'fileName': 'bound.js'},
      ]);
      expect(await first, 2);
      expect(requests, 2);
      expect(ComicSourcePage.automaticUpdateKeys(), ['bound']);
      expect(
        BackgroundTasks.instance.latest('source-check')!.status,
        BackgroundTaskStatus.completed,
      );
    },
  );

  test(
    'catalog changes during a check cannot restore stale update candidates',
    () async {
      final requested = Completer<void>();
      final response = Completer<List<dynamic>>();
      final job = ComicSourcePage.checkComicSourceUpdate(
        loadCatalog: (library) async {
          if (library.id == 'origin') {
            requested.complete();
            return response.future;
          }
          return [];
        },
      );
      await requested.future;
      ComicSourceLibraryManager.edit(
        'origin',
        url: 'https://new-origin.invalid/index.json',
      );
      response.complete([
        {'key': 'bound', 'version': '9.0.0', 'fileName': 'bound.js'},
      ]);
      expect(await job, 0);
      expect(ComicSourceManager().availableUpdates, isEmpty);
      expect(ComicSourceLibraryManager.find('origin')!.lastChecked, isNull);
      expect(
        BackgroundTasks.instance.latest('source-check')!.status,
        BackgroundTaskStatus.failed,
      );
    },
  );
}
