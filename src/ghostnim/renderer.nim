## Draws a libghostty-vt render state into an SDL window.
##
## libghostty-vt owns all terminal state. Each frame we ask it to update its
## render state snapshot, then walk the dirty rows/cells it reports and draw
## them into a persistent grid texture. Only rows libghostty marks dirty are
## redrawn; the cursor and the tab bar are composited on top every frame.

import std/[tables, osproc, strutils, os, strtabs, options, math]
from std/unicode import runes, runeLen, runeSubStr, `$`
import vt, sdl, boxdraw, shaping

type
  Face* = enum
    faceRegular, faceBold, faceItalic, faceBoldItalic

  Glyph = object
    tex: TexturePtr
    w, h: cint               ## size to draw at, in output pixels
    color: bool              ## has its own colours (emoji); don't tint it

  Rgb* = object
    ## Plain Nim colour; C structs are kept out of GC'd objects.
    r*, g*, b*: uint8

  CellInfo = object
    text: string
    fg, bg: Rgb
    hasBg: bool
    face: Face
    faint, invisible, strike, overline: bool
    underline: cint
    wide: bool

  TabHitKind* = enum
    hitNone, hitTab, hitClose, hitNew

  TabHit* = object
    kind*: TabHitKind
    index*: int

  Renderer* = ref object
    r*: RendererPtr
    fontPaths: array[Face, string]
    fonts: array[Face, FontPtr]
    shapePaths: array[Face, string]   ## file each face was opened from; "" if synthesized
    shaper: Shaper
    shaping*: bool           ## draw ligatures and contextual alternates
    runs: Table[(string, int), Glyph]   ## shaped runs, by (text, face)
    fontSize*: int
    scale*: float            ## output pixels per window pixel (HiDPI)
    cellW*, cellH*: int
    ascent: int
    pad*: int                ## padding around the grid, in output pixels
    top*: int                ## height of the bars above the grid
    tabH*: int               ## height of the tab bar
    folderH*: int            ## height of the recent-folders strip under it
    folderBar*: bool         ## whether the recent-folders strip is shown
    glyphs: Table[(string, int), Glyph]
    fallbackByFile: Table[string, FontPtr]
    fallbackForCp: Table[uint32, FontPtr]
    grid: TexturePtr
    gridW, gridH: int
    cells: seq[seq[CellInfo]]
    rowIter: GhosttyRenderStateRowIterator
    rowCells: GhosttyRenderStateRowCells
    colors*: GhosttyRenderStateColors
    selectionFg*, selectionBg*: Option[Rgb]   ## unset: swap fg and bg
    focused*: bool

proc rgb*(c: GhosttyColorRgb): Rgb {.inline.} = Rgb(r: c.r, g: c.g, b: c.b)

proc check(res: GhosttyResult, what: string) =
  if res != GHOSTTY_SUCCESS:
    raise newException(CatchableError, what & " failed: " & $res)

# The AppImage bundles fc-match/fc-list next to the binary, plus fonts and a
# fontconfig config (system config + the bundled font dir) under share/.
proc bundledShare(): string = getAppDir() / ".." / "share" / "ghostnim"

proc bundledFonts(): seq[string] =
  ## Font files shipped in the AppImage (empty for a normal build).
  let dir = bundledShare() / "fonts"
  if dirExists(dir):
    for f in walkDirRec(dir):
      if f.endsWith(".ttf") or f.endsWith(".otf"): result.add f

proc fcRun(tool, args: string): tuple[output: string, exitCode: int] =
  ## Run a fontconfig tool, preferring the bundled one and bundled config.
  let bundled = getAppDir() / tool
  let exe = if fileExists(bundled): quoteShell(bundled) else: tool
  var env: StringTableRef = nil
  let conf = bundledShare() / "fonts.conf"
  if fileExists(conf) and not existsEnv("FONTCONFIG_FILE"):
    env = newStringTable()
    for k, v in envPairs(): env[k] = v
    env["FONTCONFIG_FILE"] = conf
  execCmdEx(exe & " " & args, {poStdErrToStdOut, poUsePath}, env)

proc fcMatch(pattern: string): string =
  ## Ask fontconfig for the best font file matching `pattern`.
  try:
    let (output, code) = fcRun("fc-match", "-f '%{file}' " & quoteShell(pattern))
    if code == 0 and fileExists(output.strip): result = output.strip
  except OSError:
    discard

proc fcList(pattern: string): seq[string] =
  ## Font files matching `pattern`, monospace ones first.
  try:
    let (output, code) = fcRun("fc-list", "-f '%{spacing}\\t%{file}\\n' " & quoteShell(pattern))
    if code != 0: return
    var mono: seq[string]
    for line in output.splitLines:
      let parts = line.split('\t', 1)
      if parts.len != 2 or not fileExists(parts[1]): continue
      # fontconfig spacing: 100 = mono, 110 = charcell
      if parts[0] in ["100", "110"]: mono.add parts[1] else: result.add parts[1]
    result = mono & result
  except OSError:
    discard

const DefaultFonts* = ["Monaspace Neon Frozen", "Monaspace Neon"]
  ## Tried in order when no font is configured. The Frozen build has its
  ## ligatures (ss01-ss10) and texture healing on by default, which SDL_ttf
  ## needs since it can't turn on OpenType features; plain Monaspace Neon
  ## still gets texture healing.

