#!/usr/bin/env sh
# Render packaging/ghostnim.svg into the raster icons derived from it:
#   packaging/ghostnim.png       256x256, for the AppImage / desktop menus
#   packaging/ghostnim-128.bmp   128x128 32-bit BMP, embedded in the binary
#                                as the window icon (SDL2 decodes BMP natively)
#
# Requirements: rsvg-convert (librsvg) and ImageMagick (magick or convert).
# Without them it leaves the committed icons alone, as long as the SVG still
# matches the checksum recorded when they were rendered (ghostnim.svg.sha256).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SVG="$ROOT/packaging/ghostnim.svg"
PNG="$ROOT/packaging/ghostnim.png"
BMP="$ROOT/packaging/ghostnim-128.bmp"
SUM="$ROOT/packaging/ghostnim.svg.sha256"

svg_sum() { sha256sum "$SVG" | cut -d' ' -f1; }

if command -v magick >/dev/null 2>&1; then IM=magick
elif command -v convert >/dev/null 2>&1; then IM=convert
else IM=""
fi

if ! command -v rsvg-convert >/dev/null 2>&1 || [ -z "$IM" ]; then
  if [ "$(svg_sum)" != "$(cat "$SUM" 2>/dev/null)" ]; then
    echo "error: $SVG changed; install rsvg-convert and ImageMagick to re-render the icons" >&2
    exit 1
  fi
  echo "rsvg-convert/ImageMagick not found; using the committed icons"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rsvg-convert -w 256 -h 256 -o "$tmp/256.png" "$SVG"
rsvg-convert -w 128 -h 128 -o "$tmp/128.png" "$SVG"
# Strip timestamps/metadata so unchanged icons stay byte-identical.
"$IM" "$tmp/256.png" -strip -define png:exclude-chunks=date,time "$PNG"
# BMP4 keeps the alpha channel (with an explicit alpha mask).
"$IM" "$tmp/128.png" -define bmp:format=bmp4 "$BMP"
svg_sum > "$SUM"
echo "rendered $PNG and $BMP"
