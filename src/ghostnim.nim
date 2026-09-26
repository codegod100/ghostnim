## ghostnim — a terminal emulator written in Nim on top of libghostty-vt.
##
## libghostty-vt (Ghostty's terminal core) does all VT parsing, terminal
## state, scrollback, reflow, key/mouse encoding and produces a render
## state; ghostnim supplies the window (SDL2), fonts (SDL_ttf) and the pty.

import std/[os, strutils, posix, sequtils]
import ghostnim/[vt, sdl, pty, renderer, input, menu, update]

const
  version = "0.1.0"
  blinkIntervalMs = 600'u32
  usage = """
ghostnim """ & version & """ - a Nim terminal powered by libghostty-vt

Usage: ghostnim [options] [-e command [args...]]

Options:
  -f, --font NAME|PATH   font family (fontconfig) or font file   [monospace]
  -s, --size N           font size in points                      [14]
      --cols N           initial columns                          [100]
      --rows N           initial rows                             [30]
      --scrollback N     scrollback lines                         [10000]
      --screenshot FILE  render one frame after startup to FILE (BMP) and exit
  -e, --exec CMD ...     run CMD instead of $SHELL (must be last)
  -h, --help             show this help

Keys:
  Ctrl+Shift+T / Ctrl+Shift+W   new tab / close tab
  Ctrl+Tab / Ctrl+Shift+Tab     next / previous tab (also Ctrl+PageDown/PageUp)
  Ctrl+Shift+C / Ctrl+Shift+V   copy selection / paste
  Shift+PageUp / Shift+PageDown scroll back / forward
  Ctrl+= / Ctrl+- / Ctrl+0      bigger / smaller / reset font

Right-click opens a menu with copy, paste, select all and zoom (hold Shift
to open it when the application has mouse reporting on).
"""

type
  Options = object
    font: string
    size: int
    cols, rows: int
    scrollback: int
    command: seq[string]
    screenshot: string

  PtyWatch = object
    ## Shared with a tab's watcher thread, so it lives outside the GC heap.
    fd: cint
    stop: array[0..1, cint]   ## pipe; writing to stop[1] ends the thread
    pending: AtomicInt        ## 1 while an event is queued but not yet handled
    id: int32

  Tab = ref object
    id: int32
    term: GhosttyTerminal
    pty: Pty
    state: GhosttyRenderState
    title: string
    titleChanged: bool
    watch: ptr PtyWatch
    thread: ptr SdlThread

  App = ref object
    opts: Options
    window: WindowPtr
    rd: Renderer
    tabs: seq[Tab]
    active: int
    nextId: int32
    keyEncoder: GhosttyKeyEncoder
    keyEvent: GhosttyKeyEvent
    mouseEncoder: GhosttyMouseEncoder
    mouseEvent: GhosttyMouseEvent
    running: bool
    needsFull: bool
    ## Printable key press waiting for the matching SDL_TEXTINPUT.
    pendingKey: GhosttyKey
    pendingMods: GhosttyMods
    pendingUnshifted: uint32
    hasPendingKey: bool
    ## Set after encoding a modified printable key ourselves, so the
    ## SDL_TEXTINPUT that some platforms still emit for it (e.g. Alt+x on X11)
    ## isn't sent a second time.
    suppressText: bool
    ## Selection drag state (viewport cell coordinates).
    selecting: bool
    selAnchor: (int, int)
    mouseButtons: set[uint8]
    ## Buttons pressed over the tab bar; their release is ours too.
    barButtons: set[uint8]
    lastMouseCell: (int, int)
    menu: ContextMenu

proc cur(app: App): Tab {.inline.} = app.tabs[app.active]

# ---------------------------------------------------------------------------
# PTY wake-up threads, one per tab. Each only blocks in poll() and pushes an
# SDL event (carrying the tab id) when its pty has output, so the UI thread
# can sleep in SDL_WaitEvent. They touch no GC'd memory.

var ptyEventType: uint32

proc ptyWatcher(data: pointer): cint {.cdecl.} =
  let w = cast[ptr PtyWatch](data)
  var pfds = [TPollfd(fd: w.fd, events: POLLIN), TPollfd(fd: w.stop[0], events: POLLIN)]
  while true:
    pfds[0].revents = 0
    pfds[1].revents = 0
    # The UI hasn't drained yet: back off, only watching for a stop request.
    let busy = atomicGet(addr w.pending) != 0
    let n = if busy: poll(addr pfds[1], 1, 2) else: poll(addr pfds[0], 2, -1)
    if n < 0:
      if errno == EINTR: continue
      return 0
    if pfds[1].revents != 0: return 0
    if busy or n == 0: continue
    atomicSet(addr w.pending, 1)
    var ev: Event
    ev.`type` = ptyEventType
    ev.user.code = w.id
    discard pushEvent(addr ev)
    if (pfds[0].revents and (POLLHUP or POLLERR or POLLNVAL)) != 0 and
       (pfds[0].revents and POLLIN) == 0:
      return 0

