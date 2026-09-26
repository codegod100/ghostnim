## The file manager pane: a folder listing split off the left of the window,
## next to the terminal. It follows the current tab's working directory.
##
## Like the menu, it's drawn by ghostnim itself each frame, in the space the
## renderer leaves free left of the grid (`Renderer.left`). All coordinates
## are in output (HiDPI) pixels.

import std/[os, algorithm, strutils, times]
from std/unicode import Rune, `$`, runeLen, runeSubStr
import sdl, renderer

const maxEntries = 5000     ## enough for any folder worth browsing

type
  Entry* = object
    name*: string
    isDir*: bool

  FilePane* = object
    dir*: string              ## the folder listed
    entries*: seq[Entry]      ## ".." (except at /), then folders, then files
    stamp: Time               ## the folder's mtime when it was listed
    scroll*: int              ## first entry shown
    hovered*, selected*: int  ## entry indexes, -1 for none
    showHidden*: bool         ## list dotfiles too

proc initFilePane*(): FilePane = FilePane(hovered: -1, selected: -1)

# --- listing -----------------------------------------------------------------

proc mtime(dir: string): Time =
  try: getLastModificationTime(dir) except OSError: Time()

proc isHidden*(e: Entry): bool = e.name.startsWith(".") and e.name != ".."

proc list(dir: string, hidden: bool): seq[Entry] =
  ## The folder's entries, dotfiles only if `hidden`: folders first, each
  ## group by name.
  var dirs, files: seq[Entry]
  try:
    for kind, name in walkDir(dir, relative = true):
      if name.startsWith(".") and not hidden: continue
      if kind in {pcDir, pcLinkToDir}: dirs.add Entry(name: name, isDir: true)
      else: files.add Entry(name: name)
      if dirs.len + files.len >= maxEntries: break
  except OSError:
    discard
  proc byName(a, b: Entry): int = cmpIgnoreCase(a.name, b.name)
  dirs.sort(byName)
  files.sort(byName)
  if dir != "/": result.add Entry(name: "..", isDir: true)
  result.add dirs
  result.add files

proc path*(p: FilePane, i: int): string =
  ## The full path of entry `i`.
  if p.entries[i].name == "..": p.dir.parentDir else: p.dir / p.entries[i].name

proc load*(p: var FilePane, dir: string) =
  ## List `dir`, from the top unless it's the folder already shown.
  if dir != p.dir:
    p.scroll = 0
    p.selected = -1
    p.hovered = -1
  p.dir = dir
  p.stamp = mtime(dir)
  p.entries = list(dir, p.showHidden)
  p.scroll = min(p.scroll, max(0, p.entries.len - 1))
  if p.selected >= p.entries.len: p.selected = -1

proc reload(p: var FilePane) =
  ## List the folder again, keeping the selection on the same name.
  let selName = if p.selected >= 0: p.entries[p.selected].name else: ""
  p.load(p.dir)
  p.selected = -1
  for i, e in p.entries:
    if e.name == selName: p.selected = i

proc refresh*(p: var FilePane) =
  ## List the folder again if something was added, removed or renamed in it.
  if p.dir.len == 0: return
  if not dirExists(p.dir):
    var up = p.dir
    while up.len > 1 and not dirExists(up): up = up.parentDir
    p.load(up)
  elif mtime(p.dir) != p.stamp:
    p.reload()

proc setShowHidden*(p: var FilePane, on: bool) =
  ## List dotfiles or not, keeping the selected entry if it's still there.
  if on == p.showHidden: return
  p.showHidden = on
  if p.dir.len > 0: p.reload()

# --- geometry ------------------------------------------------------------------

proc padX(rd: Renderer): int = rd.cellW
proc padY(rd: Renderer): int = int(3 * rd.scale)
proc rowH(rd: Renderer): int = rd.cellH + 2 * rd.padY
proc headerH(rd: Renderer): int = rd.rowH + int(4 * rd.scale)
proc listY(rd: Renderer): int = rd.top + rd.headerH
proc line(rd: Renderer): int = max(1, int(rd.scale))

proc visibleRows*(rd: Renderer, outH: int): int =
  max(0, (outH - rd.listY) div rd.rowH)

