## The file manager pane: a folder listing split off the left of the window,
## next to the terminal. It follows the current tab's working directory.
##
## Like the menu, it's drawn by ghostnim itself each frame, in the space the
## renderer leaves free left of the grid (`Renderer.left`). All coordinates
## are in output (HiDPI) pixels.

import std/[os, algorithm, strutils, times]
from std/unicode import runeLen, runeSubStr
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

proc initFilePane*(): FilePane = FilePane(hovered: -1, selected: -1)

# --- listing -----------------------------------------------------------------

proc mtime(dir: string): Time =
  try: getLastModificationTime(dir) except OSError: Time()

proc list(dir: string): seq[Entry] =
  ## The folder's visible entries: folders first, each group by name.
  var dirs, files: seq[Entry]
  try:
    for kind, name in walkDir(dir, relative = true):
      if name.startsWith("."): continue
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
  p.entries = list(dir)
  p.scroll = min(p.scroll, max(0, p.entries.len - 1))
  if p.selected >= p.entries.len: p.selected = -1

proc refresh*(p: var FilePane) =
  ## List the folder again if something was added, removed or renamed in it.
  if p.dir.len == 0: return
  if not dirExists(p.dir):
    var up = p.dir
    while up.len > 1 and not dirExists(up): up = up.parentDir
    p.load(up)
  elif mtime(p.dir) != p.stamp:
    let selName = if p.selected >= 0: p.entries[p.selected].name else: ""
    p.load(p.dir)
    p.selected = -1
    for i, e in p.entries:
      if e.name == selName: p.selected = i

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
  let l = rd.line
  let w = w * 3 div 4
  rd.setColor(c)
  rd.fillRect(x, y, w, l)
  rd.fillRect(x, y + h - l, w, l)
  rd.fillRect(x, y, l, h)
  rd.fillRect(x + w - l, y, l, h)

proc draw*(p: FilePane, rd: Renderer, outH: int) =
  ## Composite the pane onto the backbuffer, in the terminal's colours.
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
      rd.setColor(mix(bg, fg, if i == p.selected: 0.16 else: 0.08))
      rd.fillRect(0, y, rd.left, rd.rowH)
    let iy = y + (rd.rowH - iconH) div 2
    if e.isDir: rd.drawFolderIcon(rd.padX, iy, iconW, iconH, mix(bg, accent, 0.85))
    else: rd.drawFileIcon(rd.padX + iconW div 8, iy - iconH div 6, iconW,
                          iconH + iconH div 3, mix(bg, fg, 0.45))
    rd.drawText(fit(e.name, nameChars), nameX, y + rd.padY,
                if e.isDir or i == p.selected: fg else: mix(bg, fg, 0.75))

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
