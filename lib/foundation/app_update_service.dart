import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/utils/translations.dart';

/// Owns update downloads independently of any route or dialog.
class AppUpdateService {
  AppUpdateService({
    BackgroundTasks? tasks,
    AppUpdateDownloader? downloader,
    Directory Function()? downloadDirectory,
    Future<void> Function(File)? validate,
    Future<bool> Function(File)? installer,
    String Function()? currentVersion,
    DateTime Function()? now,
  }) : _tasks = tasks ?? BackgroundTasks.instance,
       _downloader = downloader ?? AppUpdateDownloader(),
       _directory =
           downloadDirectory ?? (() => AndroidAppUpdater.downloadDirectory),
       _validate = validate ?? AndroidAppUpdater.validate,
       _installer = installer ?? AndroidAppUpdater.install,
       _currentVersion = currentVersion ?? (() => App.version),
       _now = now ?? DateTime.now;

  static final instance = AppUpdateService();
  static const taskKey = 'app-update-download';

  final BackgroundTasks _tasks;
  final AppUpdateDownloader _downloader;
  final Directory Function() _directory;
  final Future<void> Function(File) _validate;
  final Future<bool> Function(File) _installer;
  final String Function() _currentVersion;
  final DateTime Function() _now;
  Future<void> _preparation = Future<void>.value();
  Future<bool>? _installation;
  bool _restored = false;
  bool _downloading = false;
  BackgroundTask? _task;
  _ReadyUpdate? _ready;

  BackgroundTask? get task => _task;
  File? get readyFile => _ready?.file;
  bool get isInstalling => _installation != null;

  // Serialize restoration and starts, but never hold this queue for a download.
  Future<T> _prepare<T>(Future<T> Function() action) {
    final result = _preparation.then((_) => action());
    _preparation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> restore() => _prepare(_restore);

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    File? metadata;
    Directory? directory;
    try {
      directory = _directory();
      metadata = File(p.join(directory.path, 'ready.json'));
      if (!await metadata.exists()) return;
      final data = jsonDecode(await metadata.readAsString()) as Map;
      final asset = ReleaseAsset.fromJson(data['asset'] as Map);
      final version = data['version'];
      final digest = data['sha256'];
      if (asset == null ||
          version is! String ||
          digest is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          !isNewerAppVersion(version, _currentVersion())) {
        throw const FormatException('Invalid or obsolete cached update');
      }
      final file = _assetFile(directory, asset);
      await _verifyFile(file, asset, expectedDigest: digest);
      await _validate(file);
      _ready = _ReadyUpdate(version, asset, file, digest);
      _task = _tasks.start(taskKey, 'App update'.tl, pinned: true);
      _showReady(_task!);
    } catch (_) {
      // Cache restoration must never prevent startup or offer an invalid APK.
      await _delete(metadata);
    } finally {
      if (directory != null) await _cleanCache(directory, keep: _ready?.file);
    }
  }

  Future<BackgroundTask> startDownload(
    LatestRelease release,
    ReleaseAsset asset,
  ) => _prepare(() async {
    await _restore();
    final existing = _task;
    if (existing != null &&
        (_downloading || existing.isRunning || isInstalling)) {
      return existing;
    }
    final ready = _ready;
    if (ready != null &&
        ready.version == release.version &&
        ready.asset.name == asset.name &&
        ready.asset.url == asset.url &&
        ready.asset.size == asset.size &&
        ready.asset.digest == asset.digest) {
      try {
        // Android may evict cache files while this process remains alive.
        // Never offer a remembered installation action for a missing/corrupt APK.
        await _verifyFile(
          ready.file,
          ready.asset,
          expectedDigest: ready.digest,
        );
        return existing!;
      } catch (_) {
        // A new explicit download request repairs unusable cached content.
      }
    }
    if (ready != null) await _discardReady(ready);
    existing?.setPresentation(pinned: false, needsAttention: false);
    existing?.onOpenResult = null;
    _ready = null;
    final task = _task = _tasks.start(
      taskKey,
      'App update'.tl,
      cancellable: true,
      pinned: true,
    );
    final token = CancelToken();
    task.onCancel = () => token.cancel('Cancelled');
    task.update(total: asset.size, message: _progressMessage(0, asset.size));
    _downloading = true;
    unawaited(_download(release, asset, task, token));
    return task;
  });

