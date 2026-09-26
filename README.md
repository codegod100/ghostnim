# ghostnim

A terminal emulator written in [Nim](https://nim-lang.org), built on
**libghostty-vt**, the embeddable C library for
[Ghostty](https://ghostty.org)'s terminal core.

![ghostnim screenshot](docs/screenshot.png)

libghostty-vt does the actual terminal work: VT parsing, screen and scrollback
state, reflow on resize, key and mouse encoding, selection, and the **render
state**, a snapshot of exactly what to draw with per-row dirty tracking.
ghostnim supplies the rest: an SDL2 window, SDL_ttf glyph rendering, a pty, and
the event loop.

## Features

- Rendering driven by libghostty's render-state API. Only the rows libghostty
  marks dirty are redrawn, into a persistent grid texture.
- Truecolor and 256 colours. Bold, italic, faint, inverse, invisible,
  underline, double underline, strikethrough and overline.
- Wide characters, plus per-glyph font fallback through fontconfig (CJK,
  symbols).
- Box-drawing and block characters drawn procedurally, so lines join
  seamlessly between cells.
- Cursor shapes (block, bar, underline, hollow) with blinking.
- Keyboard input through libghostty's key encoder: legacy/xterm sequences,
  DECCKM, and the kitty keyboard protocol when an app requests it.
- Mouse reporting through libghostty's mouse encoder (X10/normal/button/any,
  SGR and more). Hold Shift to select instead.
- Mouse selection, copy (Ctrl+Shift+C), paste (Ctrl+Shift+V or middle click)
  with bracketed paste.
- Scrollback with the mouse wheel or Shift+PageUp/PageDown.
- Window title from OSC 0/2, live resize with reflow, HiDPI.
- Font zoom: Ctrl+= / Ctrl+- / Ctrl+0.

## Building

### 1. Dependencies

- Nim ≥ 1.6 (Nim 2.x recommended)
- SDL2 and SDL2_ttf development packages
- fontconfig (`fc-match`) for font discovery and fallback (optional but
  recommended)
- Zig 0.16 and git, to build libghostty-vt

On Debian/Ubuntu:

```sh
sudo apt install nim libsdl2-dev libsdl2-ttf-dev fontconfig fonts-dejavu-core
# Zig 0.16: https://ziglang.org/download/ (or `pip install ziglang==0.16.0`)
```

### 2. Build libghostty-vt

```sh
nimble vt            # or: sh scripts/build-libghostty-vt.sh
```

This clones Ghostty at a pinned commit into `vendor/ghostty-src` and installs
headers and libraries into `vendor/ghostty-vt`. To use a libghostty-vt you
already have, set `GHOSTTY_VT_PREFIX=/path/to/prefix`.

The bindings need a recent libghostty-vt (Ghostty from 2026-08-15 or later, which
added `GhosttyRenderStateCursor`). If the build stops with "libghostty-vt
headers ... are too old", or the C compiler reports `unknown type name
'GhosttyRenderStateColors'` (or `...Cursor`, `GhosttyGridRef`, ...), the installed headers are stale. Rebuild them:

```sh
rm -rf vendor/ghostty-vt && nimble vt
```

### 3. Build ghostnim

```sh
nimble build -d:release
# or: nim c -d:release -o:ghostnim src/ghostnim.nim
./ghostnim
```

ghostnim links libghostty-vt statically by default. Set `GHOSTTY_VT_SHARED=1`
to link the shared library instead (needed if you built libghostty with
`SIMD=true`).

## Usage

```
ghostnim [options] [-e command [args...]]

  -f, --font NAME|PATH   font family (fontconfig) or font file   [monospace]
  -s, --size N           font size in points                      [14]
      --cols N           initial columns                          [100]
      --rows N           initial rows                             [30]
      --scrollback N     scrollback lines                         [10000]
      --screenshot FILE  render one frame after startup to FILE (BMP) and exit
  -e, --exec CMD ...     run CMD instead of $SHELL (must be last)
```

ghostnim sets `TERM=xterm-256color` for the child process.

## Layout

| File | Purpose |
| --- | --- |
| `src/ghostnim.nim` | App: window, event loop, pty wiring, input, selection, clipboard |
| `src/ghostnim/vt.nim` | Nim bindings for the libghostty-vt C API |
| `src/ghostnim/keys.nim` | `GhosttyKey` enum (generated from `key/event.h`) |
| `src/ghostnim/renderer.nim` | Walks the libghostty render state and draws cells with SDL |
| `src/ghostnim/boxdraw.nim` | Procedural box-drawing and block elements |
| `src/ghostnim/input.nim` | SDL scancode/modifier → libghostty key mapping |
| `src/ghostnim/pty.nim` | `forkpty`-based child process |
| `src/ghostnim/sdl.nim` | Minimal SDL2/SDL_ttf bindings |

## Notes

- libghostty-vt's API is still pre-1.0. The bindings target the commit pinned
  in `scripts/build-libghostty-vt.sh`.
- Not implemented yet: Kitty graphics, ligatures/shaping, colour emoji,
  hyperlinks, and a config file.