proc resolveFonts*(primary: string): array[Face, string] =
  ## Find regular/bold/italic/bold-italic font files. `primary` may be a
  ## path to a font file or a fontconfig family name.
  # fc-match never fails, it substitutes: only ask for a default family by
  # name when it is installed (or bundled), else we could get a proportional
  # font.
  var family = primary
  if family.len == 0:
    family = "monospace"
    for f in DefaultFonts:
      if fcList(f).len > 0:
        family = f
        break
  if fileExists(primary):
    result[faceRegular] = primary
  else:
    result[faceRegular] = fcMatch(family)
    result[faceBold] = fcMatch(family & ":bold")
    result[faceItalic] = fcMatch(family & ":italic")
    result[faceBoldItalic] = fcMatch(family & ":bold:italic")
  if result[faceRegular].len == 0:
    for p in [bundledShare() / "fonts" / "monaspace" / "MonaspaceNeonFrozen-Regular.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
              "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
              "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
              bundledShare() / "fonts" / "dejavu" / "DejaVuSansMono.ttf"]:
      if fileExists(p):
        result[faceRegular] = p
        break
  if result[faceRegular].len == 0:
    raise newException(IOError, "no monospace font found; pass --font PATH")

proc loadFonts(rd: Renderer) =
  for f in Face:
    if rd.fonts[f] != nil: closeFont(rd.fonts[f])
    rd.fonts[f] = nil
  let px = cint(float(rd.fontSize) * rd.scale + 0.5)
  for f in Face:
    let path = if rd.fontPaths[f].len > 0 and rd.fontPaths[f] != rd.fontPaths[faceRegular]:
                 rd.fontPaths[f] else: ""
    rd.shapePaths[f] = ""
    if path.len > 0:
      rd.fonts[f] = openFont(path.cstring, px)
      if rd.fonts[f] != nil: rd.shapePaths[f] = path
    if rd.fonts[f] == nil:
      # Synthesize the style from the regular face.
      rd.fonts[f] = openFont(rd.fontPaths[faceRegular].cstring, px)
      if rd.fonts[f] == nil:
        raise newException(IOError, "could not open font " &
                           rd.fontPaths[faceRegular] & ": " & $getError())
      case f
      of faceRegular: rd.shapePaths[f] = rd.fontPaths[faceRegular]
      of faceBold: setFontStyle(rd.fonts[f], TTF_STYLE_BOLD)
      of faceItalic: setFontStyle(rd.fonts[f], TTF_STYLE_ITALIC)
      of faceBoldItalic: setFontStyle(rd.fonts[f], TTF_STYLE_BOLD or TTF_STYLE_ITALIC)

  var minx, maxx, miny, maxy, advance: cint
  discard glyphMetrics32(rd.fonts[faceRegular], uint32('M'), addr minx, addr maxx,
                         addr miny, addr maxy, addr advance)
  rd.cellW = max(1, advance.int)
  rd.cellH = max(1, fontLineSkip(rd.fonts[faceRegular]).int)
  rd.ascent = fontAscent(rd.fonts[faceRegular]).int
  rd.pad = int(4.0 * rd.scale)
  rd.tabH = rd.cellH + int(10.0 * rd.scale)
  rd.folderH = rd.cellH + int(10.0 * rd.scale)
  rd.top = rd.tabH + (if rd.folderBar: rd.folderH else: 0)

proc clearGlyphCache(rd: Renderer) =
  for g in rd.glyphs.values: destroyTexture(g.tex)
  rd.glyphs.clear()
  for g in rd.runs.values: destroyTexture(g.tex)
  rd.runs.clear()
  for f in rd.fallbackByFile.values: closeFont(f)
  rd.fallbackByFile.clear()
  rd.fallbackForCp.clear()

proc newRenderer*(r: RendererPtr, fontPaths: array[Face, string], fontSize: int,
                  scale: float): Renderer =
  result = Renderer(r: r, fontPaths: fontPaths, fontSize: fontSize, scale: scale,
                    focused: true, shaping: true)
  result.loadFonts()
  check ghostty_render_state_row_iterator_new(nil, addr result.rowIter),
    "ghostty_render_state_row_iterator_new"
  check ghostty_render_state_row_cells_new(nil, addr result.rowCells),
    "ghostty_render_state_row_cells_new"
  result.colors = initSized(GhosttyRenderStateColors)

proc setFonts*(rd: Renderer, fontPaths: array[Face, string]) =
  rd.fontPaths = fontPaths
  rd.shaper.reset()
  rd.clearGlyphCache()
  rd.loadFonts()

proc setFontSize*(rd: Renderer, size: int) =
  rd.fontSize = max(4, size)
  rd.clearGlyphCache()
  rd.loadFonts()

proc setFolderBar*(rd: Renderer, on: bool) =
  ## Show or hide the recent-folders strip under the tab bar.
  rd.folderBar = on
  rd.top = rd.tabH + (if on: rd.folderH else: 0)

proc destroy*(rd: Renderer) =
  rd.clearGlyphCache()
  rd.shaper.destroy()
  for f in Face:
    if rd.fonts[f] != nil: closeFont(rd.fonts[f])
  if rd.grid != nil: destroyTexture(rd.grid)
  ghostty_render_state_row_cells_free(rd.rowCells)
  ghostty_render_state_row_iterator_free(rd.rowIter)

