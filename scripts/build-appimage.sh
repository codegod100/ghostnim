#!/usr/bin/env sh
# Package ghostnim as an AppImage with linuxdeploy.
#
# Builds libghostty-vt (if needed) and a release binary, lays out
# build/AppDir with everything ghostnim needs at runtime, and writes
# ghostnim-<version>-<arch>.AppImage into the repository root. Bundled:
#   - shared libraries (SDL2, SDL2_ttf, freetype, ...; SDL3 for sdl2-compat)
#   - fc-match and fc-list, which ghostnim runs to find fonts
#   - Monaspace Neon Frozen (default font), DejaVu Sans Mono (fallback) and
#     Symbols Nerd Font (icon fallback), plus a fontconfig config that adds
#     them to the host's fonts
#   - the icon, as SVG and a 256x256 PNG rendered from it
#     (scripts/build-icons.sh, which also renders the embedded window icon)
#
# Requirements: SDL2 + SDL2_ttf, fontconfig (fc-match/fc-list), curl, tar with
# bzip2/xz support; Zig 0.16 if libghostty-vt isn't built yet; rsvg-convert
# and ImageMagick if packaging/ghostnim.svg has changed.
#
# Environment:
#   LINUXDEPLOY   linuxdeploy executable     (default: download into build/tools)
#   VERSION       version in the file name   (default: from ghostnim.nimble)
#   OUTPUT        AppImage file name         (default: ghostnim-<version>-<arch>.AppImage)
#   NIM_FLAGS     extra flags for `nimble build`, e.g. -d:autoUpdate
#   LDAI_UPDATE_INFORMATION   update information to embed; linuxdeploy then
#                 also writes <OUTPUT>.zsync (see .github/workflows/appimage.yml)
#   SKIP_BUILD=1  package the existing ./ghostnim instead of rebuilding
#   MONASPACE_VERSION, DEJAVU_VERSION, NERD_FONTS_VERSION
#                 bundled font releases
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build"
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"
ARCH=$(uname -m)
VERSION=${VERSION:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/ghostnim.nimble")}
OUTPUT=${OUTPUT:-ghostnim-$VERSION-$ARCH.AppImage}
MONASPACE_VERSION=${MONASPACE_VERSION:-1.200}
DEJAVU_VERSION=${DEJAVU_VERSION:-2.37}
NERD_FONTS_VERSION=${NERD_FONTS_VERSION:-3.4.0}

cd "$ROOT"

# Re-render the PNG/BMP icons from the SVG (the BMP is embedded in the binary,
# so this must run before building).
sh "$ROOT/scripts/build-icons.sh"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  if [ -z "${GHOSTTY_VT_PREFIX:-}" ] && [ ! -d "$ROOT/vendor/ghostty-vt/lib" ]; then
    echo "libghostty-vt not found; building it"
    sh "$ROOT/scripts/build-libghostty-vt.sh"
  fi
  # shellcheck disable=SC2086
  nimble build -d:release ${NIM_FLAGS:-}
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

# Fonts: downloaded once into build/tools, then copied into the AppDir.
fetch_font() { # name url
  [ -d "$TOOLS/$1" ] && return
  mkdir -p "$TOOLS"
  echo "fetching $1"
  curl -fL --retry 3 -o "$TOOLS/$1.archive" "$2"
  rm -rf "$TOOLS/$1.part" && mkdir "$TOOLS/$1.part"
  tar -xf "$TOOLS/$1.archive" -C "$TOOLS/$1.part"
  rm "$TOOLS/$1.archive"
  mv "$TOOLS/$1.part" "$TOOLS/$1"
}
# Monaspace's release zip is ~1 GB, so fetch just the files we ship from the
# release tag.
monaspace="$TOOLS/monaspace-$MONASPACE_VERSION"
if [ ! -d "$monaspace" ]; then
  echo "fetching monaspace-$MONASPACE_VERSION"
  rm -rf "$monaspace.part" && mkdir -p "$monaspace.part"
  for f in LICENSE fonts/frozen/MonaspaceNeonFrozen-Regular.ttf \
           fonts/frozen/MonaspaceNeonFrozen-Bold.ttf fonts/frozen/MonaspaceNeonFrozen-Italic.ttf \
           fonts/frozen/MonaspaceNeonFrozen-BoldItalic.ttf; do
    curl -fL --retry 3 -o "$monaspace.part/$(basename "$f")" \
      "https://raw.githubusercontent.com/githubnext/monaspace/v$MONASPACE_VERSION/$f"
  done
  mv "$monaspace.part" "$monaspace"
fi
fetch_font "dejavu-$DEJAVU_VERSION" \
  "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_$(echo "$DEJAVU_VERSION" | tr . _)/dejavu-fonts-ttf-$DEJAVU_VERSION.tar.bz2"
fetch_font "nerd-fonts-symbols-$NERD_FONTS_VERSION" \
  "https://github.com/ryanoasis/nerd-fonts/releases/download/v$NERD_FONTS_VERSION/NerdFontsSymbolsOnly.tar.xz"

fc_match=$(command -v fc-match) || { echo "error: fc-match not found (install fontconfig)" >&2; exit 1; }
fc_list=$(command -v fc-list) || { echo "error: fc-list not found (install fontconfig)" >&2; exit 1; }

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
share="$APPDIR/usr/share/ghostnim"
mkdir -p "$share/fonts/monaspace" "$share/fonts/dejavu" "$share/fonts/nerd-fonts-symbols"
cp "$ROOT/packaging/fonts.conf" "$share/fonts.conf"
cp "$monaspace"/* "$share/fonts/monaspace/"
dejavu="$TOOLS/dejavu-$DEJAVU_VERSION/dejavu-fonts-ttf-$DEJAVU_VERSION"
cp "$dejavu"/ttf/DejaVuSansMono*.ttf "$dejavu/LICENSE" "$share/fonts/dejavu/"
nerd="$TOOLS/nerd-fonts-symbols-$NERD_FONTS_VERSION"
cp "$nerd/SymbolsNerdFontMono-Regular.ttf" "$nerd/LICENSE" "$share/fonts/nerd-fonts-symbols/"

# NO_STRIP: linuxdeploy's bundled strip is too old for binaries from newer
# toolchains (e.g. .relr.dyn on Arch) and fails on them.
# APPIMAGE_EXTRACT_AND_RUN: run linuxdeploy's own AppImages without FUSE.
# shellcheck disable=SC2086
NO_STRIP=1 APPIMAGE_EXTRACT_AND_RUN=1 LINUXDEPLOY_OUTPUT_VERSION="$VERSION" LDAI_OUTPUT="$OUTPUT" \
  "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$ROOT/ghostnim" \
    --executable "$fc_match" \
    --executable "$fc_list" \
    --desktop-file "$ROOT/packaging/ghostnim.desktop" \
    --icon-file "$ROOT/packaging/ghostnim.svg" \
    --icon-file "$ROOT/packaging/ghostnim.png" \
    $extra_libs \
    --output appimage

echo
echo "built $ROOT/$OUTPUT"
