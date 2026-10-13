import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app_update.dart';

// Native validation only: never call install(), which could replace the runner.
// Generate fixtures with tool/generate_update_apk_fixtures.py, and stage them
// into the isolated app's cache/updater-test-fixtures (index last). No real app
// main(), app data initialization, production assets, or storage permissions.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native updater validates isolated APK identity and signer',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.runAsync(() async {
        expect(
          Platform.isAndroid,
          isTrue,
          reason: 'Requires an Android device',
        );
        final cache = await getTemporaryDirectory();
        const package = 'com.github.wgh136.venera.prime.integrationtest';
        expect(
          cache.path.split('/'),
          contains(package),
          reason: 'Refusing to test inside the ordinary app package',
        );
        final supported = await AndroidAppUpdater.supportedAbis();
        expect(supported, isNotEmpty);
        expect(supported.toSet().length, supported.length);
        expect(supported.every((abi) => abi.trim().isNotEmpty), isTrue);
        debugPrint('Native update supported ABIs: ${supported.join(", ")}');

        const fixtureOverride = String.fromEnvironment('UPDATER_FIXTURE_DIR');
        final fixtures = Directory(
          fixtureOverride.isEmpty
              ? '${cache.path}/updater-test-fixtures'
              : fixtureOverride,
        );
        final index = File('${fixtures.path}/fixture-index.json');
        debugPrint('Waiting for updater fixtures: ${fixtures.path}');
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (!await index.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          await index.exists(),
          isTrue,
          reason: 'Stage fixture-index.json last',
        );
        final metadata =
            jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        expect(metadata['runnerPackage'], package);
        final updates = Directory('${cache.path}/updates');
        await updates.create(recursive: true);
        final created = <File>[];
        final prefix =
            'native-validation-${DateTime.now().microsecondsSinceEpoch}';
        try {
          Future<File> stage(String name, {Directory? directory}) async {
            final bytes = await File('${fixtures.path}/$name').readAsBytes();
            expect(
              sha256.convert(bytes).toString(),
              metadata['files'][name]['sha256'],
              reason: 'Fixture checksum: $name',
            );
            final target = File('${(directory ?? updates).path}/$prefix-$name');
            created.add(target);
            return target.writeAsBytes(bytes, flush: true);
          }

          Future<void> rejected(File file, String message) async {
            await expectLater(
              AndroidAppUpdater.validate(file),
              throwsA(
                isA<PlatformException>()
                    .having((error) => error.code, 'code', 'invalid_update')
                    .having(
                      (error) => error.message,
                      'message',
                      contains(message),
                    ),
              ),
            );
            debugPrint('Native update rejection verified: $message');
          }

          final outside = await stage('valid-new.apk', directory: cache);
          await rejected(outside, 'Invalid update path');
          final invalid = File('${updates.path}/$prefix-invalid.apk');
          created.add(invalid);
          await invalid.writeAsString('This is not an APK');
          await rejected(invalid, 'Invalid APK');
          await rejected(
            await stage('wrong-package.apk'),
            'package does not match',
          );
          await rejected(await stage('old-version.apk'), 'not newer');
          await rejected(
            await stage('wrong-signer.apk'),
            'signing certificate does not match',
          );
          final valid = await stage('valid-new.apk');
          await AndroidAppUpdater.validate(valid);
          debugPrint(
            'Native update accepted matching package, newer version, same signer',
          );
        } finally {
          for (final file in created) {
            if (await file.exists()) await file.delete();
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