# ---------------------------------------------------------------------------
# libghostty-vt callbacks

proc onWritePty(t: GhosttyTerminal, userdata: pointer, data: ptr uint8,
                len: csize_t) {.cdecl.} =
  ## The terminal wants to reply to the application (DA, DSR, ...).
  cast[Tab](userdata).pty.writeAll(data, len.int)

proc onTitleChanged(t: GhosttyTerminal, userdata: pointer) {.cdecl.} =
  cast[Tab](userdata).titleChanged = true

# ---------------------------------------------------------------------------

proc outputSize(app: App): (int, int) =
  var w, h: cint
  discard getRendererOutputSize(app.rd.r, addr w, addr h)
  (w.int, h.int)

proc applySize(app: App) =
  ## Fit the terminal grid to the current window size.
  let (w, h) = app.outputSize()
  app.rd.resize(w, h)
  let (cols, rows) = app.rd.gridSize(w, h)
  for tab in app.tabs:
    discard ghostty_terminal_resize(tab.term, cols.uint16, rows.uint16,
                                    app.rd.cellW.uint32, app.rd.cellH.uint32)
    tab.pty.resize(cols, rows, app.rd.cellW, app.rd.cellH)
  var sz = initSized(GhosttyMouseEncoderSize)
  sz.screen_width = w.uint32
  sz.screen_height = h.uint32
  sz.cell_width = app.rd.cellW.uint32
  sz.cell_height = app.rd.cellH.uint32
  sz.padding_top = uint32(app.rd.top + app.rd.pad)
  sz.padding_left = app.rd.pad.uint32
  sz.padding_bottom = uint32(max(0, h - app.rd.top - app.rd.pad - rows * app.rd.cellH))
  sz.padding_right = uint32(w - app.rd.pad - cols * app.rd.cellW)
  ghostty_mouse_encoder_setopt(app.mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, addr sz)
  app.needsFull = true

proc refreshTitle(tab: Tab) =
  var s: GhosttyString
  tab.title = ""
  if ghostty_terminal_get(tab.term, GHOSTTY_TERMINAL_DATA_TITLE, addr s) == GHOSTTY_SUCCESS and
     s.len > 0:
    tab.title = newString(s.len.int)
    copyMem(addr tab.title[0], s.`ptr`, s.len.int)

proc updateWindowTitle(app: App) =
  let title = app.cur.title
  setWindowTitle(app.window, if title.len > 0: title.cstring else: "ghostnim")

# --- tabs -------------------------------------------------------------------

proc newTab(app: App, cwd = ""): Tab =
  ## A terminal plus a child on a pty, sized to the current window.
  let (w, h) = app.outputSize()
  let (cols, rows) = app.rd.gridSize(w, h)
  let tab = Tab(id: app.nextId, state: newRenderState())
  inc app.nextId
  if ghostty_terminal_new(nil, addr tab.term, cols.uint16, rows.uint16) != GHOSTTY_SUCCESS:
    raise newException(CatchableError, "ghostty_terminal_new failed")
  discard ghostty_terminal_resize(tab.term, cols.uint16, rows.uint16,
                                  app.rd.cellW.uint32, app.rd.cellH.uint32)
  var sb = csize_t(app.opts.scrollback)
  discard ghostty_terminal_set(tab.term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, addr sb)
  discard ghostty_terminal_set(tab.term, GHOSTTY_TERMINAL_OPT_USERDATA, cast[pointer](tab))
  discard ghostty_terminal_set(tab.term, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                               cast[pointer](onWritePty))
  discard ghostty_terminal_set(tab.term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                               cast[pointer](onTitleChanged))
  tab.pty = spawn(app.opts.command, cols, rows, app.rd.cellW, app.rd.cellH, cwd)
  tab.watch = cast[ptr PtyWatch](allocShared0(sizeof(PtyWatch)))
  tab.watch.fd = tab.pty.fd
  tab.watch.id = tab.id
  if pipe(tab.watch.stop) != 0: raiseOSError(osLastError(), "pipe failed")
  tab.thread = sdlCreateThread(ptyWatcher, "pty-watch", tab.watch)
  tab