proc newRenderState*(): GhosttyRenderState =
  ## Each terminal gets its own render state so dirty tracking stays per tab.
  check ghostty_render_state_new(nil, addr result), "ghostty_render_state_new"

proc gridSize*(rd: Renderer, outW, outH: int): (int, int) =
  ## Number of (cols, rows) that fit in an output area of the given size.
  (max(1, (outW - 2 * rd.pad) div rd.cellW),
   max(1, (outH - rd.top - 2 * rd.pad) div rd.cellH))

proc resize*(rd: Renderer, outW, outH: int) =
  ## Recreate the grid texture for a new output size.
  if rd.grid != nil and rd.gridW == outW and rd.gridH == outH: return
  if rd.grid != nil: destroyTexture(rd.grid)
  rd.grid = createTexture(rd.r, PIXELFORMAT_ARGB8888, TEXTUREACCESS_TARGET,
                          cint(max(1, outW)), cint(max(1, outH)))
  rd.gridW = outW
  rd.gridH = outH

# --- glyphs --------------------------------------------------------------

proc firstCodepoint(s: string): uint32 =
  ## Decode the first UTF-8 codepoint of `s`.
  if s.len == 0: return 0
  let b0 = uint32(s[0])
  if b0 < 0x80: return b0
  var n, cp: uint32
  if (b0 and 0xE0) == 0xC0: (n, cp) = (1'u32, b0 and 0x1F)
  elif (b0 and 0xF0) == 0xE0: (n, cp) = (2'u32, b0 and 0x0F)
  else: (n, cp) = (3'u32, b0 and 0x07)
  for i in 1 .. int(n):
    if i >= s.len: return 0xFFFD
    cp = (cp shl 6) or (uint32(s[i]) and 0x3F)
  cp

proc fontFor(rd: Renderer, face: Face, text: string): FontPtr =
  ## Pick the font to draw `text` with, falling back via fontconfig for
  ## codepoints the configured font doesn't cover (CJK, symbols, emoji...).
  result = rd.fonts[face]
  let cp = firstCodepoint(text)
  if cp < 0x80 or glyphIsProvided32(result, cp) != 0: return
  if cp in rd.fallbackForCp:
    let f = rd.fallbackForCp[cp]
    return if f != nil: f else: result
  var found: FontPtr = nil
  # Not `toHex(cp, 4)`: that truncates codepoints above U+FFFF (e.g. Nerd
  # Font's Material Design icons at U+F0000+) and asks for the wrong char.
  let charset = toHex(cp.int, if cp > 0xFFFF: 6 else: 4).toLowerAscii
  # fc-match always returns *some* font, even one lacking the glyph, so fall
  # back to every font fontconfig says covers it.
  var candidates = @[fcMatch("monospace:charset=" & charset)] & fcList(":charset=" & charset)
  # Private Use Area glyphs mean whatever each font says, and prompts expect
  # Nerd Font icons there, so prefer the bundled Nerd Font for them. Otherwise
  # bundled fonts come last, for hosts where fontconfig is missing or broken.
  let pua = cp in 0xE000'u32 .. 0xF8FF'u32 or cp >= 0xF0000'u32
  candidates = if pua: bundledFonts() & candidates else: candidates & bundledFonts()
  for file in candidates:
    if file.len == 0 or file == rd.fontPaths[faceRegular]: continue
    if file notin rd.fallbackByFile:
      rd.fallbackByFile[file] = openFont(file.cstring, cint(float(rd.fontSize) * rd.scale + 0.5))
    let f = rd.fallbackByFile[file]
    if f != nil and glyphIsProvided32(f, cp) != 0:
      found = f
      break
  rd.fallbackForCp[cp] = found
  if found != nil: result = found

proc isColorSurface(surf: SurfacePtr): bool =
  ## True if a glyph rendered in white came back with other colours, i.e. it
  ## came from a colour font (emoji). TTF_RenderUTF8_Blended returns ARGB8888.
  if surf.pixels == nil: return false
  for y in 0 ..< surf.h.int:
    let row = cast[ptr UncheckedArray[uint32]](
      cast[uint](surf.pixels) + uint(y * surf.pitch.int))
    for x in 0 ..< surf.w.int:
      let p = row[x]
      if (p shr 24) != 0 and (p and 0xFFFFFF'u32) != 0xFFFFFF'u32: return true
  false

proc tint(g: Glyph, c: Rgb) =
  ## Apply the text colour, except to colour glyphs, which keep their own.
  if g.color: discard setTextureColorMod(g.tex, 255, 255, 255)
  else: discard setTextureColorMod(g.tex, c.r, c.g, c.b)

proc glyph(rd: Renderer, text: string, face: Face): Glyph =
  let font = rd.fontFor(face, text)
  let key = (text, cast[int](font))
  if key in rd.glyphs: return rd.glyphs[key]
  # Render white; the per-cell colour is applied with a colour mod.
  let surf = renderUTF8Blended(font, text.cstring, Color(r: 255, g: 255, b: 255, a: 255))
  if surf != nil:
    result.tex = createTextureFromSurface(rd.r, surf)
    result.w = surf.w
    result.h = surf.h
    result.color = isColorSurface(surf)
    freeSurface(surf)
    if result.tex != nil: discard setTextureBlendMode(result.tex, BLENDMODE_BLEND)
    # Bitmap fonts such as Noto Color Emoji only come in fixed strike sizes
    # (~128px) and ignore the requested point size, so shrink anything much
    # taller than a cell to fit a two-cell slot, keeping its aspect ratio.
    if result.w > 0 and result.h > rd.cellH * 3 div 2:
      let k = min(rd.cellH / result.h.int, 2 * rd.cellW / result.w.int)
      result.w = cint(max(1, int(result.w.float * k + 0.5)))
      result.h = cint(max(1, int(result.h.float * k + 0.5)))
      if result.tex != nil: discard setTextureScaleMode(result.tex, SCALEMODE_LINEAR)
  rd.glyphs[key] = result

# --- drawing helpers -------------------------------------------------------

proc setColor*(rd: Renderer, c: Rgb, a = 255'u8) =
  discard setRenderDrawColor(rd.r, c.r, c.g, c.b, a)

proc fillRect*(rd: Renderer, x, y, w, h: int) =
  var rect = Rect(x: cint(x), y: cint(y), w: cint(w), h: cint(h))
  discard renderFillRect(rd.r, addr rect)

proc textWidth*(rd: Renderer, text: string): int =
  ## Width in output pixels of `text` drawn in the regular face.
  if text.len == 0: 0 else: rd.glyph(text, faceRegular).w.int

proc drawText*(rd: Renderer, text: string, x, y: int, color: Rgb) =
  ## Draw a UI string (not terminal cells) with its top-left at (x, y).
  if text.len == 0: return
  let g = rd.glyph(text, faceRegular)
  if g.tex == nil: return
  var dst = Rect(x: cint(x), y: cint(y), w: g.w, h: g.h)
  g.tint(color)
  discard setTextureAlphaMod(g.tex, 255)
  discard renderCopy(rd.r, g.tex, nil, addr dst)

proc cellX(rd: Renderer, col: int): int = rd.pad + col * rd.cellW
proc cellY(rd: Renderer, row: int): int = rd.top + rd.pad + row * rd.cellH

proc drawGlyph(rd: Renderer, cell: CellInfo, col, row: int, fg: Rgb) =
  if cell.text.len == 0 or cell.invisible or cell.text == " ": return
  let cp = firstCodepoint(cell.text)
  if cell.text.len == 3 and isSpecial(cp):
    drawSpecial(rd.r, cp, rd.cellX(col), rd.cellY(row), rd.cellW, rd.cellH,
                (fg.r, fg.g, fg.b), if cell.faint: 128'u8 else: 255'u8)
    return
  let g = rd.glyph(cell.text, cell.face)
  if g.tex == nil: return
  let span = (if cell.wide: 2 else: 1) * rd.cellW
  # Centre glyphs that are narrower than their cells (e.g. CJK in a
  # 2-cell slot); left-align otherwise so ligature-free text stays aligned.
  let dx = if g.w < span and cell.wide: (span - g.w) div 2 else: 0
  var dst = Rect(x: cint(rd.cellX(col) + dx), y: cint(rd.cellY(row)), w: g.w, h: g.h)
  g.tint(fg)
  discard setTextureAlphaMod(g.tex, if cell.faint: 128'u8 else: 255'u8)
  discard renderCopy(rd.r, g.tex, nil, addr dst)

proc runnable(rd: Renderer, cell: CellInfo): bool =
  ## Whether `cell` can join a shaped run: one character in the cell's own
  ## (non-synthesized) face, not wide, not drawn by boxdraw or a fallback font.
  if cell.text.len == 0 or cell.invisible or cell.wide or
     rd.shapePaths[cell.face].len == 0 or cell.text.runeLen != 1: return false
  if cell.text.len == 3 and isSpecial(firstCodepoint(cell.text)): return false
  rd.fontFor(cell.face, cell.text) == rd.fonts[cell.face]

proc drawRun(rd: Renderer, cells: openArray[CellInfo], first, last, row: int,
             fg: Rgb): bool =
  ## Draw cells first ..< last as one shaped string, if shaping changes them.
  ## False (nothing drawn) if they should be drawn cell by cell instead.
  var text = ""
  for i in first ..< last: text.add cells[i].text
  if text.strip(leading = true, trailing = true, chars = {' '}).len == 0: return false
  let face = cells[first].face
  if rd.shaper.runKind(rd.shapePaths[face], text) != runShaped: return false
  let key = (text, ord(face))
  var g = rd.runs.getOrDefault(key)
  if g.tex == nil:
    if rd.runs.len >= 1024:
      for old in rd.runs.values: destroyTexture(old.tex)
      rd.runs.clear()
    let surf = renderUTF8Blended(rd.fonts[face], text.cstring,
                                 Color(r: 255, g: 255, b: 255, a: 255))
    if surf == nil: return false
    g = Glyph(tex: createTextureFromSurface(rd.r, surf), w: surf.w, h: surf.h,
              color: isColorSurface(surf))
    freeSurface(surf)
    if g.tex == nil: return false
    discard setTextureBlendMode(g.tex, BLENDMODE_BLEND)
    rd.runs[key] = g
  var dst = Rect(x: cint(rd.cellX(first)), y: cint(rd.cellY(row)), w: g.w, h: g.h)
  g.tint(fg)
  discard setTextureAlphaMod(g.tex, if cells[first].faint: 128'u8 else: 255'u8)
  discard renderCopy(rd.r, g.tex, nil, addr dst)
  true

proc drawDecorations(rd: Renderer, cell: CellInfo, col, row: int, fg: Rgb) =
  let x = rd.cellX(col)
  let y = rd.cellY(row)
  let w = (if cell.wide: 2 else: 1) * rd.cellW
  let thick = max(1, rd.cellH div 16)
  rd.setColor(fg)
  if cell.underline != GHOSTTY_SGR_UNDERLINE_NONE:
    let uy = y + min(rd.cellH - thick, rd.ascent + 2 * thick)
    rd.fillRect(x, uy, w, thick)
    if cell.underline == GHOSTTY_SGR_UNDERLINE_DOUBLE:
      rd.fillRect(x, max(y, uy - 2 * thick), w, thick)
  if cell.strike:
    rd.fillRect(x, y + rd.ascent * 2 div 3, w, thick)
  if cell.overline:
    rd.fillRect(x, y, w, thick)

proc resolvedColors(rd: Renderer, cell: CellInfo, selected: bool): (Rgb, Rgb, bool) =
  ## Returns (fg, bg, drawBg) after applying inverse video and selection.
  var fg = cell.fg
  var bg = if cell.hasBg: cell.bg else: rgb(rd.colors.background)
  var drawBg = cell.hasBg
  if selected:
    (fg, bg) = (rd.selectionFg.get(bg), rd.selectionBg.get(fg))
    drawBg = true
  (fg, bg, drawBg)

# --- frame -----------------------------------------------------------------

proc readRow(rd: Renderer, row: int): tuple[selStart, selEnd: int] =
  ## Pull the current row's cells out of the render state into `rd.cells`.
  result = (-1, -1)
  var sel = initSized(GhosttyRenderStateRowSelection)
  if ghostty_render_state_row_get(rd.rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
                                  addr sel) == GHOSTTY_SUCCESS:
    result = (sel.start_x.int, sel.end_x.int)
  discard ghostty_render_state_row_get(rd.rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                       addr rd.rowCells)
  var utf8: array[128, uint8]
  var col = 0
  while ghostty_render_state_row_cells_next(rd.rowCells):
    if col >= rd.cells[row].len: break
    var c = CellInfo(fg: rgb(rd.colors.foreground))

    var raw: GhosttyCell
    if ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_RAW,
                                          addr raw) == GHOSTTY_SUCCESS:
      var wide: cint
      if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, addr wide) == GHOSTTY_SUCCESS:
        c.wide = wide == GHOSTTY_CELL_WIDE_WIDE

    var glen: uint32
    discard ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_GRAPHEMES_LEN,
                                               addr glen)
    if glen > 0:
      var buf = GhosttyBuffer(`ptr`: cast[ptr UncheckedArray[uint8]](addr utf8[0]),
                              cap: csize_t(utf8.len))
      if ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_GRAPHEMES_UTF8,
                                            addr buf) == GHOSTTY_SUCCESS:
        c.text = newString(buf.len.int)
        if buf.len > 0: copyMem(addr c.text[0], addr utf8[0], buf.len.int)

    var style = initSized(GhosttyStyle)
    discard ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_STYLE,
                                               addr style)
    var color: GhosttyColorRgb
    if ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_FG_COLOR,
                                          addr color) == GHOSTTY_SUCCESS:
      c.fg = rgb(color)
    if ghostty_render_state_row_cells_get(rd.rowCells, GHOSTTY_CELLS_DATA_BG_COLOR,
                                          addr color) == GHOSTTY_SUCCESS:
      c.bg = rgb(color)
      c.hasBg = true
    if style.inverse:
      let bg = if c.hasBg: c.bg else: rgb(rd.colors.background)
      c.bg = c.fg
      c.fg = bg
      c.hasBg = true
    c.face = if style.bold and style.italic: faceBoldItalic
             elif style.bold: faceBold
             elif style.italic: faceItalic
             else: faceRegular
    c.faint = style.faint
    c.invisible = style.invisible
    c.strike = style.strikethrough
    c.overline = style.overline
    c.underline = style.underline
    rd.cells[row][col] = c
    inc col
  for x in col ..< rd.cells[row].len:
    rd.cells[row][x] = CellInfo(fg: rgb(rd.colors.foreground))

