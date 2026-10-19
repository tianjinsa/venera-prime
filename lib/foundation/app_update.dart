import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.digest,
  });

  final String name;
  final String url;
  final int size;
  final String? digest;

  static ReleaseAsset? fromJson(Map data) {
    final name = data['name'];
    final url = data['browser_download_url'];
    final size = data['size'];
    if (name is! String || url is! String || size is! int || size <= 0) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/venera-app/venera-prime/releases/download/')) {
      return null;
    }
    return ReleaseAsset(
      name: name,
      url: url,
      size: size,
      digest: data['digest']?.toString(),
    );
  }
}

class LatestRelease {
  const LatestRelease({
    required this.version,
    required this.title,
    required this.body,
    required this.url,
    this.assets = const [],
  });

  final String version;
  final String title;
  final String body;
  final String url;
  final List<ReleaseAsset> assets;

  factory LatestRelease.fromJson(Map<String, dynamic> data) {
    final tag = data['tag_name']?.toString() ?? '';
    if (tag.isEmpty) throw const FormatException('Missing release tag');
    final name = data['name']?.toString().trim() ?? '';
    return LatestRelease(
      version: tag.replaceFirst(RegExp(r'^[vV]'), '').split('+').first,
      title: name.isEmpty ? tag : name,
      body: data['body']?.toString().trim() ?? '',
      url:
          data['html_url']?.toString() ??
          'https://github.com/venera-app/venera-prime/releases/latest',
      assets: [
        for (final entry
            in (data['assets'] as List? ?? const []).whereType<Map>())
          if (ReleaseAsset.fromJson(entry) case final asset?) asset,
      ],
    );
  }

  ReleaseAsset? androidAsset(List<String> supportedAbis) {
    const knownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
    final apks = assets
        .where(
          (a) =>
              a.name.toLowerCase().endsWith('.apk') &&
              !a.name.toLowerCase().contains('debug'),
        )
        .toList();
    for (final abi in supportedAbis) {
      for (final asset in apks) {
        if (asset.name.toLowerCase().endsWith('-$abi.apk')) return asset;
      }
    }
    for (final asset in apks) {
      if (!knownAbis.any(
        (abi) => asset.name.toLowerCase().endsWith('-$abi.apk'),
      )) {
        return asset;
      }
    }
    return null;
  }
}

/// Accept abbreviated versions and build metadata without throwing on tags.
/// Prereleases are never offered as stable upgrades.
bool isNewerAppVersion(String candidate, String current) {
  List<int>? parse(String value) {
    final match = RegExp(
      r'^[vV]?(\d+(?:\.\d+)*)(?:\+[^\s]+)?$',
    ).firstMatch(value);
    return match?.group(1)?.split('.').map(int.parse).toList();
  }

  final a = parse(candidate), b = parse(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

class AppUpdateDownloader {
  AppUpdateDownloader({Dio? dio}) : _dio = dio ?? AppDio();
  final Dio _dio;

  Future<File> download(
    ReleaseAsset asset,
    Directory directory, {
    required CancelToken cancelToken,
    ProgressCallback? onProgress,
  }) async {
    await directory.create(recursive: true);
    // Only a basename from a release may be used inside the updater cache.
    if (asset.size <= 0 ||
        p.basename(asset.name) != asset.name ||
        asset.name.contains('\\') ||
        !asset.name.toLowerCase().endsWith('.apk')) {
      throw const FormatException('Invalid update filename');
    }
    final target = File(p.join(directory.path, asset.name));
    final partial = File('${target.path}.part');
    try {
      var receivedBytes = 0;
      final response = await _dio.download(
        asset.url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          receivedBytes = received;
          onProgress?.call(received, total);
        },
        options: Options(
          headers: {'cache-time': 'no'},
          receiveTimeout: const Duration(minutes: 2),
        ),
      );
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final actualSize = await partial.length();
      if (actualSize != asset.size) {
        Log.error(
          'App update',
          'Incomplete APK: expected=${asset.size}, actual=$actualSize, '
              'received=$receivedBytes, status=${response.statusCode}, '
              'content-length=${response.headers.value('content-length')}, '
              'content-range=${response.headers.value('content-range')}, '
              'content-encoding=${response.headers.value('content-encoding')}',
        );
        throw FormatException(
          'Update download is incomplete '
          '(expected ${asset.size} bytes, received $actualSize bytes)',
        );
      }
      if (asset.digest != null && asset.digest!.isNotEmpty) {
        final expected = asset.digest!;
        if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(expected)) {
          throw const FormatException('Unsupported update checksum');
        }
        final actual = await sha256.bind(partial.openRead()).first;
        if (actual.toString() != expected.substring(7).toLowerCase()) {
          throw const FormatException('Update checksum mismatch');
        }
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}

class AndroidAppUpdater {
  static const _channel = MethodChannel('venera/method_channel');

  static Future<List<String>> supportedAbis() async =>
      await _channel.invokeListMethod<String>('getSupportedAbis') ?? const [];

  static Future<void> validate(File apk) =>
      _channel.invokeMethod<void>('validateUpdate', {'path': apk.path});

  /// Native code validates package identity, version and signing certificate,
  /// requests install permission if needed, then launches the system installer.
  static Future<bool> install(File apk) async =>
      await _channel.invokeMethod<bool>('installUpdate', {'path': apk.path}) ??
      false;

  static Directory get downloadDirectory =>
      Directory(p.join(App.cachePath, 'updates'));
}