proc free(tab: Tab) =
  discard posix.write(tab.watch.stop[1], cstring("x"), 1)
  sdlWaitThread(tab.thread, nil)
  discard posix.close(tab.watch.stop[0])
  discard posix.close(tab.watch.stop[1])
  deallocShared(tab.watch)
  tab.pty.close()
  ghostty_render_state_free(tab.state)
  ghostty_terminal_free(tab.term)

proc activate(app: App, i: int) =
  app.active = i
  app.selecting = false
  app.menu.close()
  app.needsFull = true
  app.updateWindowTitle()

proc addTab(app: App) =
  ## Open a tab next to the current one, in the current tab's directory.
  let tab = app.newTab(app.cur.pty.cwd)
  app.tabs.insert(tab, app.active + 1)
  app.activate(app.active + 1)

proc closeTab(app: App, i: int) =
  let tab = app.tabs[i]
  app.tabs.delete(i)
  tab.free()
  var status: cint
  while waitpid(-1, status, WNOHANG) > 0: discard   # reap exited children
  if app.tabs.len == 0:
    app.running = false
    return
  if app.active > i or app.active >= app.tabs.len: dec app.active
  app.activate(app.active)

proc cycleTab(app: App, delta: int) =
  let n = app.tabs.len
  app.activate(((app.active + delta) mod n + n) mod n)

proc drainPty(app: App, i: int) =
  ## Feed everything tab `i`'s child wrote into its terminal.
  let tab = app.tabs[i]
  var buf: array[65536, uint8]
  var total = 0
  atomicSet(addr tab.watch.pending, 0)
  while total < 4 * 1024 * 1024:   # yield to the UI after a few MiB
    let n = tab.pty.read(buf)
    if n > 0:
      ghostty_terminal_vt_write(tab.term, addr buf[0], csize_t(n))
      total += n
    elif n == 0:
      break
    else:
      app.closeTab(i)             # the child is gone
      return
  if tab.titleChanged:
    tab.titleChanged = false
    tab.refreshTitle()
    if i == app.active: app.updateWindowTitle()

proc scrollViewport(app: App, tag: cint, delta = 0) =
  var sv: GhosttyTerminalScrollViewport
  sv.tag = tag
  sv.value.delta = delta
  ghostty_terminal_scroll_viewport(app.cur.term, sv)

proc sendInput(app: App, s: string) =
  if s.len == 0: return
  app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_BOTTOM)
  app.cur.pty.writeAll(s)

proc encodeKey(app: App, key: GhosttyKey, action: cint, mods: GhosttyMods,
               unshifted: uint32, text: string) =
  let ev = app.keyEvent
  ghostty_key_event_set_action(ev, action)
  ghostty_key_event_set_key(ev, key)
  ghostty_key_event_set_mods(ev, mods)
  ghostty_key_event_set_consumed_mods(ev, 0)
  ghostty_key_event_set_unshifted_codepoint(ev, unshifted)
  ghostty_key_event_set_utf8(ev, text.cstring, csize_t(text.len))
  # Pick up the terminal's current keyboard modes (DECCKM, kitty flags, ...).
  ghostty_key_encoder_setopt_from_terminal(app.keyEncoder, app.cur.term)
  var outBuf: array[128, char]
  var outLen: csize_t
  if ghostty_key_encoder_encode(app.keyEncoder, ev, cast[cstring](addr outBuf[0]),
                                csize_t(outBuf.len), addr outLen) == GHOSTTY_SUCCESS and
     outLen > 0:
    var s = newString(outLen.int)
    copyMem(addr s[0], addr outBuf[0], outLen.int)
    app.sendInput(s)

proc modeEnabled(app: App, mode: GhosttyMode): bool =
  var cfg = GhosttyTerminalModeConfig(mode: mode)
  ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_MODE, addr cfg) == GHOSTTY_SUCCESS and
    cfg.value

proc mouseTracking(app: App): bool =
  var on: bool
  ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, addr on) ==
    GHOSTTY_SUCCESS and on

# --- clipboard / selection --------------------------------------------------

proc paste(app: App) =
  let clip = getClipboardText()
  if clip == nil: return
  let text = $clip
  sdlFree(clip)
  if text.len == 0: return
  let bracketed = app.modeEnabled(ghostty_mode_new(2004, false))
  var data = text     # ghostty_paste_encode may modify the input in place
  var outBuf = newString(text.len * 2 + 16)
  var written: csize_t
  if ghostty_paste_encode(data.cstring, csize_t(data.len), bracketed, outBuf.cstring,
                          csize_t(outBuf.len), addr written) == GHOSTTY_SUCCESS:
    outBuf.setLen(written.int)
    app.sendInput(outBuf)

