# Venera AVIF decoder

This local package vendors the Dart API, native-assets hook and C shim from
[`avif_native` 0.1.1](https://pub.dev/packages/avif_native/versions/0.1.1).
The upstream package archive SHA-256 is
`0a374a7ddc6e48d671792bd33efd9f46f199389cdcd42561210bd886facbc62e`.
It is consumed as a direct path dependency, not a global dependency override.
The build-hook dependencies use `code_assets` 1.2.x and `hooks` 2.0.x to retain
compatibility with Flutter 3.41's pinned `meta` 1.17 dependency.

The Android arm64-v8a, armeabi-v7a and x86_64 decode-only libraries are rebuilt
from pinned libavif 1.4.2 and dav1d 1.5.3 sources with 16 KB ELF page alignment.
They are bundled under `native/android`; the hook checks each library's SHA-256
before bundling it. Normal Android builds require no extra download, Python,
Meson, NASM or CMake invocation for this package.

Other supported targets retain upstream HTTPS release URLs and SHA-256 checks:
Linux x64/arm64, Windows x64, macOS x64/arm64, and iOS arm64 plus simulator
x64/arm64. Linux upstream binaries require glibc 2.34 or newer. Web and Windows
arm64 are not supported. Android x86 is not a target of this application.

The hook defaults to `decode-dav1d`. Only decoding libraries are shipped; the
unchanged encoding API reports `UnsupportedError` if called. Application code
can explicitly select the profile with:

```yaml
hooks:
  user_defines:
    avif_native:
      features: decode
      decoder: dav1d
```

`AvifDecoder(bytes)` exposes dimensions, frame count and repetition count.
`getNextFrame()` returns straight RGBA bytes and duration; `dispose()` releases
the native decoder. These operations are synchronous: run decoding away from
the UI isolate and premultiply transparent pixels before passing RGBA to Flutter.

## Rebuilding Android libraries

Maintainers need Python 3.12+, CMake 3.21+, Ninja, Meson, NASM 2.14+ and the pinned
Android NDK 28.2.13676358. The initial rebuild downloads source archives whose
commits and SHA-256 checksums are recorded in `native/versions.json`.

```sh
python3 packages/avif_native/tool/build_android.py \
  --ndk /path/to/android-sdk/ndk/28.2.13676358
```

The script builds each ABI, strips symbols, verifies every ELF LOAD segment is
aligned to at least 16 KB, replaces the three bundled libraries and updates
their manifest checksums. It uses a temporary build directory and leaves no
downloaded sources or compiler output in this package. The runtime code and
third-party licenses are retained in `LICENSE` and `LICENSES/`.
