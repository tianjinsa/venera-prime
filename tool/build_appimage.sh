#!/usr/bin/env bash
set -euo pipefail

arch="${1:?Usage: build_appimage.sh x86_64|aarch64}"
case "$arch" in
  x86_64|aarch64) ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

bundle=$(find build/linux -type d -path '*/release/bundle' -print -quit)
test -n "$bundle"
output="$PWD/build/linux/appimage"
mkdir -p "$output"
appdir="$output/VeneraPrime.AppDir"
rm -rf "$appdir"
cp -a "$bundle" "$appdir"
cat > "$appdir/venera.desktop" <<'EOF'
[Desktop Entry]
Name=Venera Prime
Exec=venera
Icon=venera
Type=Application
Categories=Utility;
EOF
cp assets/app_icon.png "$appdir/venera.png"

linuxdeploy="$output/linuxdeploy-${arch}.AppImage"
appimagetool="$output/appimagetool-${arch}.AppImage"
curl -L --fail -o "$linuxdeploy" "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${arch}.AppImage"
curl -L --fail -o "$appimagetool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
chmod +x "$linuxdeploy" "$appimagetool"
export APPIMAGE_EXTRACT_AND_RUN=1

# WebKit launches subprocesses and loads an injected bundle in addition to
# linking libwebkit2gtk. Deploy all of them, including their ELF dependencies.
webkit_libdir=$(pkg-config --variable=libdir webkit2gtk-4.1)
webkit_libexecdir=$(pkg-config --variable=libexecdir webkit2gtk-4.1)
webkit_helpers=""
for directory in "$webkit_libexecdir" "$webkit_libdir" /usr/libexec /usr/lib; do
  if [[ -n "$directory" && -x "$directory/webkit2gtk-4.1/WebKitWebProcess" ]]; then
    webkit_helpers="$directory/webkit2gtk-4.1"
    break
  fi
done
test -x "$webkit_helpers/WebKitNetworkProcess"
test -x "$webkit_helpers/WebKitWebProcess"
mkdir -p "$appdir/usr/libexec" "$appdir/usr/lib"
cp -a "$webkit_helpers" "$appdir/usr/libexec/webkit2gtk-4.1"
cp -a "$webkit_libdir/webkit2gtk-4.1" "$appdir/usr/lib/webkit2gtk-4.1"
gio_modules=$(pkg-config --variable=giomoduledir gio-2.0)
test -d "$gio_modules"
cp -a "$gio_modules" "$appdir/usr/lib/gio"

deploy_args=(--appdir "$appdir" --executable "$appdir/venera")
while IFS= read -r -d '' library; do
  deploy_args+=(--library "$library")
done < <(find "$appdir/lib" "$appdir/usr/lib/webkit2gtk-4.1" "$appdir/usr/lib/gio" -type f -name '*.so*' -print0)
for helper in "$appdir/usr/libexec/webkit2gtk-4.1/"WebKit*Process; do
  if [[ -f "$helper" && -x "$helper" ]]; then
    deploy_args+=(--executable "$helper")
  fi
done
"$linuxdeploy" "${deploy_args[@]}"

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/lib:$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export WEBKIT_EXEC_PATH="$HERE/usr/libexec/webkit2gtk-4.1"
export WEBKIT_INJECTED_BUNDLE_PATH="$HERE/usr/lib/webkit2gtk-4.1/injected-bundle"
export GIO_MODULE_DIR="$HERE/usr/lib/gio"
exec "$HERE/venera" "$@"
EOF
chmod +x "$appdir/AppRun"

# Fail packaging if WebKit or any deployed process still has unresolved links.
while IFS= read -r -d '' binary; do
  if LD_LIBRARY_PATH="$appdir/lib:$appdir/usr/lib" ldd "$binary" | grep -q 'not found'; then
    echo "Unresolved dependency: $binary" >&2
    exit 1
  fi
done < <(find "$appdir" -type f \( -name '*.so*' -o -name 'WebKit*Process' -o -name venera \) -print0)
test -f "$appdir/usr/lib/libwebkit2gtk-4.1.so.0"
version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
"$appimagetool" "$appdir" "$output/Venera-Prime-${version}-${arch}.AppImage"
