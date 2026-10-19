import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart' show overrideIO;

void main() {
  test(
    'application IO overrides preserve native file and symlink types',
    () async {
      final directory = await Directory.systemTemp.createTemp('io-types-');
      final file = File('${directory.path}/update.apk');
      final link = Link('${directory.path}/update-link.apk');
      await file.writeAsBytes([1, 2, 3, 4]);
      await link.create(file.path);
      try {
        await overrideIO(() async {
          expect(await file.exists(), isTrue);
          expect(await file.length(), 4);
          expect(
            await FileSystemEntity.type(file.path, followLinks: false),
            FileSystemEntityType.file,
          );
          expect(
            FileSystemEntity.typeSync(file.path, followLinks: false),
            FileSystemEntityType.file,
          );
          expect(
            await FileSystemEntity.type(link.path, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(
            await FileSystemEntity.type(link.path),
            FileSystemEntityType.file,
          );
          expect(
            await FileSystemEntity.type(directory.path),
            FileSystemEntityType.directory,
          );
          expect(
            await FileSystemEntity.type('${directory.path}/missing'),
            FileSystemEntityType.notFound,
          );
        });
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
