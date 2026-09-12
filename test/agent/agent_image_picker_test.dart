import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/agent/agent_images.dart';
import 'package:venera/agent/agent_models.dart';
import 'package:venera/utils/io.dart' show IO;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/method_channel');
  const fileChannel = MethodChannel('plugins.flutter.io/file_selector');
  late Directory temporary;

  Future<File> imageFile(String name) => File(
    'assets/app_icon.png',
  ).copy('${temporary.path}${Platform.pathSeparator}$name');

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('venera-agent-picker-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      fileChannel,
      (_) async => throw StateError('Android must use the photo picker'),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(fileChannel, null);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(IO.isSelectingFiles, false);
    await temporary.delete(recursive: true);
  });

  test(
    'Android photo picker preserves multiple originals and display names',
    () async {
      final first = await imageFile('agent_image_first.tmp');
      final second = await imageFile('agent_image_second.tmp');
      final original = await first.readAsBytes();
      var calls = 0;
      final released = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'releaseAgentImages') {
          released.addAll((call.arguments['paths'] as List).cast<String>());
          expect(await first.exists(), false);
          expect(await second.exists(), false);
          return null;
        }
        calls++;
        expect(call.method, 'pickAgentImages');
        expect(IO.isSelectingFiles, true);
        return [
          {'path': first.path, 'name': '第一张.png'},
          {'path': second.path, 'name': '第二张.jpg'},
        ];
      });

      final images = await pickAgentImages();

      expect(calls, 1);
      expect(released, [first.path, second.path]);
      expect(images.map((image) => image.attachment.name), [
        '第一张.png',
        '第二张.jpg',
      ]);
      expect(images.map((image) => image.attachment.mimeType), [
        'image/png',
        'image/png',
      ]);
      for (final image in images) {
        expect(image.bytes, original);
        expect(image.attachment.byteLength, original.length);
      }
      expect(await first.exists(), false);
      expect(await second.exists(), false);
      expect(await File('assets/app_icon.png').readAsBytes(), original);
    },
  );

  for (final response in [null, <Object>[]]) {
    test('cancelled Android picker returns no images ($response)', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'pickAgentImages');
        expect(IO.isSelectingFiles, true);
        return response;
      });
      expect(await pickAgentImages(), isEmpty);
      expect(await temporary.list().toList(), isEmpty);
    });
  }

  test('invalid selected image cleans every temporary copy', () async {
    final valid = await imageFile('valid.tmp');
    final invalid = File('${temporary.path}/invalid.tmp');
    await invalid.writeAsString('not an image');
    final unread = await imageFile('unread.tmp');
    final released = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'releaseAgentImages') {
        released.addAll((call.arguments['paths'] as List).cast<String>());
        expect(await temporary.list().toList(), isEmpty);
        return null;
      }
      return [
        {'path': valid.path, 'name': 'valid.png'},
        {'path': invalid.path, 'name': 'fake.png'},
        {'path': unread.path, 'name': 'last.png'},
      ];
    });

    await expectLater(
      pickAgentImages(),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'INVALID_IMAGE'),
      ),
    );

    expect(await temporary.list().toList(), isEmpty);
    expect(released, [valid.path, invalid.path, unread.path]);
  });

  test(
    'malformed metadata still releases every returned temporary path',
    () async {
      final malformed = await imageFile('malformed.tmp');
      final remaining = await imageFile('remaining.tmp');
      final released = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'releaseAgentImages') {
          released.addAll((call.arguments['paths'] as List).cast<String>());
          return null;
        }
        return [
          {'path': malformed.path, 'name': null},
          {'path': remaining.path, 'name': 'remaining.png'},
        ];
      });

      await expectLater(pickAgentImages(), throwsA(isA<TypeError>()));

      expect(released, [malformed.path, remaining.path]);
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  for (final valid in [true, false]) {
    test(
      'engine detach during cleanup preserves the ${valid ? 'image' : 'validation error'}',
      () async {
        final copy = await imageFile('selected.tmp');
        if (!valid) await copy.writeAsString('not an image');
        final original = await copy.readAsBytes();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (call.method == 'releaseAgentImages') {
            expect(await copy.exists(), false);
            throw MissingPluginException('Activity detached');
          }
          return [
            {'path': copy.path, 'name': 'selected.png'},
          ];
        });

        if (valid) {
          final images = await pickAgentImages();
          expect(images.single.bytes, original);
        } else {
          await expectLater(
            pickAgentImages(),
            throwsA(
              isA<AgentException>().having(
                (e) => e.code,
                'code',
                'INVALID_IMAGE',
              ),
            ),
          );
        }
        expect(await copy.exists(), false);
      },
    );
  }

  test(
    'native lifecycle cancellation releases the file-selection guard',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'pickAgentImages');
        expect(IO.isSelectingFiles, true);
        throw PlatformException(
          code: 'IMAGE_PICK_CANCELLED',
          message: '图片选择已取消，请重新选择',
        );
      });

      await expectLater(
        pickAgentImages(),
        throwsA(
          isA<AgentException>().having(
            (e) => e.code,
            'code',
            'IMAGE_PICK_CANCELLED',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(IO.isSelectingFiles, false);
    },
  );

  test('native picker failures retain their actionable error', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'IMAGE_TOO_LARGE',
        message: '图片“large.png”超过20 MB，请缩小后添加',
      );
    });

    await expectLater(
      pickAgentImages(),
      throwsA(
        isA<AgentException>()
            .having((e) => e.code, 'code', 'IMAGE_TOO_LARGE')
            .having((e) => e.message, 'message', contains('large.png')),
      ),
    );
  });

  test('a missing cache copy still cleans subsequent selections', () async {
    final remaining = await imageFile('remaining.tmp');
    final paths = ['${temporary.path}/missing.tmp', remaining.path];
    final released = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'releaseAgentImages') {
        released.addAll((call.arguments['paths'] as List).cast<String>());
        return null;
      }
      return [
        {'path': paths.first, 'name': 'gone.png'},
        {'path': remaining.path, 'name': 'remaining.png'},
      ];
    });

    await expectLater(pickAgentImages(), throwsA(isA<FileSystemException>()));

    expect(await remaining.exists(), false);
    expect(released, paths);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    test(
      '$platform retains the existing filtered file picker and originals',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final source = await imageFile('source.png');
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          _,
        ) async {
          throw StateError('Only Android uses the native photo channel');
        });
        binding.defaultBinaryMessenger.setMockMethodCallHandler(fileChannel, (
          call,
        ) async {
          expect(call.method, 'openFile');
          expect(IO.isSelectingFiles, true);
          expect(call.arguments['multiple'], true);
          final group =
              (call.arguments['acceptedTypeGroups'] as List).single as Map;
          expect(
            group['extensions'],
            containsAll(['jpg', 'png', 'webp', 'gif']),
          );
          return [source.path];
        });

        final images = await pickAgentImages();

        expect(images.single.attachment.name, 'source.png');
        expect(images.single.bytes, await source.readAsBytes());
        expect(await source.exists(), true);
      },
    );
  }
}
