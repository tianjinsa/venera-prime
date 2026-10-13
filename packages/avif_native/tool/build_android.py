#!/usr/bin/env python3
"""Rebuild the bundled Android decoders; normal app builds do not run this."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


PACKAGE = Path(__file__).resolve().parents[1]
TARGETS = {
    "android-arm64": "arm64-v8a",
    "android-arm": "armeabi-v7a",
    "android-x64": "x86_64",
}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def source(name, spec, work):
    archive = work / f"{name}.tar.gz"
    with urllib.request.urlopen(spec["archiveUrl"], timeout=60) as response:
        archive.write_bytes(response.read())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != spec["archiveSha256"]:
        raise RuntimeError(f"{name} source checksum mismatch: {digest}")
    destination = work / name
    destination.mkdir()
    with tarfile.open(archive) as contents:
        for member in contents.getmembers():
            parts = Path(member.name).parts[1:]
            if not parts:
                continue
            if member.issym() or member.islnk():
                raise RuntimeError(f"Unexpected source archive link: {member.name}")
            member.name = str(Path(*parts))
            contents.extract(member, destination, filter="data")
    return destination


def verify_alignment(library, readelf):
    report = subprocess.check_output(
        [str(readelf), "--program-headers", "--wide", str(library)], text=True
    )
    loads = [line.split() for line in report.splitlines() if line.strip().startswith("LOAD")]
    if not loads or any(int(fields[-1], 16) < 16384 for fields in loads):
        raise RuntimeError(f"Library does not have 16 KB ELF alignment: {library}\n{report}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk", required=True, type=Path, help="Android NDK 28.2.13676358")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    ndk = args.ndk.resolve()
    if "Pkg.Revision = 28.2.13676358" not in (ndk / "source.properties").read_text():
        raise RuntimeError("Use pinned NDK 28.2.13676358 to reproduce these libraries")
    for tool in ("cmake", "ninja", "meson", "nasm"):
        if not shutil.which(tool):
            raise RuntimeError(f"Missing build tool: {tool}")
    prebuilts = list((ndk / "toolchains/llvm/prebuilt").iterdir())
    if len(prebuilts) != 1:
        raise RuntimeError("Expected one NDK host toolchain")
    suffix = ".exe" if os.name == "nt" else ""
    strip = prebuilts[0] / "bin" / f"llvm-strip{suffix}"
    readelf = prebuilts[0] / "bin" / f"llvm-readelf{suffix}"
    versions = json.loads((PACKAGE / "native/versions.json").read_text())
    manifest_path = PACKAGE / "native/manifest.json"
    manifest = json.loads(manifest_path.read_text())

    with tempfile.TemporaryDirectory(prefix="venera-avif-build-") as temporary:
        work = Path(temporary)
        libavif = source("libavif", versions["libavif"], work)
        dav1d = source("dav1d", versions["dav1d"], work)
        # Copy instead of symlinking so the script also works without Windows
        # developer-mode symlink privileges.
        shutil.copytree(dav1d, libavif / "ext/dav1d")
        for target, abi in TARGETS.items():
            build = work / target
            run(
                "cmake", "-S", PACKAGE / "native", "-B", build, "-G", "Ninja",
                "-DCMAKE_BUILD_TYPE=MinSizeRel", "-DAVIF_PROFILE=decode-dav1d",
                f"-DLIBAVIF_SOURCE_DIR={libavif}",
                f"-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake",
                f"-DANDROID_ABI={abi}", "-DANDROID_PLATFORM=21",
                "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384",
            )
            run("cmake", "--build", build, "--target", "avif_native", "--parallel", args.jobs)
            built = build / "libavif_native.so"
            run(strip, "--strip-unneeded", built)
            verify_alignment(built, readelf)
            destination = PACKAGE / "native/android" / abi / built.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(built, destination)
            manifest["artifacts"][f"{target}-decode-dav1d"] = {
                "path": destination.relative_to(PACKAGE / "native").as_posix(),
                "librarySha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                "fileName": built.name,
            }
            print(f"Bundled {abi}: {destination.stat().st_size} bytes, ELF alignment >= 16 KB")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
