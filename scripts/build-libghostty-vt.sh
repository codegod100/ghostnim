#!/usr/bin/env sh
# Build libghostty-vt from Ghostty's source and install it into
# ./vendor/ghostty-vt (headers + libghostty-vt.a/.so), where config.nims
# looks for it.
#
# Requirements: git and Zig 0.16.x (https://ziglang.org/download/).
#
# Environment:
#   GHOSTTY_REF   Ghostty commit/tag/branch to build   (default: pinned below)
#   ZIG           zig executable                       (default: zig)
#   SIMD          true|false, SIMD-accelerated parsing (default: false)
#                 true needs libc++ at link time, so only use it together
#                 with GHOSTTY_VT_SHARED=1 when building ghostnim.
set -eu

GHOSTTY_REF=${GHOSTTY_REF:-6301810a48aaa3426887a4316668f18833a40138}
ZIG=${ZIG:-zig}
SIMD=${SIMD:-false}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/vendor/ghostty-src"
PREFIX="$ROOT/vendor/ghostty-vt"

if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "error: zig not found (set ZIG=/path/to/zig). Ghostty needs Zig 0.16." >&2
  exit 1
fi
case "$("$ZIG" version)" in
  0.16.*) ;;
  *) echo "warning: Ghostty expects Zig 0.16.x, found $("$ZIG" version)" >&2 ;;
esac

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$GHOSTTY_REF^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch origin "$GHOSTTY_REF" || git -C "$SRC" fetch origin
fi
git -C "$SRC" -c advice.detachedHead=false checkout "$GHOSTTY_REF"

cd "$SRC"
"$ZIG" build \
  -Demit-lib-vt \
  -Doptimize=ReleaseFast \
  -Dsimd="$SIMD" \
  --prefix "$PREFIX"

echo
echo "libghostty-vt installed to $PREFIX"
ls "$PREFIX/lib"
