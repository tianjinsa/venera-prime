#!/usr/bin/env python3
"""Generate validation-only APKs under build; never build/install the test app.

Usage: python3 tool/generate_update_apk_fixtures.py ISOLATED_RUNNER.apk

The runner must use com.github.wgh136.venera.prime.integrationtest. Defaults to
the standard Android debug key. For a differently signed runner, set
FIXTURE_KEYSTORE, FIXTURE_KEY_ALIAS, FIXTURE_STORE_PASSWORD and
FIXTURE_KEY_PASSWORD. Passwords are passed to apksigner through the environment.
No private key or fixture is placed in source/assets. Never install these APKs.

Stage the printed output directory's files into the isolated app's
cache/updater-test-fixtures using adb run-as (fixture-index.json last), or use
--dart-define=UPDATER_FIXTURE_DIR=/sdcard/Download/venera-prime-updater-test
when that directory is readable by the test app. The test waits up to 90 seconds
for the marker so the orchestrator can stage files after starting the runner.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


PACKAGE = "com.github.wgh136.venera.prime.integrationtest"
ROOT = Path(__file__).resolve().parents[1]


def run(*args, env=None):
    return subprocess.check_output(args, text=True, env=env, stderr=subprocess.STDOUT)


def signer(apksigner, apk):
    output = run(str(apksigner), "verify", "--print-certs", str(apk))
    return re.findall(r"Signer #\d+ certificate SHA-256 digest: (\w+)", output)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    runner = Path(sys.argv[1]).resolve(strict=True)
    sdk = Path(os.environ.get("ANDROID_HOME", "/home/luorix/Android/Sdk"))
    build_tools = sdk / "build-tools" / "36.0.0"
    aapt = build_tools / "aapt"
    apksigner = build_tools / "apksigner"
    android_jar = sdk / "platforms" / "android-36" / "android.jar"
    badging = run(str(aapt), "dump", "badging", str(runner))
    identity = re.search(r"^package: name='([^']+)' versionCode='(\d+)'", badging)
    if identity is None or identity[1] != PACKAGE:
        raise SystemExit("Refusing non-isolated runner APK")
    version = int(identity[2])
    if not 0 < version < 2_100_000_000:
        raise SystemExit("Runner versionCode must allow an older and newer fixture")
    runner_signers = signer(apksigner, runner)
    if len(runner_signers) != 1:
        raise SystemExit("Expected one verified runner signer")

    keystore = Path(os.environ.get("FIXTURE_KEYSTORE", str(Path.home() / ".android/debug.keystore"))).resolve(strict=True)
    alias = os.environ.get("FIXTURE_KEY_ALIAS", "androiddebugkey")
    signing_env = dict(os.environ)
    signing_env.setdefault("FIXTURE_STORE_PASSWORD", "android")
    signing_env.setdefault("FIXTURE_KEY_PASSWORD", signing_env["FIXTURE_STORE_PASSWORD"])
    output_root = ROOT / "build" / "updater-native-fixtures"
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=output_root))
    work = output / "work"
    work.mkdir()
    wrong_key = work / "wrong-signer.keystore"
    run("keytool", "-genkeypair", "-keystore", str(wrong_key),
        "-alias", "fixture", "-storepass", "android", "-keypass", "android",
        "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=Updater Validation Fixture", "-noprompt")

    def make(name, package, code, wrong_signer=False):
        manifest = work / "AndroidManifest.xml"
        manifest.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
            f'package="{package}" android:versionCode="{code}" android:versionName="fixture">'
            '<uses-sdk android:minSdkVersion="21" android:targetSdkVersion="36"/>'
            '<application android:hasCode="false" android:label="Validation fixture"/>'
            '</manifest>\n', encoding="utf-8")
        unsigned = work / "unsigned.apk"
        aligned = work / "aligned.apk"
        run(str(aapt), "package", "-f", "-M", str(manifest),
            "-I", str(android_jar), "-F", str(unsigned))
        run(str(build_tools / "zipalign"), "-f", "4", str(unsigned), str(aligned))
        target = output / name
        env = dict(signing_env)
        if wrong_signer:
            env["FIXTURE_STORE_PASSWORD"] = "android"
            env["FIXTURE_KEY_PASSWORD"] = "android"
        run(str(apksigner), "sign", "--ks", str(wrong_key if wrong_signer else keystore),
            "--ks-key-alias", "fixture" if wrong_signer else alias,
            "--ks-pass", "env:FIXTURE_STORE_PASSWORD", "--key-pass", "env:FIXTURE_KEY_PASSWORD",
            "--out", str(target), str(aligned), env=env)
        actual_signers = signer(apksigner, target)
        if not actual_signers or (actual_signers == runner_signers) == wrong_signer:
            raise SystemExit("Fixture signer does not match expected runner identity; check FIXTURE_KEYSTORE")
        return {"sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                "package": package, "versionCode": code}

    files = {
        "valid-new.apk": make("valid-new.apk", PACKAGE, version + 1),
        "wrong-package.apk": make("wrong-package.apk", PACKAGE + ".wrong", version + 1),
        "old-version.apk": make("old-version.apk", PACKAGE, version - 1),
        "wrong-signer.apk": make("wrong-signer.apk", PACKAGE, version + 1, True),
    }
    # Publish the staging marker only after every fixture has verified.
    (output / "fixture-index.json").write_text(json.dumps({
        "runnerPackage": PACKAGE, "runnerVersionCode": version,
        "runnerSignerSha256": runner_signers[0], "files": files,
    }, indent=2) + "\n", encoding="utf-8")
    # The unrelated key is disposable, and is never needed on the device.
    for path in work.iterdir():
        path.unlink()
    work.rmdir()
    print(output)


if __name__ == "__main__":
    main()
