import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/app_update_service.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/utils/translations.dart';

const _bytes = [1, 2, 3, 4];
const _asset = ReleaseAsset(
  name: 'venera.apk',
  url:
      'https://github.com/venera-app/venera-prime/releases/download/v3/venera.apk',
  size: 4,
);
const _release = LatestRelease(version: '3.0', title: '3.0', body: '', url: '');

class _Downloader extends Fake implements AppUpdateDownloader {
  int calls = 0;
  Completer<void>? gate;
  Object? error;
  ProgressCallback? progress;
  final started = Completer<void>();

  @override
  Future<File> download(
    ReleaseAsset asset,
    Directory directory, {
    required CancelToken cancelToken,
    ProgressCallback? onProgress,
  }) async {
    calls++;
    await directory.create(recursive: true);
    final partial = File('${directory.path}/${asset.name}.part');
    await partial.writeAsBytes([1]);
    progress = onProgress;
    if (!started.isCompleted) started.complete();
    if (gate != null) {
      await Future.any([gate!.future, cancelToken.whenCancel]);
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (error != null) throw error!;
    await partial.writeAsBytes(_bytes);
    return partial.rename('${directory.path}/${asset.name}');
  }
}

Future<void> _finish(BackgroundTask task) async {
  if (task.isRunning) {
    final completion = Completer<void>();
    void changed() {
      if (!task.isRunning && !completion.isCompleted) completion.complete();
    }

    task.addListener(changed);
    try {
      await completion.future.timeout(const Duration(seconds: 5));
    } finally {
      task.removeListener(changed);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late Directory directory;
  late BackgroundTasks tasks;
  late _Downloader downloader;
  var validations = 0;
  var installs = 0;

  AppUpdateService service({
    Future<void> Function(File)? validate,
    Future<bool> Function(File)? installer,
    String version = '2.0',
    DateTime Function()? now,
    BackgroundTasks? registry,
  }) => AppUpdateService(
    tasks: registry ?? tasks,
    downloader: downloader,
    downloadDirectory: () => directory,
    currentVersion: () => version,
    now: now,
    validate:
        validate ??
        (_) async {
          validations++;
        },
    installer:
        installer ??
        (_) async {
          installs++;
          return true;
        },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-update-service-');
    tasks = BackgroundTasks();
    downloader = _Downloader();
    validations = 0;
    installs = 0;
  });
  tearDown(() async {
    tasks.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'start returns immediately, duplicate clicks reuse one task, validation precedes ready',
    () async {
      downloader.gate = Completer<void>();
      final validating = Completer<void>();
      final validationStarted = Completer<void>();
      final updates = service(
        validate: (_) async {
          validations++;
          validationStarted.complete();
          await validating.future;
        },
      );
      final task = await updates.startDownload(_release, _asset);
      expect(task.isRunning, isTrue);
      expect(task.pinned, isTrue);
      expect(task.needsAttention, isFalse);
      expect(await updates.startDownload(_release, _asset), same(task));
      await downloader.started.future;
      expect(downloader.calls, 1);
      downloader.gate!.complete();
      await validationStarted.future;
      expect(task.isRunning, isTrue);
      expect(updates.readyFile, isNull);
      expect(task.onOpenResult, isNull);
      validating.complete();
      await _finish(task);
      expect(task.status, BackgroundTaskStatus.completed);
      expect(task.needsAttention, isTrue);
      expect(task.pinned, isTrue);
      expect(task.resultLabel, isNotEmpty);
      expect(updates.readyFile!.existsSync(), isTrue);
      expect(installs, 0);
      expect(tasks.activeCount, 0);
      tasks.clearFinished();
      expect(tasks.tasks, [task]);
      expect(await updates.startDownload(_release, _asset), same(task));
      expect(downloader.calls, 1);
      expect(File('${directory.path}/ready.json').existsSync(), isTrue);
    },
  );

  test(
    'progress notifications are limited to ten per second and show byte counts',
    () async {
      var now = DateTime(2026);
      downloader.gate = Completer<void>();
      final updates = service(now: () => now);
      final task = await updates.startDownload(_release, _asset);
      await downloader.started.future;
      var notifications = 0;
      task.addListener(() => notifications++);
      for (var i = 0; i < 1000; i++) {
        now = now.add(const Duration(milliseconds: 1));
        downloader.progress!(i % 4, -1);
      }
      expect(notifications, lessThanOrEqualTo(10));
      expect(task.message, contains('%'));
      expect(task.message, contains(' B / 4 B'));
      task.requestCancel();
      await _finish(task);
    },
  );

  test(
    'cancellation cleans partial files and a later request can retry',
    () async {
      downloader.gate = Completer<void>();
      final updates = service();
      final task = await updates.startDownload(_release, _asset);
      await downloader.started.future;
      task.requestCancel();
      expect(await updates.startDownload(_release, _asset), same(task));
      await _finish(task);
      expect(task.status, BackgroundTaskStatus.cancelled);
      expect(task.pinned, isFalse);
      expect(task.needsAttention, isFalse);
      expect(directory.listSync(), isEmpty);
      downloader.gate = null;
      final retry = await updates.startDownload(_release, _asset);
      expect(retry, isNot(same(task)));
      await _finish(retry);
      expect(retry.status, BackgroundTaskStatus.completed);
      expect(downloader.calls, 2);
    },
  );

  test(
    'download errors are retained without escaping and retries work',
    () async {
      downloader.error = StateError('network unavailable');
      final updates = service();
      final task = await updates.startDownload(_release, _asset);
      await _finish(task);
      expect(task.status, BackgroundTaskStatus.failed);
      expect(task.errors.single, contains('network unavailable'));
      expect(task.pinned, isFalse);
      expect(task.needsAttention, isFalse);
      expect(directory.listSync(), isEmpty);
      downloader.error = null;
      final retry = await updates.startDownload(_release, _asset);
      await _finish(retry);
      expect(retry.status, BackgroundTaskStatus.completed);
    },
  );

  test(
    'cancelling during native validation never publishes a ready APK',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final updates = service(
        validate: (_) async {
          started.complete();
          await gate.future;
        },
      );
      final task = await updates.startDownload(_release, _asset);
      await started.future;
      task.requestCancel();
      gate.complete();
      await _finish(task);
      expect(task.status, BackgroundTaskStatus.cancelled);
      expect(updates.readyFile, isNull);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'installer is explicit, deduplicated, and retryable after permission denial or validation error',
    () async {
      final installGate = Completer<bool>();
      var rejectValidation = false;
      final updates = service(
        validate: (_) async {
          if (rejectValidation) throw StateError('validation unavailable');
        },
        installer: (_) async {
          installs++;
          return installGate.future;
        },
      );
      final task = await updates.startDownload(_release, _asset);
      await _finish(task);
      final first = updates.installReadyUpdate();
      expect(updates.installReadyUpdate(), same(first));
      installGate.complete(false);
      expect(await first, isFalse);
      expect(installs, 1);
      expect(task.pinned, isTrue);
      expect(task.needsAttention, isTrue);
      expect(updates.readyFile!.existsSync(), isTrue);
      rejectValidation = true;
      expect(await updates.installReadyUpdate(), isFalse);
      expect(installs, 1);
      expect(task.errors.last, contains('validation unavailable'));
      rejectValidation = false;
      expect(await updates.installReadyUpdate(), isFalse);
      expect(installs, 2);
    },
  );

  test(
    'launching the installer clears attention but retains a retry action',
    () async {
      final updates = service();
      final task = await updates.startDownload(_release, _asset);
      await _finish(task);
      expect(await updates.installReadyUpdate(), isTrue);
      expect(task.needsAttention, isFalse);
      expect(task.pinned, isTrue);
      expect(task.onOpenResult, isNotNull);
      expect(await updates.installReadyUpdate(), isTrue);
      expect(installs, 2);
      expect(validations, 3);
    },
  );

  test(
    'restore verifies cached APK and concurrent start reuses it without downloading',
    () async {
      final initial = service();
      await _finish(await initial.startDownload(_release, _asset));
      final restoredTasks = BackgroundTasks();
      final restored = service(registry: restoredTasks);
      try {
        final restoring = restored.restore();
        final starting = restored.startDownload(_release, _asset);
        await restoring;
        final task = await starting;
        expect(task.status, BackgroundTaskStatus.completed);
        expect(task.needsAttention, isTrue);
        expect(restoredTasks.tasks, [task]);
        expect(downloader.calls, 1);
        expect(validations, 2);
        expect(installs, 0);
        expect(
          p.normalize(restored.readyFile!.path),
          p.normalize(initial.readyFile!.path),
        );
      } finally {
        restoredTasks.dispose();
      }
    },
  );

  test(
    'restore rejects obsolete, missing, tampered, or unsafe cached files',
    () async {
      final file = File('${directory.path}/${_asset.name}');
      final metadata = File('${directory.path}/ready.json');
      final valid = {
        'version': '3.0',
        'sha256': sha256.convert(_bytes).toString(),
        'asset': {
          'name': _asset.name,
          'browser_download_url': _asset.url,
          'size': 4,
        },
      };
      for (final condition in [
        'obsolete',
        'missing',
        'tampered',
        'traversal',
        'validation',
      ]) {
        await file.writeAsBytes(
          condition == 'tampered' ? [4, 3, 2, 1] : _bytes,
        );
        final data = jsonDecode(jsonEncode(valid)) as Map;
        if (condition == 'missing') await file.delete();
        if (condition == 'traversal') data['asset']['name'] = '../venera.apk';
        await metadata.writeAsString(jsonEncode(data));
        final restored = service(
          version: condition == 'obsolete' ? '3.0' : '2.0',
          validate: condition == 'validation'
              ? (_) async {
                  throw StateError('invalid signing certificate');
                }
              : null,
        );
        await restored.restore();
        expect(restored.readyFile, isNull, reason: condition);
        expect(restored.task, isNull, reason: condition);
        expect(metadata.existsSync(), isFalse, reason: condition);
      }
      expect(downloader.calls, 0);
      expect(installs, 0);
    },
  );

  test(
    'tampering after download prevents installation and retains the retry entry',
    () async {
      final updates = service();
      final task = await updates.startDownload(_release, _asset);
      await _finish(task);
      await updates.readyFile!.writeAsBytes([4, 3, 2, 1]);
      expect(await updates.installReadyUpdate(), isFalse);
      expect(installs, 0);
      expect(task.errors.last, contains('checksum mismatch'));
      expect(task.onOpenResult, isNotNull);
      await updates.readyFile!.writeAsBytes(_bytes);
      expect(await updates.installReadyUpdate(), isTrue);
    },
  );
}
