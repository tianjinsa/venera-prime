import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Android integration tests use a separate application ID', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    expect(gradle, contains('project.findProperty("target")'));
    expect(gradle, contains('flutterTarget.startsWith("integration_test/")'));
    expect(gradle, contains('flutterTarget.contains("/integration_test/")'));
    expect(gradle, contains('project.findProperty("primeIntegrationTest")'));
    expect(gradle, contains('flutterTarget.endsWith("/listener.dart")'));
    expect(gradle, contains('applicationId = integrationTestBuild ?'));
    expect(gradle, contains('com.github.wgh136.venera.prime.integrationtest'));
    final script = File(
      'tool/test_follow_updates_android.sh',
    ).readAsStringSync();
    expect(script, contains('dump badging'));
    expect(script, contains('Refusing to run'));
    expect(script, contains('trap verify_normal_app EXIT'));
    expect(
      script,
      contains('export ORG_GRADLE_PROJECT_primeIntegrationTest=true'),
    );
    expect(
      script.indexOf('build apk --debug'),
      lessThan(script.indexOf('test --no-pub -d')),
    );
  });

  test('both Linux AppImages deploy WebKit libraries and subprocesses', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    for (final platform in {
      'Build_Linux': 'x86_64',
      'Build_Linux_ARM64': 'aarch64',
    }.entries) {
      final steps = workflow['jobs'][platform.key]['steps'] as YamlList;
      final commands = steps.map((step) => step['run'] ?? '').join('\n');
      expect(commands, contains('libwebkit2gtk-4.1-dev'));
      expect(
        commands,
        contains('bash tool/build_appimage.sh ${platform.value}'),
      );
    }
    final script = File('tool/build_appimage.sh').readAsStringSync();
    expect(script, contains('"\$linuxdeploy" "\${deploy_args[@]}"'));
    expect(script, contains('WebKitNetworkProcess'));
    expect(script, contains('WebKitWebProcess'));
    expect(script, contains('WEBKIT_EXEC_PATH'));
    expect(script, contains('WEBKIT_INJECTED_BUNDLE_PATH'));
    expect(script, contains('libwebkit2gtk-4.1.so.0'));
    expect(script, contains('not found'));
    expect(script, contains(r'$HERE/lib:$HERE/usr/lib'));
  });

  test('runtime version matches pubspec version', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync());
    final pubspecVersion = (pubspec['version'] as String).split('+').first;
    final appSource = File('lib/foundation/app.dart').readAsStringSync();
    final runtimeVersion = RegExp(
      r'final version = "([^"]+)";',
    ).firstMatch(appSource)!.group(1);

    expect(runtimeVersion, pubspecVersion);

    final releaseNotes = File(
      'doc/release-$pubspecVersion.md',
    ).readAsLinesSync();
    expect(releaseNotes.first, '# Venera Prime $pubspecVersion');

    final aboutSource = File(
      'lib/pages/settings/about.dart',
    ).readAsStringSync();
    expect(aboutSource, contains(r'Text("V${App.version}"'));
  });

  test('workflow validates versions before every build', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    final jobs = workflow['jobs'] as YamlMap;
    final validation = jobs['Validate_Version'] as YamlMap;
    final validationStep = (validation['steps'] as YamlList).last as YamlMap;

    expect(validationStep['run'], contains('tool/check_version.py'));
    expect(
      validationStep['env']['RELEASE_TAG'],
      contains('github.event.release.tag_name'),
    );

    for (final jobName in [
      'Build_MacOS',
      'Build_IOS',
      'Build_Android',
      'Build_Windows',
      'Build_Linux',
      'Build_Linux_ARM64',
    ]) {
      expect((jobs[jobName] as YamlMap)['needs'], contains('Validate_Version'));
    }
    expect((jobs['Release'] as YamlMap)['needs'], contains('Validate_Version'));
    expect(
      (jobs['Release'] as YamlMap)['if'],
      contains("needs.Validate_Version.result == 'success'"),
    );
  });

  test('release gathers all build artifacts including AppImages', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    final steps = workflow['jobs']['Release']['steps'] as YamlList;
    final download = steps.firstWhere(
      (step) =>
          step['uses']?.toString().startsWith('actions/download-artifact@') ==
          true,
    )['with'];
    expect(download['pattern'], '*_build');
    expect(download['merge-multiple'], isTrue);
    expect(steps.first['run'], contains('exit 1'));
    expect(steps.first['if'], contains("needs.*.result"));
  });
  test('release uses validated metadata and automated identity gate', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    final jobs = workflow['jobs'] as YamlMap;
    final validation = jobs['Validate_Version'] as YamlMap;
    final steps = validation['steps'] as YamlList;
    final gate = steps.firstWhere(
      (step) => step['run'] == 'python3 tool/check_release_identity.py',
    );
    expect(gate['env']['RELEASE_ACTOR'], contains('github.actor'));
    expect(
      gate['env']['RELEASE_TRIGGERING_ACTOR'],
      contains('github.triggering_actor'),
    );
    expect(gate['if'], contains('inputs.publish_release'));
    final release = (jobs['Release']['steps'] as YamlList).firstWhere(
      (step) =>
          step['uses']?.toString().startsWith('softprops/action-gh-release@') ==
          true,
    );
    expect(
      release['with']['body_path'],
      contains('needs.Validate_Version.outputs.notes'),
    );
    expect(
      release['with']['tag_name'],
      contains('needs.Validate_Version.outputs.tag'),
    );
    expect(release['with']['target_commitish'], contains('github.sha'));
    expect(release['env']['GITHUB_TOKEN'], contains('secrets.GITHUB_TOKEN'));
  });
}