proc gridRef(app: App, col, row: int, tag = GHOSTTY_POINT_TAG_VIEWPORT): (bool, GhosttyGridRef) =
  var pt: GhosttyPoint
  pt.tag = tag
  pt.value.coordinate = GhosttyPointCoordinate(x: col.uint16, y: row.uint32)
  var r = initSized(GhosttyGridRef)
  (ghostty_terminal_grid_ref(app.cur.term, pt, addr r) == GHOSTTY_SUCCESS, r)

proc setSelection(app: App, a, b: (int, int)) =
  let (okA, ra) = app.gridRef(a[0], a[1])
  let (okB, rb) = app.gridRef(b[0], b[1])
  if not (okA and okB): return
  var sel = initSized(GhosttySelection)
  sel.start = ra
  sel.`end` = rb
  discard ghostty_terminal_set(app.cur.term, GHOSTTY_TERMINAL_OPT_SELECTION, addr sel)

proc selectAll(app: App) =
  ## Select everything, from the top of the scrollback to the bottom-right
  ## of the active screen.
  var cols, rows: uint16
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_COLS, addr cols)
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_ROWS, addr rows)
  let (okA, ra) = app.gridRef(0, 0, GHOSTTY_POINT_TAG_SCREEN)
  let (okB, rb) = app.gridRef(max(0, cols.int - 1), max(0, rows.int - 1),
                              GHOSTTY_POINT_TAG_ACTIVE)
  if not (okA and okB): return
  var sel = initSized(GhosttySelection)
  sel.start = ra
  sel.`end` = rb
  discard ghostty_terminal_set(app.cur.term, GHOSTTY_TERMINAL_OPT_SELECTION, addr sel)

proc clearSelection(app: App) =
  discard ghostty_terminal_set(app.cur.term, GHOSTTY_TERMINAL_OPT_SELECTION, nil)

proc hasSelection(app: App): bool =
  var sel = initSized(GhosttySelection)
  ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_SELECTION, addr sel) == GHOSTTY_SUCCESS

proc copySelection(app: App) =
  var sel = initSized(GhosttySelection)
  if ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_SELECTION, addr sel) != GHOSTTY_SUCCESS:
    return
  var opts = initSized(GhosttyFormatterTerminalOptions)
  opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
  opts.unwrap = true
  opts.trim = true
  opts.extra = initSized(GhosttyFormatterTerminalExtra)
  opts.extra.screen = initSized(GhosttyFormatterScreenExtra)
  opts.selection = addr sel
  var fmt: GhosttyFormatter
  if ghostty_formatter_terminal_new(nil, addr fmt, app.cur.term, opts) != GHOSTTY_SUCCESS: return
  var p: ptr uint8
  var n: csize_t
  if ghostty_formatter_format_alloc(fmt, nil, addr p, addr n) == GHOSTTY_SUCCESS and p != nil:
    var s = newString(n.int)
    if n > 0: copyMem(addr s[0], p, n.int)
    discard setClipboardText(s.cstring)
    ghostty_free(nil, p, n)
  ghostty_formatter_free(fmt)

proc zoom(app: App, size: int) =
  app.rd.setFontSize(size)
  app.applySize()

# --- context menu -----------------------------------------------------------

proc runMenuAction(app: App, action: MenuAction) =
  if action == maNone: return
  app.menu.close()
  case action
  of maCopy: app.copySelection()
  of maPaste: app.paste()
  of maSelectAll: app.selectAll()
  of maZoomIn: app.zoom(app.rd.fontSize + 1)
  of maZoomOut: app.zoom(app.rd.fontSize - 1)
  of maZoomReset: app.zoom(app.opts.size)
  of maNone: discard

proc menuKey(app: App, e: KeyboardEvent) =
  ## Keyboard handling while the menu is open; nothing reaches the terminal.
  case toGhosttyKey(e.keysym.scancode)
  of gkArrowDown: app.menu.moveHover(1)
  of gkArrowUp: app.menu.moveHover(-1)
  of gkEnter, gkNumpadEnter, gkSpace: app.runMenuAction(app.menu.activate())
  else:
    app.menu.close()
  # Swallow any text the key would have produced.
  app.hasPendingKey = false
  app.suppressText = true

# --- events -----------------------------------------------------------------

