## Decides which runs of terminal text need shaping.
##
## Cells are normally drawn one character at a time, which is fast (a glyph
## cache hit per cell) but skips OpenType shaping: no programming ligatures
## (Monaspace Frozen, JetBrains Mono, Fira Code) and no contextual alternates
## (Monaspace's texture healing). For a run of same-styled cells we ask HarfBuzz whether
## shaping changes any glyph; only then is the run drawn as one string, which
## SDL_ttf shapes with HarfBuzz too. A run is only drawn that way if its shaped
## advances still add up to exactly one cell per character, so it stays on
## the grid.

import std/tables
from std/unicode import runeAt, runeLenAt
import harfbuzz

type
  RunKind* = enum
    runPlain     ## shaping changes nothing: draw cell by cell
    runShaped    ## shaping changes glyphs and stays on the grid
    runOffGrid   ## shaping changes glyphs but would break cell alignment

  Shaper* = object
    fonts: Table[string, ptr HbFont]    ## by font file; nil if unreadable
    buf: ptr HbBuffer
    cache: Table[(string, string), RunKind]

const maxCached = 8192

proc font(s: var Shaper, path: string): ptr HbFont =
  s.fonts.withValue(path, f): return f[]
  let blob = hb_blob_create_from_file(path.cstring)
  let face = hb_face_create(blob, 0)
  if hb_face_get_glyph_count(face) > 0: result = hb_font_create(face)
  hb_face_destroy(face)
  hb_blob_destroy(blob)
  s.fonts[path] = result

proc classify(s: var Shaper, font: ptr HbFont, text: string): RunKind =
  if s.buf == nil: s.buf = hb_buffer_create()
  hb_buffer_clear_contents(s.buf)
  hb_buffer_add_utf8(s.buf, text.cstring, text.len.cint, 0, text.len.cint)
  # Terminal text is laid out left to right, cell by cell; SDL_ttf renders
  # LTR by default too.
  hb_buffer_set_direction(s.buf, HB_DIRECTION_LTR)
  hb_buffer_guess_segment_properties(s.buf)
  hb_shape(font, s.buf, nil, 0)
  var n: cuint
  let infos = hb_buffer_get_glyph_infos(s.buf, addr n)
  let pos = hb_buffer_get_glyph_positions(s.buf, addr n)

  var cellAdvance: int32 = 0
  var total: int64 = 0
  var chars = 0
  var i = 0
  var changed = false
  while i < text.len:
    let cp = uint32(text.runeAt(i))
    var nominal: uint32
    discard hb_font_get_nominal_glyph(font, cp, addr nominal)
    if chars == 0: cellAdvance = hb_font_get_glyph_h_advance(font, nominal)
    if chars >= n.int or infos[chars].cluster != uint32(i) or
       infos[chars].codepoint != nominal:
      changed = true
    inc chars
    i += text.runeLenAt(i)
  if not changed and n.int == chars: return runPlain
  for k in 0 ..< n.int:
    total += pos[k].xAdvance
    if pos[k].yOffset != 0 or pos[k].yAdvance != 0: return runOffGrid
  if cellAdvance > 0 and total == int64(cellAdvance) * chars: runShaped
  else: runOffGrid

proc runKind*(s: var Shaper, fontPath, text: string): RunKind =
  ## How the run `text` (one character per cell) comes out in `fontPath`.
  let key = (fontPath, text)
  s.cache.withValue(key, k): return k[]
  let font = s.font(fontPath)
  result = if font == nil: runPlain else: s.classify(font, text)
  if s.cache.len >= maxCached: s.cache.clear()
  s.cache[key] = result

proc reset*(s: var Shaper) =
  ## Forget fonts and cached results (after the font files change).
  for f in s.fonts.values:
    if f != nil: hb_font_destroy(f)
  s.fonts.clear()
  s.cache.clear()

proc destroy*(s: var Shaper) =
  s.reset()
  if s.buf != nil: hb_buffer_destroy(s.buf)
  s.buf = nil
