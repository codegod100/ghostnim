## Right-click context menu.
##
## SDL2 has no native menus, so the menu is drawn by ghostnim itself on top of
## the terminal each frame. All coordinates are in output (HiDPI) pixels.

import sdl, renderer

type
  MenuAction* = enum
    maNone,       ## separators
    maCopy, maPaste, maSelectAll, maZoomIn, maZoomOut, maZoomReset, maOpenConfig,
    maToggleFolderBar, maToggleFilePane, maToggleHiddenFiles, maFilterFiles

  MenuItem* = object
    label*, shortcut*: string
    action*: MenuAction
    enabled*: bool

  ContextMenu* = object
    open*: bool
    items: seq[MenuItem]
    x, y, w, h: int
    hovered: int              ## index into items, -1 for none
    openX, openY: int
    ignoreRelease: bool       ## the release of the click that opened us

proc item*(label: string, action: MenuAction, shortcut = "", enabled = true): MenuItem =
  MenuItem(label: label, shortcut: shortcut, action: action, enabled: enabled)

proc separator*(): MenuItem = MenuItem(action: maNone)

proc isSeparator(it: MenuItem): bool {.inline.} = it.action == maNone

# --- geometry ----------------------------------------------------------------

proc border(rd: Renderer): int = max(1, int(rd.scale))
proc padX(rd: Renderer): int = int(12 * rd.scale)
proc padY(rd: Renderer): int = int(3 * rd.scale)
proc itemH(rd: Renderer): int = rd.cellH + 2 * rd.padY
proc sepH(rd: Renderer): int = max(3, int(7 * rd.scale))

proc rowHeight(rd: Renderer, it: MenuItem): int =
  if it.isSeparator: rd.sepH else: rd.itemH

proc show*(m: var ContextMenu, rd: Renderer, items: seq[MenuItem], x, y, outW, outH: int) =
  ## Open the menu with its top-left corner at (x, y), kept inside the window.
  m.items = items
  var labelW, shortcutW = 0
  m.h = 2 * rd.border
  for it in items:
    m.h += rd.rowHeight(it)
    if not it.isSeparator:
      labelW = max(labelW, rd.textWidth(it.label))
      shortcutW = max(shortcutW, rd.textWidth(it.shortcut))
  let gap = if shortcutW > 0: 3 * rd.cellW else: 0
  m.w = 2 * rd.border + 2 * rd.padX + labelW + gap + shortcutW
  # Flip to the left/top of the pointer when there's no room, then clamp.
  m.x = if x + m.w > outW: x - m.w else: x
  m.y = if y + m.h > outH: y - m.h else: y
  m.x = clamp(m.x, 0, max(0, outW - m.w))
  m.y = clamp(m.y, 0, max(0, outH - m.h))
  m.hovered = -1
  m.openX = x
  m.openY = y
  m.ignoreRelease = true
  m.open = true

proc close*(m: var ContextMenu) =
  m.open = false
  m.hovered = -1

proc contains*(m: ContextMenu, x, y: int): bool =
  m.open and x >= m.x and x < m.x + m.w and y >= m.y and y < m.y + m.h

proc itemAt(m: ContextMenu, rd: Renderer, x, y: int): int =
  ## Index of the selectable item under (x, y), or -1.
  if not m.contains(x, y): return -1
  var top = m.y + rd.border
  for i, it in m.items:
    let h = rd.rowHeight(it)
    if y >= top and y < top + h:
      return if it.isSeparator or not it.enabled: -1 else: i
    top += h
  -1

# --- input -------------------------------------------------------------------

proc motion*(m: var ContextMenu, rd: Renderer, x, y: int) =
  m.hovered = m.itemAt(rd, x, y)
  let slop = int(4 * rd.scale)
  if abs(x - m.openX) > slop or abs(y - m.openY) > slop:
    m.ignoreRelease = false

proc release*(m: var ContextMenu, rd: Renderer, x, y: int): MenuAction =
  ## A mouse button was released at (x, y). Returns the chosen action, if any.
  ## Releasing the button that opened the menu without moving keeps it open,
  ## so both press-drag-release and click-then-click work.
  if m.ignoreRelease:
    m.ignoreRelease = false
    return maNone
  let i = m.itemAt(rd, x, y)
  if i >= 0: m.items[i].action else: maNone

proc moveHover*(m: var ContextMenu, delta: int) =
  ## Keyboard navigation: move to the next/previous enabled item, wrapping.
  let n = m.items.len
  if n == 0: return
  var i = if m.hovered < 0: (if delta > 0: -1 else: n) else: m.hovered
  for _ in 0 ..< n:
    i = (i + delta + n) mod n
    if not m.items[i].isSeparator and m.items[i].enabled:
      m.hovered = i
      return

proc activate*(m: ContextMenu): MenuAction =
  ## The action of the highlighted item (keyboard Enter).
  if m.hovered >= 0: m.items[m.hovered].action else: maNone

# --- drawing -----------------------------------------------------------------

proc mix(a, b: Rgb, t: float): Rgb =
  template ch(x, y: uint8): uint8 = uint8(float(x) + (float(y) - float(x)) * t + 0.5)
  Rgb(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b))

proc draw*(m: ContextMenu, rd: Renderer) =
  ## Composite the menu onto the backbuffer, using the terminal's colours.
  if not m.open: return
  let bg = rgb(rd.colors.background)
  let fg = rgb(rd.colors.foreground)
  let b = rd.border

  # Drop shadow.
  let sh = max(2, int(3 * rd.scale))
  discard setRenderDrawBlendMode(rd.r, BLENDMODE_BLEND)
  rd.setColor(Rgb(), 90)
  rd.fillRect(m.x + sh, m.y + sh, m.w, m.h)
  discard setRenderDrawBlendMode(rd.r, BLENDMODE_NONE)

  rd.setColor(mix(bg, fg, 0.35))
  rd.fillRect(m.x, m.y, m.w, m.h)
  rd.setColor(mix(bg, fg, 0.07))
  rd.fillRect(m.x + b, m.y + b, m.w - 2 * b, m.h - 2 * b)

  var top = m.y + b
  for i, it in m.items:
    let h = rd.rowHeight(it)
    if it.isSeparator:
      rd.setColor(mix(bg, fg, 0.25))
      rd.fillRect(m.x + b + rd.padX div 2, top + h div 2, m.w - 2 * b - rd.padX, b)
    else:
      if i == m.hovered:
        rd.setColor(mix(bg, fg, 0.22))
        rd.fillRect(m.x + b, top, m.w - 2 * b, h)
      let textColor = if it.enabled: fg else: mix(bg, fg, 0.4)
      rd.drawText(it.label, m.x + b + rd.padX, top + rd.padY, textColor)
      if it.shortcut.len > 0:
        let sw = rd.textWidth(it.shortcut)
        rd.drawText(it.shortcut, m.x + m.w - b - rd.padX - sw, top + rd.padY,
                    if it.enabled: mix(bg, fg, 0.6) else: textColor)
    top += h