proc handleShortcut(app: App, sym: int32, scancode: cint, mods: uint16): bool =
  ## Terminal-level shortcuts. Returns true if the key was consumed.
  let ctrl = (mods and KMOD_CTRL) != 0
  let shift = (mods and KMOD_SHIFT) != 0
  let key = toGhosttyKey(scancode)
  if ctrl and shift and key == gkC:
    app.copySelection(); return true
  if ctrl and shift and key == gkV:
    app.paste(); return true
  if ctrl and shift and key == gkT:
    app.addTab(); return true
  if ctrl and shift and key == gkW:
    app.closeTab(app.active); return true
  if ctrl and key == gkTab:
    app.cycleTab(if shift: -1 else: 1); return true
  if ctrl and not shift and key in {gkPageUp, gkPageDown}:
    app.cycleTab(if key == gkPageUp: -1 else: 1); return true
  if shift and not ctrl and key in {gkPageUp, gkPageDown}:
    var rows: uint16
    discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_ROWS, addr rows)
    let d = max(1, rows.int div 2)
    app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA, if key == gkPageUp: -d else: d)
    return true
  if ctrl and not shift and key in {gkEqual, gkMinus, gkDigit0}:
    app.zoom(case key
             of gkEqual: app.rd.fontSize + 1
             of gkMinus: app.rd.fontSize - 1
             else: app.opts.size)
    return true
  false

proc onKeyDown(app: App, e: KeyboardEvent) =
  let sym = e.keysym.sym
  let smods = e.keysym.`mod`
  if app.menu.open:
    app.menuKey(e)
    return
  if app.handleShortcut(sym, e.keysym.scancode, smods): return
  app.suppressText = false
  let key = toGhosttyKey(e.keysym.scancode)
  let mods = toGhosttyMods(smods)
  let action = if e.repeat != 0: GHOSTTY_KEY_ACTION_REPEAT else: GHOSTTY_KEY_ACTION_PRESS
  let unshifted = unshiftedCodepoint(sym)
  if producesText(sym, smods):
    # Wait for SDL_TEXTINPUT so we get the layout/IME-produced text.
    app.pendingKey = key
    app.pendingMods = mods
    app.pendingUnshifted = unshifted
    app.hasPendingKey = true
    return
  var text = ""
  if unshifted != 0 and (mods and (GHOSTTY_MODS_CTRL or GHOSTTY_MODS_ALT)) != 0:
    # Ctrl/Alt combos generate no SDL text; supply the character ourselves.
    var cp = unshifted
    if (mods and GHOSTTY_MODS_SHIFT) != 0 and cp >= uint32('a') and cp <= uint32('z'):
      cp -= 32
    text = codepointToUtf8(cp)
    app.suppressText = true
  app.encodeKey(key, action, mods, unshifted, text)

proc onKeyUp(app: App, e: KeyboardEvent) =
  # Only emitted when the kitty keyboard protocol asks for release events.
  if app.menu.open: return
  app.encodeKey(toGhosttyKey(e.keysym.scancode), GHOSTTY_KEY_ACTION_RELEASE,
                toGhosttyMods(e.keysym.`mod`), unshiftedCodepoint(e.keysym.sym), "")

proc onTextInput(app: App, e: TextInputEvent) =
  var text = $cast[cstring](unsafeAddr e.text[0])
  if app.suppressText:
    app.suppressText = false
    return
  if app.menu.open: return
  if app.hasPendingKey:
    app.hasPendingKey = false
    app.encodeKey(app.pendingKey, GHOSTTY_KEY_ACTION_PRESS, app.pendingMods,
                  app.pendingUnshifted, text)
  else:
    # Text without a key press (IME commit): send as-is.
    app.sendInput(text)

proc pixelPos(app: App, x, y: int32): (float, float) =
  (float(x) * app.rd.scale, float(y) * app.rd.scale)

proc cellAt(app: App, x, y: int32): (int, int) =
  let (px, py) = app.pixelPos(x, y)
  var cols, rows: uint16
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_COLS, addr cols)
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_ROWS, addr rows)
  let c = clamp(int((px - app.rd.pad.float) / app.rd.cellW.float), 0, max(0, cols.int - 1))
  let r = clamp(int((py - float(app.rd.top + app.rd.pad)) / app.rd.cellH.float), 0,
                max(0, rows.int - 1))
  (c, r)

proc inTabBar(app: App, y: int32): bool =
  float(y) * app.rd.scale < app.rd.top.float

proc onTabBarClick(app: App, button: uint8, x, y: int32) =
  let (px, py) = app.pixelPos(x, y)
  let hit = app.rd.hitTabBar(app.tabs.len, px.int, py.int)
  case hit.kind
  of hitTab:
    if button == BUTTON_LEFT: app.activate(hit.index)
    elif button == BUTTON_MIDDLE: app.closeTab(hit.index)
  of hitClose:
    if button in {BUTTON_LEFT, BUTTON_MIDDLE}: app.closeTab(hit.index)
  of hitNew:
    if button == BUTTON_LEFT: app.addTab()
  of hitNone: discard

