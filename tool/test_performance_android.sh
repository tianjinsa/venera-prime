#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || -z "$1" || "$1" == -* ]]; then
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
target="${INTEGRATION_TEST_TARGET:-integration_test/performance_audit_test.dart}"
if [[ "$target" != integration_test/*_test.dart || ! -f "$target" ]]; then
  printf 'Target must be an existing integration_test/*_test.dart file.\n' >&2
  exit 2
fi

mkdir -p .dart_tool/performance-audit
run_dir="$(mktemp -d "$PWD/.dart_tool/performance-audit/run.XXXXXXXX")"
exec > >(tee -a "$run_dir/run.log") 2>&1
printf 'Device: %s\nArtifacts and log: %s\n' "$device" "$run_dir"

normal_before="$("$adb" -s "$device" shell pm path "$normal_package")"
printf '%s\n' "$normal_before" > "$run_dir/normal-package-before.txt"

verify_normal_app() {
  local status=$? normal_after
  if ! normal_after="$("$adb" -s "$device" shell pm path "$normal_package")"; then
    printf 'Unable to verify the ordinary app installation after testing.\n' >&2
    exit 1
  fi
  printf '%s\n' "$normal_after" > "$run_dir/normal-package-after.txt"
  if [[ "$normal_before" != "$normal_after" ]]; then
    printf 'Ordinary app installation changed during testing.\n' >&2
    exit 1
  fi
  printf 'Ordinary app installation unchanged. Exit status: %s\n' "$status"
  exit "$status"
}
trap verify_normal_app EXIT

# drive captures the existing APK identity before building, then normally
# uninstalls that identity after testing. Prebuild and verify the isolated app,
# use a private APK copy, and disable runner cleanup as an additional safeguard.
export ORG_GRADLE_PROJECT_primeIntegrationTest=true
apk="$run_dir/performance-audit.apk"
if [[ -n "${INTEGRATION_TEST_APK:-}" ]]; then
  cp "$INTEGRATION_TEST_APK" "$apk"
else
  "$flutter" build apk --profile --no-pub --target "$target"
  cp build/app/outputs/flutter-apk/app-profile.apk "$apk"
fi
"$aapt" dump badging "$apk" > "$run_dir/apk-badging.txt"
IFS= read -r package_line < "$run_dir/apk-badging.txt"
if [[ "$package_line" != "package: name='$test_package' "* ]]; then
  printf 'Refusing to run: APK does not have the isolated test package.\n' >&2
  exit 1
fi

export PERFORMANCE_AUDIT_OUTPUT_DIR="$run_dir"
"$flutter" drive --profile --no-pub -d "$device" \
  --target "$target" \
  --driver tool/performance_audit_driver.dart \
  --use-application-binary "$apk" \
  --keep-app-running
