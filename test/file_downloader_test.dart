import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/file_downloader.dart';

void main() {
  test(
    'waits for other range requests before closing the file on failure',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final siblingStarted = Completer<void>();
      final siblingRelease = Completer<void>();
      final siblingFinished = Completer<void>();
      final transferError = Completer<void>();
      final fileSize = 16 * 1024 * 1024 + 1;
      final serverTask = () async {
        await for (final request in server) {
          if (request.method == 'HEAD') {
            request.response.headers.contentLength = fileSize;
            request.response.headers.set('accept-ranges', 'bytes');
            await request.response.close();
            continue;
          }

          final range = request.headers.value('range');
          if (range == 'bytes=0-${16 * 1024 * 1024 - 1}') {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            await request.response.close();
            continue;
          }

          siblingStarted.complete();
          try {
            await siblingRelease.future;
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'content-range',
              'bytes 16777216-16777216/$fileSize',
            );
            request.response.contentLength = 1;
            request.response.write('x');
            await request.response.close();
          } finally {
            siblingFinished.complete();
          }
        }
      }();

      final directory = await Directory.systemTemp.createTemp('prime-range-');
      final downloader = FileDownloader(
        'http://127.0.0.1:${server.port}/archive.zip',
        '${directory.path}/archive.zip',
        maxConcurrent: 2,
      );
      final subscription = downloader.start().listen(
        (_) {},
        onError: (Object _, StackTrace __) {
          if (!transferError.isCompleted) transferError.complete();
        },
      );

      try {
        await siblingStarted.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transferError.isCompleted, isFalse);
        siblingRelease.complete();
        await transferError.future.timeout(const Duration(seconds: 5));
        await siblingFinished.future.timeout(const Duration(seconds: 5));
      } finally {
        if (!siblingRelease.isCompleted) siblingRelease.complete();
        await subscription.cancel();
        await server.close(force: true);
        await serverTask;
        await directory.delete(recursive: true);
      }
    },
  );
}