proc sendMouse(app: App, action: cint, button: cint, x, y: int32) =
  let ev = app.mouseEvent
  ghostty_mouse_event_set_action(ev, action)
  if button == 0: ghostty_mouse_event_clear_button(ev)
  else: ghostty_mouse_event_set_button(ev, button)
  ghostty_mouse_event_set_mods(ev, toGhosttyMods(getModState()))
  let (px, py) = app.pixelPos(x, y)
  ghostty_mouse_event_set_position(ev, GhosttyMousePosition(x: px.cfloat, y: py.cfloat))
  var anyPressed = app.mouseButtons.len > 0
  ghostty_mouse_encoder_setopt_from_terminal(app.mouseEncoder, app.cur.term)
  ghostty_mouse_encoder_setopt(app.mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                               addr anyPressed)
  var outBuf: array[64, char]
  var outLen: csize_t
  if ghostty_mouse_encoder_encode(app.mouseEncoder, ev, cast[cstring](addr outBuf[0]),
                                  csize_t(outBuf.len), addr outLen) == GHOSTTY_SUCCESS and
     outLen > 0:
    var s = newString(outLen.int)
    copyMem(addr s[0], addr outBuf[0], outLen.int)
    app.cur.pty.writeAll(s)

proc sdlButton(b: uint8): cint =
  case b
  of BUTTON_LEFT: GHOSTTY_MOUSE_BUTTON_LEFT
  of BUTTON_MIDDLE: GHOSTTY_MOUSE_BUTTON_MIDDLE
  of BUTTON_RIGHT: GHOSTTY_MOUSE_BUTTON_RIGHT
  else: 0

proc reportMouse(app: App): bool =
  ## Send mouse events to the app unless Shift is held (forces selection).
  app.mouseTracking() and (getModState() and KMOD_SHIFT) == 0

proc openMenu(app: App, x, y: int32) =
  let (px, py) = app.pixelPos(x, y)
  let (w, h) = app.outputSize()
  app.menu.show(app.rd, @[
    item("Copy", maCopy, "Ctrl+Shift+C", app.hasSelection()),
    item("Paste", maPaste, "Ctrl+Shift+V", hasClipboardText() != 0),
    item("Select All", maSelectAll),
    separator(),
    item("Zoom In", maZoomIn, "Ctrl+="),
    item("Zoom Out", maZoomOut, "Ctrl+-"),
    item("Reset Zoom", maZoomReset, "Ctrl+0"),
  ], int(px), int(py), w, h)

proc menuMouseButton(app: App, e: MouseButtonEvent, down: bool) =
  let (px, py) = app.pixelPos(e.x, e.y)
  let (x, y) = (int(px), int(py))
  if down:
    if not app.menu.contains(x, y):
      app.menu.close()
      # Right-clicking elsewhere moves the menu there.
      if e.button == BUTTON_RIGHT and not app.reportMouse():
        app.openMenu(e.x, e.y)
  else:
    app.runMenuAction(app.menu.release(app.rd, x, y))

proc onMouseButton(app: App, e: MouseButtonEvent, down: bool) =
  if down and not app.menu.open and app.inTabBar(e.y) and app.mouseButtons.len == 0:
    app.barButtons.incl e.button
    app.onTabBarClick(e.button, e.x, e.y)
    return
  if not down and e.button in app.barButtons:
    app.barButtons.excl e.button
    return
  if down: app.mouseButtons.incl e.button else: app.mouseButtons.excl e.button
  if app.menu.open:
    app.menuMouseButton(e, down)
    return
  if app.reportMouse():
    let action = if down: GHOSTTY_MOUSE_ACTION_PRESS else: GHOSTTY_MOUSE_ACTION_RELEASE
    app.sendMouse(action, sdlButton(e.button), e.x, e.y)
    return
  if e.button == BUTTON_LEFT:
    if down:
      app.selecting = true
      app.selAnchor = app.cellAt(e.x, e.y)
      app.clearSelection()
    else:
      app.selecting = false
  elif e.button == BUTTON_MIDDLE and down:
    app.paste()
  elif e.button == BUTTON_RIGHT and down:
    app.openMenu(e.x, e.y)

proc onMouseMotion(app: App, e: MouseMotionEvent) =
  if app.menu.open:
    let (px, py) = app.pixelPos(e.x, e.y)
    app.menu.motion(app.rd, int(px), int(py))
  elif app.reportMouse():
    if app.mouseButtons.len == 0 and app.inTabBar(e.y): return
    let cell = app.cellAt(e.x, e.y)
    if cell == app.lastMouseCell: return
    app.lastMouseCell = cell
    var button = 0.cint
    for b in [BUTTON_LEFT, BUTTON_MIDDLE, BUTTON_RIGHT]:
      if b in app.mouseButtons:
        button = sdlButton(b)
        break
    app.sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button, e.x, e.y)
  elif app.selecting:
    app.setSelection(app.selAnchor, app.cellAt(e.x, e.y))