proc contains*(rd: Renderer, x, y: int): bool =
  ## Whether output pixel (x, y) is in the pane.
  rd.left > 0 and y >= rd.top and x >= 0 and x < rd.left

proc onDivider*(rd: Renderer, x, y: int): bool =
  ## Whether (x, y) is on the line between the pane and the terminal, where
  ## a drag resizes the pane.
  rd.left > 0 and y >= rd.top and abs(x - rd.left) <= max(3, int(4 * rd.scale))

proc entryAt*(p: FilePane, rd: Renderer, x, y, outH: int): int =
  ## The index of the entry under (x, y), or -1.
  if not rd.contains(x, y) or y < rd.listY: return -1
  let row = (y - rd.listY) div rd.rowH
  if row >= rd.visibleRows(outH): return -1
  let i = p.scroll + row
  if i < p.entries.len: i else: -1

proc scrollBy*(p: var FilePane, rd: Renderer, delta, outH: int) =
  p.scroll = clamp(p.scroll + delta, 0, max(0, p.entries.len - rd.visibleRows(outH)))

# --- keyboard --------------------------------------------------------------------

proc select*(p: var FilePane, i, rows: int) =
  ## Select entry `i` (clamped), scrolling it into view in a pane showing
  ## `rows` entries.
  if p.entries.len == 0:
    p.selected = -1
    return
  p.selected = clamp(i, 0, p.entries.len - 1)
  let rows = max(1, rows)
  if p.selected < p.scroll: p.scroll = p.selected
  elif p.selected >= p.scroll + rows: p.scroll = p.selected - rows + 1

proc selectName*(p: var FilePane, name: string, rows: int) =
  ## Select the entry called `name`, else the first one after "..".
  for i, e in p.entries:
    if e.name == name:
      p.select(i, rows)
      return
  p.select(if p.entries.len > 1 and p.entries[0].name == "..": 1 else: 0, rows)

proc jumpTo*(p: var FilePane, prefix: string, rows: int) =
  ## Type-ahead: select the next entry whose name starts with `prefix`. A
  ## one-letter prefix moves on from the selected entry, so repeating it
  ## cycles through the matches; a longer one may stay on it.
  let n = p.entries.len
  if n == 0 or prefix.len == 0: return
  let start = if prefix.len == 1: p.selected + 1 else: max(0, p.selected)
  for k in 0 ..< n:
    let i = (start + k) mod n
    if p.entries[i].name.toLowerAscii.startsWith(prefix.toLowerAscii):
      p.select(i, rows)
      return

# --- drawing -------------------------------------------------------------------

proc mix(a, b: Rgb, t: float): Rgb =
  template ch(x, y: uint8): uint8 = uint8(float(x) + (float(y) - float(x)) * t + 0.5)
  Rgb(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b))

proc fit(text: string, chars: int, fromLeft = false): string =
  ## `text` cut to `chars` cells with an ellipsis, keeping its end if
  ## `fromLeft` (for paths).
  let n = text.runeLen
  if n <= chars: text
  elif chars <= 1: ""
  elif fromLeft: "…" & text.runeSubStr(n - chars + 1)
  else: text.runeSubStr(0, chars - 1) & "…"

proc displayPath(dir: string): string =
  let home = getHomeDir().strip(leading = false, chars = {'/'})
  if dir == home: "~"
  elif dir.startsWith(home & "/"): "~" & dir[home.len .. ^1]
  else: dir

proc drawFolderIcon(rd: Renderer, x, y, w, h: int, c: Rgb) =
  rd.setColor(c)
  rd.fillRect(x, y, w * 2 div 5, max(1, h div 5))       # the tab
  rd.fillRect(x, y + h div 6, w, h - h div 6)           # the body

