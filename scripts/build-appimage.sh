#!/usr/bin/env sh
# Package ghostnim as an AppImage with linuxdeploy.
#
# Builds a release binary, lays out build/AppDir, bundles the shared libraries
# it needs (SDL2, SDL2_ttf, freetype, ...) and writes
# ghostnim-<version>-<arch>.AppImage into the repository root.
#
# Requirements: libghostty-vt already built (`nimble vt`), SDL2 + SDL2_ttf,
# curl (to fetch linuxdeploy on first use).
#
# Environment:
#   LINUXDEPLOY   linuxdeploy executable     (default: download into build/tools)
#   VERSION       version in the file name   (default: from ghostnim.nimble)
#   SKIP_BUILD=1  package the existing ./ghostnim instead of rebuilding
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build"
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"
ARCH=$(uname -m)
VERSION=${VERSION:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/ghostnim.nimble")}

cd "$ROOT"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  if [ -z "${GHOSTTY_VT_PREFIX:-}" ] && [ ! -d "$ROOT/vendor/ghostty-vt/lib" ]; then
    echo "error: libghostty-vt not found; run 'nimble vt' first" >&2
    exit 1
  fi
  nimble build -d:release
fi
[ -x "$ROOT/ghostnim" ] || { echo "error: ./ghostnim not built" >&2; exit 1; }

# linuxdeploy plus its AppImage output plugin, which it finds next to itself.
fetch() {
  [ -x "$TOOLS/$1" ] && return
  mkdir -p "$TOOLS"
  echo "fetching $1"
  curl -fL --retry 3 -o "$TOOLS/$1.part" "$2"
  chmod +x "$TOOLS/$1.part"
  mv "$TOOLS/$1.part" "$TOOLS/$1"
}
if [ -z "${LINUXDEPLOY:-}" ]; then
  fetch "linuxdeploy-$ARCH.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
  LINUXDEPLOY="$TOOLS/linuxdeploy-$ARCH.AppImage"
fi
if ! command -v linuxdeploy-plugin-appimage >/dev/null 2>&1; then
  fetch "linuxdeploy-plugin-appimage-$ARCH.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-$ARCH.AppImage"
  PATH="$TOOLS:$PATH"
fi

# sdl2-compat (what Arch and other newer distros ship as SDL2) dlopen()s
# SDL3 at runtime, so linuxdeploy can't see that dependency. Bundle it
# explicitly; the $ORIGIN rpath linuxdeploy sets lets libSDL2 find it.
extra_libs=""
sdl2=$(ldd "$ROOT/ghostnim" | sed -n 's/.*libSDL2-2\.0\.so\.0 => \([^ ]*\).*/\1/p')
if [ -n "$sdl2" ] && grep -q "libSDL3.so.0" "$sdl2" 2>/dev/null; then
  sdl3="$(dirname "$sdl2")/libSDL3.so.0"
  [ -e "$sdl3" ] || { echo "error: $sdl2 is sdl2-compat but $sdl3 was not found" >&2; exit 1; }
  extra_libs="--library $sdl3"
fi

rm -rf "$APPDIR"
# NO_STRIP: linuxdeploy's bundled strip is too old for binaries from newer
# toolchains (e.g. .relr.dyn on Arch) and fails on them.
# APPIMAGE_EXTRACT_AND_RUN: run linuxdeploy's own AppImages without FUSE.
# shellcheck disable=SC2086
NO_STRIP=1 APPIMAGE_EXTRACT_AND_RUN=1 LINUXDEPLOY_OUTPUT_VERSION="$VERSION" \
  "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$ROOT/ghostnim" \
    --desktop-file "$ROOT/packaging/ghostnim.desktop" \
    --icon-file "$ROOT/packaging/ghostnim.svg" \
    $extra_libs \
    --output appimage

echo
echo "built $ROOT/ghostnim-$VERSION-$ARCH.AppImage"