proc onMouseWheel(app: App, e: MouseWheelEvent) =
  var dy = e.y
  if e.direction == MOUSEWHEEL_FLIPPED: dy = -dy
  if dy == 0: return
  if app.menu.open:
    app.menu.close()
    return
  var x, y: cint
  discard getMouseState(addr x, addr y)
  if app.inTabBar(y):
    app.cycleTab(if dy > 0: -1 else: 1)
  elif app.reportMouse():
    let button = if dy > 0: GHOSTTY_MOUSE_BUTTON_FOUR else: GHOSTTY_MOUSE_BUTTON_FIVE
    for _ in 1 .. abs(dy):
      app.sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button, x, y)
  else:
    app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA, -3 * dy)

proc handleEvent(app: App, e: var Event) =
  let t = e.`type`
  if t == ptyEventType:
    for i, tab in app.tabs:
      if tab.id == e.user.code:
        app.drainPty(i)
        break
  elif t == EV_QUIT:
    app.running = false
  elif t == EV_KEYDOWN:
    app.onKeyDown(e.key)
  elif t == EV_KEYUP:
    app.onKeyUp(e.key)
  elif t == EV_TEXTINPUT:
    app.onTextInput(e.text)
  elif t == EV_MOUSEBUTTONDOWN:
    app.onMouseButton(e.button, true)
  elif t == EV_MOUSEBUTTONUP:
    app.onMouseButton(e.button, false)
  elif t == EV_MOUSEMOTION:
    app.onMouseMotion(e.motion)
  elif t == EV_MOUSEWHEEL:
    app.onMouseWheel(e.wheel)
  elif t == EV_WINDOW:
    case e.window.event
    of WINDOWEVENT_SIZE_CHANGED:
      app.menu.close()
      app.applySize()
    of WINDOWEVENT_EXPOSED: app.needsFull = true
    of WINDOWEVENT_FOCUS_GAINED, WINDOWEVENT_FOCUS_LOST:
      if e.window.event == WINDOWEVENT_FOCUS_LOST: app.menu.close()
      app.rd.focused = e.window.event == WINDOWEVENT_FOCUS_GAINED
      app.needsFull = true
    else: discard

# ---------------------------------------------------------------------------

proc saveScreenshot(app: App, path: string) =
  ## Dump the current backbuffer to a 24-bit BMP (used for headless testing).
  let (w, h) = app.outputSize()
  var pixels = newSeq[uint32](w * h)
  if renderReadPixels(app.rd.r, nil, PIXELFORMAT_ARGB8888, addr pixels[0], cint(w * 4)) != 0:
    stderr.writeLine "ghostnim: screenshot failed: ", getError()
    return
  let rowSize = (w * 3 + 3) and not 3
  var f = open(path, fmWrite)
  defer: f.close()
  proc le32(v: int): string =
    result = newString(4)
    for i in 0..3: result[i] = char((v shr (8 * i)) and 0xFF)
  proc le16(v: int): string = le32(v)[0..1]
  f.write "BM" & le32(54 + rowSize * h) & le32(0) & le32(54)
  f.write le32(40) & le32(w) & le32(h) & le16(1) & le16(24) & le32(0) &
          le32(rowSize * h) & le32(2835) & le32(2835) & le32(0) & le32(0)
  var row = newString(rowSize)
  for y in countdown(h - 1, 0):
    for x in 0 ..< w:
      let p = pixels[y * w + x]
      row[x * 3] = char(p and 0xFF)
      row[x * 3 + 1] = char((p shr 8) and 0xFF)
      row[x * 3 + 2] = char((p shr 16) and 0xFF)
    f.write row

proc parseOptions(): Options =
  result = Options(size: 14, cols: 100, rows: 30, scrollback: 10_000)
  let args = commandLineParams()
  var i = 0
  proc need(i: var int): string =
    inc i
    if i >= args.len:
      quit("ghostnim: missing value for " & args[i - 1], 2)
    args[i]
  while i < args.len:
    let a = args[i]
    case a
    of "-h", "--help": echo usage; quit(0)
    of "-f", "--font": result.font = need(i)
    of "-s", "--size": result.size = parseInt(need(i))
    of "--cols": result.cols = parseInt(need(i))
    of "--rows": result.rows = parseInt(need(i))
    of "--scrollback": result.scrollback = parseInt(need(i))
    of "--screenshot": result.screenshot = need(i)
    of "-e", "--exec":
      result.command = args[i + 1 .. ^1]
      break
    else:
      quit("ghostnim: unknown option " & a & "\n\n" & usage, 2)
    inc i
  if result.command.len == 0: result.command = @[defaultShell()]