proc drawRow(rd: Renderer, row: int, sel: tuple[selStart, selEnd: int]) =
  let y = rd.cellY(row)
  # Clear the whole strip (including side padding) to the default background.
  rd.setColor(rgb(rd.colors.background))
  rd.fillRect(0, y, rd.gridW, rd.cellH)
  let cells = rd.cells[row]
  template isSel(x: int): bool = sel.selStart >= 0 and x >= sel.selStart and x <= sel.selEnd
  # Pass 1: backgrounds, so wide/overhanging glyphs aren't painted over.
  for x, c in cells:
    let (_, bg, drawBg) = rd.resolvedColors(c, isSel(x))
    if drawBg:
      rd.setColor(bg)
      rd.fillRect(rd.cellX(x), y, rd.cellW, rd.cellH)
  # Pass 2: glyphs and decorations. Neighbouring cells that share a face and
  # colour form a run, which is drawn shaped if that changes how it looks.
  var x = 0
  while x < cells.len:
    let c = cells[x]
    let (fg, _, _) = rd.resolvedColors(c, isSel(x))
    var last = x + 1
    if rd.shaping and rd.runnable(c):
      while last < cells.len and cells[last].face == c.face and
            cells[last].faint == c.faint and rd.runnable(cells[last]) and
            rd.resolvedColors(cells[last], isSel(last))[0] == fg:
        inc last
    if last - x < 2 or not rd.drawRun(cells, x, last, row, fg):
      for i in x ..< last: rd.drawGlyph(cells[i], i, row, fg)
    for i in x ..< last: rd.drawDecorations(cells[i], i, row, fg)
    x = last

