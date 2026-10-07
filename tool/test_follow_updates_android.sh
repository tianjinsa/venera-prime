#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf 'Usage: %s DEVICE_ID\n' "$0" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
flutter="${FLUTTER:-flutter}"
adb="${ADB:-adb}"
aapt="${AAPT:-aapt}"
device="$1"
normal_package='com.github.wgh136.venera.prime'
test_package="${normal_package}.integrationtest"
normal_before="$("$adb" -s "$device" shell pm path "$normal_package")"

# Flutter recompiles a temporary listener entrypoint during `flutter test`.
# Keep the isolated identity across both Gradle invocations.
export ORG_GRADLE_PROJECT_primeIntegrationTest=true

# The runner captures the existing APK identity before rebuilding, then
# uninstalls that identity at exit. Never let it capture the ordinary app.
"$flutter" build apk --debug --no-pub --target integration_test/follow_updates_test.dart
badging="$("$aapt" dump badging build/app/outputs/flutter-apk/app-debug.apk)"
if [[ "$badging" != "package: name='$test_package' "* ]]; then
  printf 'Refusing to run: APK does not have the isolated test package.\n' >&2
  exit 1
fi

verify_normal_app() {
  local normal_after
  normal_after="$("$adb" -s "$device" shell pm path "$normal_package")"
  if [[ "$normal_before" != "$normal_after" ]]; then
    printf 'Ordinary app installation changed during testing.\n' >&2
    exit 1
  fi
}
trap verify_normal_app EXIT
"$flutter" test --no-pub -d "$device" integration_test/follow_updates_test.dart
