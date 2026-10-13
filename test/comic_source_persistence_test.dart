import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';

import 'support/source_fixture.dart';

class _Sync extends Fake implements DataSync {
  int uploads = 0;

  @override
  Future<Res<bool>> uploadData({bool force = false}) async {
    uploads++;
    return const Res(true);
  }
}

class _ObservedFile extends Fake implements File {
  _ObservedFile(this.file, this.afterRename);

  final File file;
  final Future<void> Function() afterRename;

  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      file.readAsString(encoding: encoding);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => file.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> copy(String newPath) => file.copy(newPath);
  @override
  Future<File> rename(String newPath) async {
    final result = await file.rename(newPath);
    await afterRename();
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Sync sync;
  late DataSync? previousSync;

  setUp(() async {
    previousSync = DataSync.instance;
    root = await Directory.systemTemp.createTemp('source-persistence-');
    App.dataPath = root.path;
    sync = _Sync();
    DataSync.instance = sync;
  });

  tearDown(() async {
    DataSync.instance = previousSync;
    await root.delete(recursive: true);
  });

  test(
    'external backup readers always see a committed source data file',
    () async {
      final source = sourceFixture();
      source.data = {'value': 'old'};
      await source.saveData();
      final target = File('${root.path}/comic_source/${source.key}.data');
      final files = {
        for (final suffix in ['', '.tmp', '.bak'])
          '${target.path}$suffix': File('${target.path}$suffix'),
      };
      final observed = <String?>[];
      source.data['value'] = 'new';
      await IOOverrides.runZoned(
        () => source.saveData(),
        createFile: (path) => _ObservedFile(files[path]!, () async {
          // Backup export runs in a different isolate and cannot join the
          // source save queue. Observe each actual filesystem rename boundary.
          observed.add(
            await target.exists() ? await target.readAsString() : null,
          );
        }),
      );
      expect(observed, isNotEmpty);
      expect(observed, isNot(contains(null)));
      expect(
        observed.map((value) => jsonDecode(value!)['value']),
        everyElement(isIn(['old', 'new'])),
      );
      expect(jsonDecode(await target.readAsString())['value'], 'new');
    },
  );

  test(
    'identical nested JSON and reloaded sources do not write or upload',
    () async {
      final source = sourceFixture();
      source.data = {
        'accessToken': 'token',
        'nested': {
          'ids': [1, 2],
        },
      };
      await source.saveData();
      final file = File('${root.path}/comic_source/${source.key}.data');
      final sentinel = DateTime(2001);
      await file.setLastModified(sentinel);
      await Future.wait(List.generate(30, (_) => source.saveData()));
      final reloaded = sourceFixture();
      await reloaded.loadData();
      await reloaded.saveData();
      expect(sync.uploads, 1);
      expect(await file.lastModified(), sentinel);
      (reloaded.data['nested']['ids'] as List).add(3);
      await reloaded.saveData();
      expect(jsonDecode(await file.readAsString())['nested']['ids'], [1, 2, 3]);
      expect(sync.uploads, 2);
    },
  );

  test(
    'overlapping instances save snapshots in order and reload waits',
    () async {
      final source = sourceFixture();
      final replacement = sourceFixture();
      source.data = {
        'value': [1],
      };
      final first = source.saveData();
      source.data['value'][0] = 2;
      final second = source.saveData();
      replacement.data = {
        'value': [3],
      };
      final third = replacement.saveData();
      final reloaded = sourceFixture();
      final loading = reloaded.loadData();
      await Future.wait([first, second, third, loading]);
      expect(reloaded.data, {
        'value': [3],
      });
      expect(sync.uploads, 3);
      expect(Directory('${root.path}/comic_source').listSync(), hasLength(1));
    },
  );

  test(
    'failed writes release the queue and never suppress a later retry',
    () async {
      final source = sourceFixture();
      source.data = {'accessToken': 'old'};
      await source.saveData();
      final file = File('${root.path}/comic_source/${source.key}.data');
      final obstruction = Directory('${file.path}.tmp');
      await obstruction.create();
      source.data['accessToken'] = 'new';
      await expectLater(source.saveData(), throwsA(isA<FileSystemException>()));
      expect(jsonDecode(await file.readAsString())['accessToken'], 'old');
      expect(sync.uploads, 1);
      await obstruction.delete();
      await source.saveData();
      expect(jsonDecode(await file.readAsString())['accessToken'], 'new');
      expect(sync.uploads, 2);
      // No stale in-memory deduplication after disk replacement/deletion.
      await file.writeAsString('{"accessToken":"remote"}');
      await source.saveData();
      await file.delete();
      await source.saveData();
      expect(jsonDecode(await file.readAsString())['accessToken'], 'new');
      expect(sync.uploads, 4);
    },
  );
}