proc drawCursor(rd: Renderer, cursor: GhosttyRenderStateCursor) =
  let col = cursor.viewport_x.int
  let row = cursor.viewport_y.int
  if row >= rd.cells.len or col >= rd.cells[row].len: return
  let cell = rd.cells[row][col]
  let color = rgb(if rd.colors.cursor_has_value: rd.colors.cursor else: rd.colors.foreground)
  let x = rd.cellX(col)
  let y = rd.cellY(row)
  let w = (if cell.wide: 2 else: 1) * rd.cellW
  let thick = max(1, int(2 * rd.scale))
  var style = cursor.visual_style
  if not rd.focused: style = GHOSTTY_CURSOR_BLOCK_HOLLOW
  rd.setColor(color)
  case style
  of GHOSTTY_CURSOR_BAR:
    rd.fillRect(x, y, thick, rd.cellH)
  of GHOSTTY_CURSOR_UNDERLINE:
    rd.fillRect(x, y + rd.cellH - thick, w, thick)
  of GHOSTTY_CURSOR_BLOCK_HOLLOW:
    var rect = Rect(x: cint(x), y: cint(y), w: cint(w), h: cint(rd.cellH))
    discard renderDrawRect(rd.r, addr rect)
  else:
    rd.fillRect(x, y, w, rd.cellH)
    # Re-draw the character under the cursor in the background colour.
    let bg = if cell.hasBg: cell.bg else: rgb(rd.colors.background)
    rd.drawGlyph(cell, col, row, bg)