proc drawFileIcon(rd: Renderer, x, y, w, h: int, c: Rgb) =
  ## A page with a folded top-right corner and a couple of text lines, so it
  ## doesn't read as the empty box of a missing glyph.
  let l = rd.line
  let w = w * 3 div 4
  let f = max(2 * l, w * 2 div 5)                  # size of the folded corner
  rd.setColor(c)
  rd.fillRect(x, y, w - f, l)                      # top, up to the fold
  rd.fillRect(x, y + h - l, w, l)                  # bottom
  rd.fillRect(x, y, l, h)                          # left
  rd.fillRect(x + w - l, y + f, l, h - f)          # right, below the fold
  for i in 0 .. f - l:                             # the fold's diagonal
    rd.fillRect(x + w - f + i, y + i, l, l)
  rd.fillRect(x + w - f, y, l, f)                  # the fold's flap
  rd.fillRect(x + w - f, y + f - l, f, l)
  if h >= 8 * l:                                   # text lines, when there's room
    let tx = x + 2 * l
    let tw = w - 4 * l
    rd.fillRect(tx, y + h div 2, tw, l)
    rd.fillRect(tx, y + h div 2 + 2 * l, tw * 2 div 3, l)

# Nerd Font icons by file name or extension (lowercase), with the palette
# entry to colour them: 1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan;
# -1 is the foreground. The AppImage bundles Symbols Nerd Font; without one,
# files get the drawn page icon.
const nameIcons = [
  ("makefile gnumakefile", 0xE673, 1),
  ("dockerfile containerfile", 0xE650, 4),
  ("license licence copying license.md license.txt", 0xE60A, 3),
  (".gitignore .gitattributes .gitmodules", 0xE702, 1),
  (".bashrc .bash_profile .zshrc .zprofile .profile", 0xE691, 2)]

const extIcons = [
  ("nim nims nimble", 0xE677, 3),
  ("py pyi", 0xE606, 4),
  ("js mjs cjs", 0xE60C, 3),
  ("ts mts cts", 0xE628, 4),
  ("jsx tsx", 0xE625, 6),
  ("rs", 0xE68B, 1),
  ("go", 0xE627, 6),
  ("c h", 0xE649, 4),
  ("cpp cc cxx hpp hh hxx", 0xE646, 4),
  ("zig", 0xE6A9, 3),
  ("lua", 0xE620, 4),
  ("rb", 0xE605, 1),
  ("java", 0xE66D, 1),
  ("kt kts", 0xE634, 5),
  ("swift", 0xE699, 1),
  ("php", 0xE608, 5),
  ("hs", 0xE61F, 5),
  ("ex exs", 0xE62D, 5),
  ("ml mli", 0xE67A, 3),
  ("jl", 0xE624, 5),
  ("clj cljs edn", 0xE642, 2),
  ("scala", 0xE68E, 1),
  ("dart", 0xE64C, 4),
  ("vim", 0xE62B, 2),
  ("nix", 0xF1105, 4),
  ("sh bash zsh fish", 0xE691, 2),
  ("html htm", 0xE60E, 1),
  ("css", 0xE614, 4),
  ("scss sass", 0xE603, 5),
  ("svelte", 0xE697, 1),
  ("vue", 0xE6A0, 2),
  ("json jsonc", 0xE60B, 3),
  ("toml", 0xE6B2, 6),
  ("yml yaml", 0xE6A8, 5),
  ("xml", 0xE619, 3),
  ("ini conf cfg kdl", 0xE615, 6),
  ("md markdown", 0xE609, 4),
  ("tex", 0xE69B, 2),
  ("csv tsv", 0xE64A, 2),
  ("sql db sqlite sqlite3", 0xE64D, 3),
  ("lock", 0xE672, -1),
  ("txt log", 0xE64E, -1),
  ("pdf", 0xE67D, 1),
  ("doc docx odt", 0xF022C, 4),
  ("xls xlsx ods", 0xF021B, 2),
  ("ppt pptx odp", 0xF0227, 1),
  ("png jpg jpeg gif bmp webp ico tiff", 0xE60D, 5),
  ("svg", 0xE698, 3),
  ("mp3 flac wav ogg opus m4a", 0xE638, 6),
  ("mp4 mkv webm mov avi", 0xE69F, 5),
  ("ttf otf woff woff2", 0xE659, 1),
  ("zip tar gz tgz xz bz2 zst 7z rar", 0xE6AA, 3)]