# Window icon, embedded so it works without any installed files.
let iconBmp = static(staticRead("../packaging/ghostnim-128.bmp"))

proc setIcon(window: WindowPtr) =
  let icon = loadBMP_RW(rwFromConstMem(unsafeAddr iconBmp[0], cint(iconBmp.len)), 1)
  if icon == nil: return
  setWindowIcon(window, icon)
  freeSurface(icon)

proc main() =
  let opts = parseOptions()
  # Before SDL starts any threads, since this forks.
  if opts.screenshot.len == 0: startUpdateCheck()
  discard setHint("SDL_IM_MODULE", "")   # let the platform pick its IME
  if sdl.init(INIT_VIDEO or INIT_EVENTS) != 0:
    quit("ghostnim: SDL_Init failed: " & $getError(), 1)
  defer: sdl.quit()
  if ttfInit() != 0:
    quit("ghostnim: TTF_Init failed: " & $getError(), 1)
  defer: ttfQuit()

  let app = App(opts: opts, running: true, needsFull: true)
  let fontPaths = resolveFonts(opts.font)

  # Measure the cell size first so the initial window fits cols x rows.
  app.window = createWindow("ghostnim", WINDOWPOS_CENTERED, WINDOWPOS_CENTERED, 800, 600,
                            WINDOW_RESIZABLE or WINDOW_ALLOW_HIGHDPI)
  if app.window == nil: quit("ghostnim: SDL_CreateWindow failed: " & $getError(), 1)
  app.window.setIcon()
  var r = createRenderer(app.window, -1, RENDERER_ACCELERATED or RENDERER_TARGETTEXTURE)
  if r == nil: r = createRenderer(app.window, -1, RENDERER_TARGETTEXTURE)
  if r == nil: quit("ghostnim: SDL_CreateRenderer failed: " & $getError(), 1)
  var ww, wh, ow, oh: cint
  getWindowSize(app.window, addr ww, addr wh)
  discard getRendererOutputSize(r, addr ow, addr oh)
  let scale = if ww > 0: ow.float / ww.float else: 1.0
  app.rd = newRenderer(r, fontPaths, opts.size, scale)
  let winW = (opts.cols * app.rd.cellW + 2 * app.rd.pad).float / scale
  let winH = (opts.rows * app.rd.cellH + app.rd.top + 2 * app.rd.pad).float / scale
  setWindowSize(app.window, cint(winW + 0.5), cint(winH + 0.5))

  discard ghostty_key_encoder_new(nil, addr app.keyEncoder)
  discard ghostty_key_event_new(nil, addr app.keyEvent)
  discard ghostty_mouse_encoder_new(nil, addr app.mouseEncoder)
  discard ghostty_mouse_event_new(nil, addr app.mouseEvent)

  # The first tab: a terminal and its child on a pty, watched by a thread
  # that wakes the UI.
  ptyEventType = registerEvents(1)
  app.tabs.add app.newTab()
  app.applySize()
  app.updateWindowTitle()
  startTextInput()

  let startTicks = getTicks()
  var lastBlink = getTicks()
  var blinkOn = true
  var ev: Event
  while app.running:
    let timeout = if app.rd.cursorBlinking(app.cur.state): cint(blinkIntervalMs) else: cint(1000)
    if waitEventTimeout(addr ev, timeout) != 0:
      app.handleEvent(ev)
      while app.running and pollEvent(addr ev) != 0:
        app.handleEvent(ev)
    let now = getTicks()
    if now - lastBlink >= blinkIntervalMs:
      blinkOn = not blinkOn
      lastBlink = now
    if not app.running: break
    app.rd.draw(app.cur.state, app.cur.term, app.needsFull, blinkOn)
    app.rd.drawTabBar(app.tabs.mapIt(it.title), app.active)
    app.menu.draw(app.rd)
    app.needsFull = false
    if opts.screenshot.len > 0 and now - startTicks > 1500:
      # Headless test hook: capture the backbuffer before presenting it.
      app.saveScreenshot(opts.screenshot)
      app.running = false
    renderPresent(app.rd.r)

  for tab in app.tabs: tab.free()
  ghostty_mouse_event_free(app.mouseEvent)
  ghostty_mouse_encoder_free(app.mouseEncoder)
  ghostty_key_event_free(app.keyEvent)
  ghostty_key_encoder_free(app.keyEncoder)
  app.rd.destroy()
  destroyRenderer(r)
  destroyWindow(app.window)

when isMainModule:
  main()