  Future<void> _download(
    LatestRelease release,
    ReleaseAsset asset,
    BackgroundTask task,
    CancelToken token,
  ) async {
    File? target;
    File? metadata;
    var lastProgress = _now();
    Future<void> cleanTemporaryFiles() async {
      if (target != null) await _delete(File('${target.path}.part'));
      if (metadata != null) await _delete(File('${metadata.path}.tmp'));
    }

    try {
      final directory = _directory();
      target = _assetFile(directory, asset);
      metadata = File(p.join(directory.path, 'ready.json'));
      await _delete(metadata);
      if (!isNewerAppVersion(release.version, _currentVersion())) {
        throw const FormatException('Update version is not newer');
      }
      if (token.isCancelled) throw token.cancelError!;
      final file = await _downloader.download(
        asset,
        directory,
        cancelToken: token,
        onProgress: (received, _) {
          if (token.isCancelled || !task.isRunning) return;
          final now = _now();
          if (now.difference(lastProgress) <
              const Duration(milliseconds: 100)) {
            return;
          }
          lastProgress = now;
          final completed = received.clamp(0, asset.size);
          task.update(
            completed: completed,
            total: asset.size,
            message: _progressMessage(completed, asset.size),
          );
        },
      );
      if (token.isCancelled) throw token.cancelError!;
      if (p.normalize(file.absolute.path) !=
          p.normalize(target.absolute.path)) {
        throw const FormatException('Unexpected update file');
      }
      task.update(completed: asset.size, message: 'Verifying update'.tl);
      final digest = await _verifyFile(file, asset);
      if (token.isCancelled) throw token.cancelError!;
      await _validate(file);
      if (token.isCancelled) throw token.cancelError!;
      final ready = _ReadyUpdate(release.version, asset, file, digest);
      await directory.create(recursive: true);
      final temporary = File('${metadata.path}.tmp');
      await temporary.writeAsString(jsonEncode(ready.toJson()), flush: true);
      if (token.isCancelled) throw token.cancelError!;
      await temporary.rename(metadata.path);
      await cleanTemporaryFiles();
      if (token.isCancelled) throw token.cancelError!;
      _ready = ready;
      _showReady(task);
    } catch (error) {
      await _delete(metadata);
      await _delete(target);
      // Complete only after cleanup, so a retry cannot lose its new .part file.
      await cleanTemporaryFiles();
      if (token.isCancelled) {
        task.cancelRequested = true;
        task.finish(message: 'Cancelled'.tl);
      } else {
        task.fail(error);
      }
      task.setPresentation(
        pinned: false,
        needsAttention: false,
        message: token.isCancelled
            ? 'Cancelled'.tl
            : '${'Update failed'.tl}\n$error',
      );
    } finally {
      _downloading = false;
    }
  }

  void _showReady(BackgroundTask task) {
    task.resultLabel = 'Install'.tl;
    task.onOpenResult = () {
      unawaited(installReadyUpdate());
    };
    task.update(completed: _ready!.asset.size, total: _ready!.asset.size);
    task.finish(message: 'Ready to install'.tl);
    task.setPresentation(pinned: true, needsAttention: true);
  }

  /// The installation prompt only opens after an explicit user action.
  /// Permission denial or a dismissed installer leaves the cached APK reusable.
  Future<bool> installReadyUpdate() {
    final existing = _installation;
    if (existing != null) return existing;
    final completion = Completer<bool>();
    _installation = completion.future;
    unawaited(() async {
      try {
        // Share the preparation queue so cache verification/replacement cannot
        // race an installation request for the previous ready file.
        completion.complete(await _prepare(_install));
      } catch (_) {
        // _install records actionable errors; this also guards UI callbacks.
        completion.complete(false);
      } finally {
        _installation = null;
      }
    }());
    return completion.future;
  }