proc fileIcon(name: string): tuple[glyph: string, color: int] =
  ## The icon for a file called `name`, or "" if it has none.
  let name = name.toLowerAscii
  for (keys, cp, color) in nameIcons:
    if name in keys.split(' '): return ($Rune(cp), color)
  let dot = name.rfind('.')
  if dot > 0:                                      # not a bare dotfile
    let ext = name[dot + 1 .. ^1]
    for (keys, cp, color) in extIcons:
      if ext in keys.split(' '): return ($Rune(cp), color)
  ("", -1)

proc draw*(p: FilePane, rd: Renderer, outH: int, focused: bool) =
  ## Composite the pane onto the backbuffer, in the terminal's colours. With
  ## keyboard focus, the selected entry is highlighted in the accent colour.
  if rd.left <= 0: return
  let bg = rgb(rd.colors.background)
  let fg = rgb(rd.colors.foreground)
  let accent = rgb(rd.colors.palette[4])      # the terminal's blue
  let l = rd.line
  var clip = Rect(x: 0, y: cint(rd.top), w: cint(rd.left), h: cint(outH - rd.top))
  discard renderSetClipRect(rd.r, addr clip)
  rd.setColor(mix(bg, fg, 0.04))
  rd.fillRect(0, rd.top, rd.left, outH - rd.top)
  let chars = (rd.left - 2 * rd.padX) div rd.cellW

  # Header: the folder, and a line under it.
  rd.drawText(fit(displayPath(p.dir), chars, fromLeft = true), rd.padX,
              rd.top + (rd.headerH - rd.cellH) div 2, mix(bg, fg, 0.6))
  rd.setColor(mix(bg, fg, 0.12))
  rd.fillRect(0, rd.listY - l, rd.left, l)

  let rows = rd.visibleRows(outH)
  let iconW = rd.cellW * 3 div 2
  let iconH = max(4, rd.cellH div 2)
  let nameX = rd.padX + iconW + rd.cellW div 2
  let nameChars = (rd.left - nameX - rd.padX) div rd.cellW
  for i in p.scroll ..< min(p.entries.len, p.scroll + rows):
    let e = p.entries[i]
    let y = rd.listY + (i - p.scroll) * rd.rowH
    if i == p.selected or i == p.hovered:
      rd.setColor(if i == p.selected and focused: mix(bg, accent, 0.35)
                  else: mix(bg, fg, if i == p.selected: 0.16 else: 0.08))
      rd.fillRect(0, y, rd.left, rd.rowH)
    let iy = y + (rd.rowH - iconH) div 2
    let dim = if e.isHidden: 0.6 else: 1.0     # dotfiles are drawn fainter
    let (glyph, color) = if e.isDir: ("", -1) else: fileIcon(e.name)
    if e.isDir: rd.drawFolderIcon(rd.padX, iy, iconW, iconH, mix(bg, accent, 0.85 * dim))
    elif glyph.len > 0 and rd.hasGlyph(glyph):
      let c = if color < 0: fg else: rgb(rd.colors.palette[color])
      rd.drawText(glyph, rd.padX + (iconW - rd.textWidth(glyph)) div 2, y + rd.padY,
                  mix(bg, c, (if color < 0: 0.6 else: 0.9) * dim))
    else: rd.drawFileIcon(rd.padX + iconW div 8, iy - iconH div 6, iconW,
                          iconH + iconH div 3, mix(bg, fg, max(0.35, 0.45 * dim)))
    let textT = if e.isDir or i == p.selected: 1.0 else: 0.75
    rd.drawText(fit(e.name, nameChars), nameX, y + rd.padY, mix(bg, fg, textT * dim))

  # Scrollbar, when not everything fits.
  if p.entries.len > rows and rows > 0:
    let trackH = rows * rd.rowH
    let thumbH = max(rd.rowH, trackH * rows div p.entries.len)
    let thumbY = rd.listY + (trackH - thumbH) * p.scroll div max(1, p.entries.len - rows)
    let w = max(2, int(3 * rd.scale))
    rd.setColor(mix(bg, fg, 0.25))
    rd.fillRect(rd.left - w - 2 * l, thumbY, w, thumbH)

  # The divider between the pane and the terminal.
  rd.setColor(mix(bg, fg, 0.2))
  rd.fillRect(rd.left - l, rd.top, l, outH - rd.top)
  discard renderSetClipRect(rd.r, nil)