proc draw*(rd: Renderer, state: GhosttyRenderState, term: GhosttyTerminal,
           force: bool, blinkOn: bool) =
  ## Update `state` from `term` and draw a frame into the backbuffer (call
  ## `renderPresent` afterwards).
  check ghostty_render_state_update(state, term), "ghostty_render_state_update"
  var dirty: cint
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, addr dirty)
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, addr rd.colors)
  var cols, rows: uint16
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, addr cols)
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, addr rows)

  var full = force or dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
  if rd.cells.len != rows.int or (rows > 0 and rd.cells[0].len != cols.int):
    rd.cells = newSeq[seq[CellInfo]](rows.int)
    for r in rd.cells.mitems: r = newSeq[CellInfo](cols.int)
    full = true

  if full or dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE:
    discard setRenderTarget(rd.r, rd.grid)
    if full:
      rd.setColor(rgb(rd.colors.background))
      discard renderClear(rd.r)
    discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                                     addr rd.rowIter)
    var row = 0
    while ghostty_render_state_row_iterator_next(rd.rowIter) and row < rd.cells.len:
      var rowDirty = false
      discard ghostty_render_state_row_get(rd.rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                                           addr rowDirty)
      if full or rowDirty:
        let sel = rd.readRow(row)
        rd.drawRow(row, sel)
      inc row
    discard ghostty_render_state_clean(state)
    discard setRenderTarget(rd.r, nil)

  rd.setColor(rgb(rd.colors.background))
  discard renderClear(rd.r)
  discard renderCopy(rd.r, rd.grid, nil, nil)

  var cursor = initSized(GhosttyRenderStateCursor)
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, addr cursor)
  if cursor.visible and cursor.viewport_has_value and (blinkOn or not cursor.blinking):
    rd.drawCursor(cursor)

proc cursorBlinking*(rd: Renderer, state: GhosttyRenderState): bool =
  var cursor = initSized(GhosttyRenderStateCursor)
  discard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, addr cursor)
  cursor.visible and cursor.blinking

# --- tab bar ---------------------------------------------------------------

proc mix(a, b: Rgb, t: float): Rgb =
  template m(x, y: uint8): uint8 = uint8(float(x) + (float(y) - float(x)) * t + 0.5)
  Rgb(r: m(a.r, b.r), g: m(a.g, b.g), b: m(a.b, b.b))

proc tabWidth(rd: Renderer, n: int): int =
  ## Tabs share the bar right of the "+" button, up to a comfortable maximum.
  max(1, min(32 * rd.cellW, (rd.gridW - rd.tabH) div max(1, n)))

proc closeWidth(rd: Renderer, tabW: int): int = min(3 * rd.cellW, tabW div 3)

