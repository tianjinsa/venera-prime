import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app_update.dart';

// Host-assisted checks in the isolated package only. The host denies permission,
// replaces a fixture during the permission screen, then grants permission. On
// the last step it cancels the system installer; never install the fixture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'permission denial, revalidation and installer launch',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Isolated update installer validation')),
          ),
        ),
      );
      await tester.runAsync(() async {
        final cache = await getTemporaryDirectory();
        expect(
          cache.path.split('/'),
          contains('com.github.wgh136.venera.prime.integrationtest'),
        );
        final fixture = File(
          '${cache.path}/updater-test-fixtures/valid-new.apk',
        );
        final directory = Directory('${cache.path}/updates');
        await directory.create(recursive: true);
        final apk = File('${directory.path}/install-probe.apk');
        final marker = File('${cache.path}/installer-probe.json');
        final finished = File('${cache.path}/installer-probe-finish');
        if (await finished.exists()) await finished.delete();
        Future<void> stage(String value) async {
          await marker.writeAsString(
            jsonEncode({'stage': value, 'apk': apk.path}),
            flush: true,
          );
          debugPrint('INSTALLER_PROBE: $value');
        }

        try {
          await fixture.copy(apk.path);
          await stage('deny-permission');
          expect(await AndroidAppUpdater.install(apk), isFalse);
          await stage('denial-confirmed');
          await fixture.copy(apk.path);
          await stage('tamper-then-grant');
          await expectLater(
            AndroidAppUpdater.install(apk),
            throwsA(
              isA<PlatformException>().having(
                (e) => e.message,
                'message',
                contains('Invalid APK'),
              ),
            ),
          );
          await stage('revalidation-confirmed');
          await fixture.copy(apk.path);
          expect(await AndroidAppUpdater.install(apk), isTrue);
          await stage('installer-launched-cancel-only');
          final until = DateTime.now().add(const Duration(seconds: 120));
          while (!await finished.exists() && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          expect(
            await finished.exists(),
            isTrue,
            reason: 'Host must cancel the installer and acknowledge',
          );
          await stage('passed');
        } finally {
          if (await apk.exists()) await apk.delete();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