  Future<bool> _install() async {
    final ready = _ready;
    final task = _task;
    if (ready == null || task == null) return false;
    task.setPresentation(message: 'Opening installer…'.tl);
    try {
      if (!isNewerAppVersion(ready.version, _currentVersion())) {
        throw const FormatException('Update version is not newer');
      }
      try {
        await _verifyFile(
          ready.file,
          ready.asset,
          expectedDigest: ready.digest,
        );
      } catch (error) {
        await _discardReady(ready);
        task.errors.add(error.toString());
        task.resultLabel = 'Download'.tl;
        task.onOpenResult = () {
          unawaited(
            startDownload(
              LatestRelease(
                version: ready.version,
                title: '',
                body: '',
                url: '',
              ),
              ready.asset,
            ).then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                task.errors.add(error.toString());
                task.setPresentation(message: '${'Update failed'.tl}\n$error');
              },
            ),
          );
        };
        task.setPresentation(
          pinned: true,
          needsAttention: false,
          message: '${'Update failed'.tl}\n$error',
        );
        return false;
      }
      await _validate(ready.file);
      final launched = await _installer(ready.file);
      task.setPresentation(
        pinned: true,
        needsAttention: !launched,
        message: launched
            ? 'Ready to install'.tl
            : 'Allow app installs in system settings, then tap Install again.'
                  .tl,
      );
      return launched;
    } catch (error) {
      // Finished task errors remain inspectable while the Install action stays.
      task.errors.add(error.toString());
      task.setPresentation(
        pinned: true,
        needsAttention: true,
        message: '${'Update failed'.tl}\n$error',
      );
      return false;
    }
  }

  Future<void> _discardReady(_ReadyUpdate ready) async {
    if (identical(_ready, ready)) _ready = null;
    await _delete(File(p.join(ready.file.parent.path, 'ready.json')));
    await _delete(ready.file);
  }

  // The updater owns these files. Leave unrelated files and directories alone,
  // and never follow links while cleaning interrupted/obsolete downloads.
  static Future<void> _cleanCache(Directory directory, {File? keep}) async {
    try {
      if (!await directory.exists()) return;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File && entry is! Link) continue;
        if (keep != null && p.equals(entry.absolute.path, keep.absolute.path)) {
          continue;
        }
        final name = p.basename(entry.path).toLowerCase();
        if (name.endsWith('.apk') ||
            name.endsWith('.apk.part') ||
            name == 'ready.json.tmp') {
          await _delete(File(entry.path));
        }
      }
    } catch (_) {
      // Cache housekeeping must not prevent startup or a fresh download.
    }
  }

  static File _assetFile(Directory directory, ReleaseAsset asset) {
    if (asset.size <= 0 ||
        p.basename(asset.name) != asset.name ||
        asset.name.contains('\\') ||
        !asset.name.toLowerCase().endsWith('.apk')) {
      throw const FormatException('Invalid update filename');
    }
    return File(p.join(directory.path, asset.name));
  }

  static Future<String> _verifyFile(
    File file,
    ReleaseAsset asset, {
    String? expectedDigest,
  }) async {
    // Do not follow a cache symlink outside the private updater directory.
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != asset.size) {
      throw const FormatException('Update download is incomplete');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final publishedDigest = asset.digest;
    if (expectedDigest != null && digest != expectedDigest ||
        publishedDigest != null &&
            publishedDigest.isNotEmpty &&
            publishedDigest.toLowerCase() != 'sha256:$digest') {
      throw const FormatException('Update checksum mismatch');
    }
    return digest;
  }

  static Future<void> _delete(File? file) async {
    try {
      if (file == null) return;
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await file.delete();
      }
    } catch (_) {}
  }

  static String _progressMessage(int received, int total) {
    String bytes(int count) => count < 1024
        ? '$count B'
        : count < 1024 * 1024
        ? '${(count / 1024).toStringAsFixed(1)} KiB'
        : '${(count / (1024 * 1024)).toStringAsFixed(1)} MiB';
    final percent = total > 0
        ? (received / total * 100).clamp(0, 100).toStringAsFixed(0)
        : '0';
    return '${'Downloading'.tl} $percent% · ${bytes(received)} / ${bytes(total)}';
  }
}

class _ReadyUpdate {
  const _ReadyUpdate(this.version, this.asset, this.file, this.digest);
  final String version;
  final ReleaseAsset asset;
  final File file;
  final String digest;
  Map<String, dynamic> toJson() => {
    'version': version,
    'sha256': digest,
    'asset': {
      'name': asset.name,
      'browser_download_url': asset.url,
      'size': asset.size,
      'digest': asset.digest,
    },
  };
}