proc hitTabBar*(rd: Renderer, n, x, y: int): TabHit =
  ## What lies under output pixel (x, y) in a bar showing `n` tabs.
  if y < 0 or y >= rd.tabH or x < 0: return  # (the folder strip is separate)
  if x < rd.tabH: return TabHit(kind: hitNew)
  let tabW = rd.tabWidth(n)
  let tx = x - rd.tabH
  let i = tx div tabW
  if i < n:
    let kind = if tx >= (i + 1) * tabW - rd.closeWidth(tabW): hitClose else: hitTab
    return TabHit(kind: kind, index: i)

proc drawCellText(rd: Renderer, text: string, x, y: int, fg: Rgb, face = faceRegular) =
  ## Draw one line of text on the cell grid (one cell per codepoint).
  var cx = x
  for r in text.runes:
    let g = rd.glyph($r, face)
    if g.tex != nil:
      var dst = Rect(x: cint(cx), y: cint(y), w: g.w, h: g.h)
      g.tint(fg)
      discard setTextureAlphaMod(g.tex, 255)
      discard renderCopy(rd.r, g.tex, nil, addr dst)
    cx += rd.cellW

proc blendSpans(rd: Renderer, x0, y0, x1, y1: int, c: Rgb,
                coverage: proc (px, py: float): float) =
  ## Fill pixels in [x0, x1) x [y0, y1) with `c` at the alpha `coverage`
  ## gives for each pixel centre, merging equal runs into one rect.
  discard setRenderDrawBlendMode(rd.r, BLENDMODE_BLEND)
  for y in y0 ..< y1:
    var runX = x0
    var runA = -1
    for x in x0 .. x1:
      let a = if x < x1: int(clamp(coverage(x.float + 0.5, y.float + 0.5), 0.0, 1.0) * 255 + 0.5)
              else: -1
      if a != runA:
        if runA > 0:
          rd.setColor(c, uint8(runA))
          rd.fillRect(runX, y, x - runX, 1)
        runX = x
        runA = a
  discard setRenderDrawBlendMode(rd.r, BLENDMODE_NONE)

proc fillTopRounded(rd: Renderer, x, y, w, h, r: int, c: Rgb) =
  ## A rectangle whose top corners are antialiased quarter circles.
  let r = min(r, min(w div 2, h))
  rd.setColor(c)
  rd.fillRect(x + r, y, w - 2 * r, r)
  rd.fillRect(x, y + r, w, h - r)
  proc corner(x0: int, cx: float) =
    let (rf, cy) = (r.float, float(y + r))
    rd.blendSpans(x0, y, x0 + r, y + r, c, proc (px, py: float): float =
      rf + 0.5 - hypot(px - cx, py - cy))
  corner(x, float(x + r))
  corner(x + w - r, float(x + w - r))

proc strokeSegments(rd: Renderer, segs: openArray[(float, float, float, float)],
                    width: float, c: Rgb) =
  ## Antialiased strokes with round caps between the given end points.
  var x0 = high(int)
  var y0 = high(int)
  var x1 = low(int)
  var y1 = low(int)
  for (ax, ay, bx, by) in segs:
    x0 = min(x0, int(floor(min(ax, bx) - width)))
    y0 = min(y0, int(floor(min(ay, by) - width)))
    x1 = max(x1, int(ceil(max(ax, bx) + width)))
    y1 = max(y1, int(ceil(max(ay, by) + width)))
  let segs = @segs
  let half = width / 2
  rd.blendSpans(x0, y0, x1, y1, c, proc (px, py: float): float =
    var d = Inf
    for (ax, ay, bx, by) in segs:
      let (dx, dy) = (bx - ax, by - ay)
      let t = clamp(((px - ax) * dx + (py - ay) * dy) / max(1e-9, dx * dx + dy * dy), 0.0, 1.0)
      d = min(d, hypot(px - ax - t * dx, py - ay - t * dy))
    half + 0.5 - d)

proc drawCloseIcon(rd: Renderer, cx, cy: float, size: float, c: Rgb) =
  let k = size / 2
  rd.strokeSegments([(cx - k, cy - k, cx + k, cy + k), (cx - k, cy + k, cx + k, cy - k)],
                    max(1.2, 1.4 * rd.scale), c)

proc drawPlusIcon(rd: Renderer, cx, cy: float, size: float, c: Rgb) =
  let k = size / 2
  rd.strokeSegments([(cx - k, cy, cx + k, cy), (cx, cy - k, cx, cy + k)],
                    max(1.2, 1.6 * rd.scale), c)

proc drawTabBar*(rd: Renderer, titles: openArray[string], active: int) =
  ## Draw the tab bar across the top of the window. Call after `draw`, which
  ## refreshes the colours from the active terminal.
  let bg = rgb(rd.colors.background)
  let fg = rgb(rd.colors.foreground)
  let barBg = mix(bg, fg, 0.08)
  let n = titles.len
  let tabW = rd.tabWidth(n)
  let closeW = rd.closeWidth(tabW)
  let line = max(1, int(rd.scale))
  let inset = max(2, rd.tabH div 6)            # gap above a tab and between tabs
  let radius = max(3, rd.tabH div 3)
  let textY = inset + (rd.tabH - inset - rd.cellH) div 2
  let iconSize = max(6.0, rd.cellH.float * 0.36)
  rd.setColor(barBg)
  rd.fillRect(0, 0, rd.gridW, rd.tabH)
  # The border under the bar, broken where the active tab joins the terminal.
  rd.setColor(mix(bg, fg, 0.2))
  let activeX = rd.tabH + active * tabW
  rd.fillRect(0, rd.tabH - line, activeX, line)
  rd.fillRect(activeX + tabW, rd.tabH - line, rd.gridW - activeX - tabW, line)
  if n > 0 and active != 0:
    # Divider between the "+" button and the first tab.
    rd.setColor(mix(bg, fg, 0.25))
    rd.fillRect(rd.tabH - line, inset + (rd.tabH - inset) div 4, line, (rd.tabH - inset) div 2)
  for i, title in titles:
    let x = rd.tabH + i * tabW
    let isActive = i == active
    if isActive:
      # Rounded tab, outlined in the border colour, flowing into the terminal.
      rd.fillTopRounded(x + inset div 2, inset, tabW - inset, rd.tabH - inset,
                        radius, mix(bg, fg, 0.2))
      rd.fillTopRounded(x + inset div 2 + line, inset + line, tabW - inset - 2 * line,
                        rd.tabH - inset - line, radius - line, bg)
    elif i + 1 != active:
      rd.setColor(mix(bg, fg, 0.25))
      rd.fillRect(x + tabW - line, inset + (rd.tabH - inset) div 4, line, (rd.tabH - inset) div 2)
    let textFg = if isActive: fg else: mix(bg, fg, 0.6)
    # Title, cut to the space left of the close button.
    let maxChars = (tabW - closeW - rd.cellW - inset) div rd.cellW
    var label = if title.len > 0: title else: "shell"
    if label.runeLen > maxChars:
      label = if maxChars > 1: label.runeSubStr(0, maxChars - 1) & "…" else: ""
    rd.drawCellText(label, x + inset div 2 + rd.cellW, textY, textFg,
                    if isActive: faceBold else: faceRegular)
    rd.drawCloseIcon(float(x + tabW - inset div 2) - closeW.float / 2,
                     textY.float + rd.cellH.float / 2, iconSize, textFg)
  rd.drawPlusIcon(rd.tabH.float / 2,
                  textY.float + rd.cellH.float / 2, iconSize * 1.2, mix(bg, fg, 0.6))

# --- recent-folders strip ----------------------------------------------------

proc fillRounded(rd: Renderer, x, y, w, h, r: int, c: Rgb) =
  ## A rectangle with all four corners antialiased quarter circles.
  let r = min(r, min(w div 2, h div 2))
  rd.setColor(c)
  rd.fillRect(x + r, y, w - 2 * r, h)
  rd.fillRect(x, y + r, r, h - 2 * r)
  rd.fillRect(x + w - r, y + r, r, h - 2 * r)
  proc corner(x0, y0: int, cx, cy: float) =
    let rf = r.float
    rd.blendSpans(x0, y0, x0 + r, y0 + r, c, proc (px, py: float): float =
      rf + 0.5 - hypot(px - cx, py - cy))
  let (l, t) = (float(x + r), float(y + r))
  let (rr, b) = (float(x + w - r), float(y + h - r))
  corner(x, y, l, t)
  corner(x + w - r, y, rr, t)
  corner(x, y + h - r, l, b)
  corner(x + w - r, y + h - r, rr, b)

proc folderChips(rd: Renderer, labels: openArray[string]): seq[tuple[x, w: int]] =
  ## Where each folder chip goes, left to right; only the ones that fit.
  let padX = rd.cellW
  let gap = max(2, rd.cellW div 2)
  var x = rd.pad + rd.cellW div 2
  for label in labels:
    let w = label.runeLen * rd.cellW + 2 * padX
    if x + w > rd.gridW - rd.pad: break
    result.add (x, w)
    x += w + gap

proc chipBox(rd: Renderer): tuple[y, h: int] =
  let inset = max(2, int(4 * rd.scale))
  (rd.tabH + inset, rd.folderH - 2 * inset)

proc hitFolderBar*(rd: Renderer, labels: openArray[string], x, y: int): int =
  ## The index of the folder chip under output pixel (x, y), or -1.
  if not rd.folderBar: return -1
  let (cy, ch) = rd.chipBox()
  if y < cy or y >= cy + ch: return -1
  for i, c in rd.folderChips(labels):
    if x >= c.x and x < c.x + c.w: return i
  -1

proc drawFolderBar*(rd: Renderer, labels: openArray[string], hovered: int) =
  ## Draw the recent folders as chips under the tab bar, on the terminal's
  ## background so the active tab flows through them into the terminal.
  if not rd.folderBar: return
  let bg = rgb(rd.colors.background)
  let fg = rgb(rd.colors.foreground)
  rd.setColor(bg)
  rd.fillRect(0, rd.tabH, rd.gridW, rd.folderH)
  let (cy, ch) = rd.chipBox()
  let textY = cy + (ch - rd.cellH) div 2
  for i, c in rd.folderChips(labels):
    let isHovered = i == hovered
    rd.fillRounded(c.x, cy, c.w, ch, ch div 2,
                   mix(bg, fg, if isHovered: 0.16 else: 0.06))
    rd.drawCellText(labels[i], c.x + rd.cellW, textY,
                    if isHovered: fg else: mix(bg, fg, 0.6))
