## ghostnim — a terminal emulator written in Nim on top of libghostty-vt.
##
## libghostty-vt (Ghostty's terminal core) does all VT parsing, terminal
## state, scrollback, reflow, key/mouse encoding and produces a render
## state; ghostnim supplies the window (SDL2), fonts (SDL_ttf) and the pty.

import std/[os, strutils, posix, sequtils, options, algorithm]
from std/times import epochTime, `==`
from std/unicode import runeLen, runeSubStr
import ghostnim/[vt, sdl, pty, renderer, input, menu, update, config, keybinds, links,
                wordsel, paths, filepane]

const
  version = "0.1.0"
  blinkIntervalMs = 600'u32
  shownRecentDirs = 12     ## folders offered in the strip under the tabs (as many as fit)
  keptRecentDirs = 50      ## history kept, shared by all tabs
  defaultPaneWidth = 240   ## file pane width in window pixels
  usage = """
ghostnim """ & version & """ - a Nim terminal powered by libghostty-vt

Usage: ghostnim [options] [-e command [args...]]

Options:
  -c, --config FILE      config file  [$XDG_CONFIG_HOME/ghostnim/config.kdl]
  -f, --font NAME|PATH   font family (fontconfig) or font file   [Monaspace Neon Frozen]
  -s, --size N           font size in points                      [14]
      --no-font-shaping  draw characters one by one: no ligatures or
                         contextual alternates
      --cols N           initial columns                          [100]
      --rows N           initial rows                             [30]
      --scrollback N     scrollback lines                         [10000]
  -d, --working-directory DIR  start the first tab in DIR  [current directory]
      --no-inherit-directory   start new tabs in the working directory too,
                         not in the current tab's directory
      --screenshot FILE  render one frame after startup to FILE (BMP) and exit
  -e, --exec CMD ...     run CMD instead of $SHELL (must be last)
  -h, --help             show this help

Keys (defaults; change them in the config file's keybinds block):
  Ctrl+Shift+T / Ctrl+Shift+W   new tab / close tab
  Ctrl+Tab / Ctrl+Shift+Tab     next / previous tab (also Ctrl+PageDown/PageUp)
  Ctrl+Shift+C / Ctrl+Shift+V   copy selection / paste
  Shift+PageUp / Shift+PageDown scroll back / forward
  Ctrl+= / Ctrl+- / Ctrl+0      bigger / smaller / reset font (also Ctrl++)
  Ctrl+,                        open the config file in $VISUAL/$EDITOR
  Ctrl+Shift+E                  show and focus / hide the file manager
  Ctrl+Shift+O                  open the current folder in $VISUAL/$EDITOR
  Ctrl+Shift+,                  reload the config file (also automatic on save)

Drag to select text, double-click to select a word, path or URL, and
triple-click to select a line. A selection is copied to the clipboard as soon
as it's made.

Ctrl+click a link (an OSC 8 hyperlink or a URL in the text) to open it.
Ctrl+click a path to a directory to open a new tab there, or a path to a file
to open it in $VISUAL/$EDITOR in a new tab.

Right-click opens a menu with copy, paste, select all, zoom, show/hide recent
folders, show/hide the file manager, Open Folder in Editor and Open Config (hold Shift to open it when
the application has mouse reporting on). Click a recent folder under the tabs
to cd there.

Ctrl+Shift+E shows the file manager, split off the left of the window. It
lists the current tab's folder: click a folder to cd there, double-click a
file to open it, middle-click a file to type its path into the terminal (or a
folder to open a new tab there), and drag the divider to resize it. While it
has focus: arrows, PageUp/PageDown and Home/End move, Enter opens, Left or
Backspace goes up, typing jumps to a name, Ctrl+H shows or hides dotfiles,
Shift+Enter types the path into the terminal and Escape returns to it.

Every option except --config, --screenshot and --help can also be set in the
config file (KDL): `font "Iosevka"`, `font-size 13`, `font-shaping #false`,
`cols 120`, `rows 36`, `scrollback 50000`, `command "fish" "--login"`,
`working-directory "~/code"`, `inherit-directory #false`,
`copy-on-select #false`, plus `colors { ... }` and `keybinds { ... }` blocks. The command line wins.
"""

type
  Cli = object
    ## What the command line set. It wins over the config file, on every
    ## reload too; empty/zero fields were not given.
    configPath, font, workingDirectory, screenshot: string
    size, cols, rows: int
    scrollback: int          ## -1 when not given
    command: seq[string]
    noInheritDirectory: bool
    noFontShaping: bool

  Options = object
    font: string
    size: int
    cols, rows: int
    scrollback: int
    command: seq[string]
    workingDirectory: string
    inheritDirectory: bool
    fontShaping: bool
    copyOnSelect: bool
    colors: Colors
    keybinds: Keybinds
    screenshot: string

  RecentDir = object
    path: string
    visits: int               ## times a tab has gone there
    lastVisit: int64          ## when the latest was, in Unix milliseconds

  SelectUnit = enum
    ## What a selection drag grows by: cells, or (after a double or triple
    ## click) whole words or lines.
    suCell, suWord, suLine

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
    lastDir: string           ## working directory when last looked at
    watch: ptr PtyWatch
    thread: ptr SdlThread

  App = ref object
    opts: Options
    cli: Cli
    configStamp: ConfigStamp   ## the config file as last loaded
    configChecked: uint32      ## ticks of the last check for changes
    window: WindowPtr
    rd: Renderer
    tabs: seq[Tab]
    active: int
    dirs: seq[RecentDir]       ## folders any tab has been in, most used first
    newVisits: seq[tuple[path: string, at: int64]]  ## not yet in the shared file
    goneDirs: seq[string]      ## folders found missing, to drop from it
    dirsStamp: times.Time      ## the shared file's mtime when last read
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
    selUnit: SelectUnit
    ## The word or line first clicked, which a word/line drag always keeps.
    selAnchorStart, selAnchorEnd: (int, int)
    mouseButtons: set[uint8]
    ## Buttons whose press we handled ourselves (tab bar, Ctrl+click on a
    ## link); their release is ours too, not the terminal's.
    ownButtons: set[uint8]
    lastMouseCell: (int, int)
    menu: ContextMenu
    arrowCursor, handCursor: ptr SdlCursor
    shownCursor: ptr SdlCursor ## the pointer's current shape
    resizeCursor: ptr SdlCursor
    dirsChecked: uint32        ## ticks of the last look at the tabs' directories
    folderHover: int           ## recent-folder chip under the pointer, -1 for none
    ## The file manager pane.
    pane: FilePane
    paneOn: bool
    paneW: int                 ## its width in window pixels
    paneTab: int32             ## the tab it follows, -1 to pick up the current one
    paneCwd: string            ## that tab's directory when last looked at
    paneChecked: uint32        ## ticks of the last look for changes in the folder
    resizingPane: bool         ## the divider is being dragged
    paneFocused: bool          ## keys go to the file pane, not the terminal
    typeAhead: string          ## what's been typed to find a file pane entry
    typeAheadAt: uint32        ## ticks of the last key typed into it
    windowFocused: bool

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

proc paneWidth(app: App, outW: int): int =
  ## The file pane's width in output pixels: as set, but leaving the
  ## terminal at least 20 columns.
  let minW = 12 * app.rd.cellW
  clamp(int(app.paneW.float * app.rd.scale + 0.5), minW,
        max(minW, outW - 20 * app.rd.cellW - 2 * app.rd.pad))

proc applySize(app: App) =
  ## Fit the terminal grid to the current window size.
  let (w, h) = app.outputSize()
  app.rd.left = if app.paneOn: app.paneWidth(w) else: 0
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
  sz.padding_left = uint32(app.rd.left + app.rd.pad)
  sz.padding_bottom = uint32(max(0, h - app.rd.top - app.rd.pad - rows * app.rd.cellH))
  sz.padding_right = uint32(max(0, w - app.rd.left - app.rd.pad - cols * app.rd.cellW))
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

# --- options ----------------------------------------------------------------

proc parseCli(): Cli =
  result.scrollback = -1
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
    of "-c", "--config": result.configPath = need(i)
    of "-f", "--font": result.font = need(i)
    of "-s", "--size": result.size = parseInt(need(i))
    of "--cols": result.cols = parseInt(need(i))
    of "--rows": result.rows = parseInt(need(i))
    of "--scrollback": result.scrollback = parseInt(need(i))
    of "-d", "--working-directory":
      result.workingDirectory = expandTilde(need(i))
      if not dirExists(result.workingDirectory):
        quit("ghostnim: no such directory: " & result.workingDirectory, 2)
    of "--no-inherit-directory": result.noInheritDirectory = true
    of "--no-font-shaping": result.noFontShaping = true
    of "--screenshot": result.screenshot = need(i)
    of "-e", "--exec":
      result.command = args[i + 1 .. ^1]
      break
    else:
      quit("ghostnim: unknown option " & a & "\n\n" & usage, 2)
    inc i

proc launchedFromDesktop(): bool =
  ## Desktop launchers start programs in $HOME or /. Anywhere else (a file
  ## manager's "Open Terminal Here", a shell in some project) was chosen on
  ## purpose, so the first tab should start there.
  try:
    let cwd = getCurrentDir()
    result = cwd == "/" or sameFile(cwd, getHomeDir())
  except OSError:
    result = true

proc merge(cfg: Config, cli: Cli): Options =
  ## The config file's settings with the command line's on top. The config's
  ## working-directory only replaces the launch directory when that's just
  ## the desktop's default.
  template pick(c, f: untyped): untyped = (if c: cli.f else: cfg.f)
  result = Options(
    font: pick(cli.font.len > 0, font),
    size: pick(cli.size > 0, size),
    cols: pick(cli.cols > 0, cols),
    rows: pick(cli.rows > 0, rows),
    scrollback: pick(cli.scrollback >= 0, scrollback),
    command: pick(cli.command.len > 0, command),
    workingDirectory:
      if cli.workingDirectory.len > 0: cli.workingDirectory
      elif launchedFromDesktop(): cfg.workingDirectory
      else: "",
    inheritDirectory: cfg.inheritDirectory and not cli.noInheritDirectory,
    fontShaping: cfg.fontShaping and not cli.noFontShaping,
    copyOnSelect: cfg.copyOnSelect,
    colors: cfg.colors, keybinds: cfg.keybinds, screenshot: cli.screenshot)
  if result.command.len == 0: result.command = @[defaultShell()]

# --- tabs -------------------------------------------------------------------

proc applyColors(app: App, term: GhosttyTerminal) =
  ## The config file's colours become the terminal's defaults, which programs
  ## can still override with OSC 4/10/11/12. Unset ones go back to built-in.
  let c = app.opts.colors
  proc toVt(c: ConfigRgb): GhosttyColorRgb = GhosttyColorRgb(r: c.r, g: c.g, b: c.b)
  for (opt, col) in [(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, c.foreground),
                     (GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, c.background),
                     (GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, c.cursor)]:
    var v = toVt(col.get((0'u8, 0'u8, 0'u8)))
    discard ghostty_terminal_set(term, opt, if col.isSome: addr v else: nil)
  # Reset first, so PALETTE_DEFAULT is the built-in palette, not the last config's.
  discard ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
  if c.palette.len > 0:
    var pal: array[256, GhosttyColorRgb]
    discard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, addr pal)
    for (i, col) in c.palette: pal[i] = toVt(col)
    discard ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, addr pal)

proc applySelectionColors(app: App) =
  template toRgb(c: Option[ConfigRgb]): Option[Rgb] =
    (if c.isSome: some(Rgb(r: c.get.r, g: c.get.g, b: c.get.b)) else: none(Rgb))
  app.rd.selectionFg = toRgb(app.opts.colors.selectionForeground)
  app.rd.selectionBg = toRgb(app.opts.colors.selectionBackground)
  app.rd.shaping = app.opts.fontShaping

proc newTab(app: App, cwd = "", command: seq[string] = @[]): Tab =
  ## A terminal plus a child on a pty, sized to the current window, running
  ## `command` (default: the configured shell).
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
  app.applyColors(tab.term)
  tab.pty = spawn(if command.len > 0: command else: app.opts.command, cols, rows, app.rd.cellW, app.rd.cellH,
                  if cwd.len > 0: cwd else: app.opts.workingDirectory)
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
  app.paneTab = -1            # the file pane follows the new tab
  app.selecting = false
  app.menu.close()
  app.needsFull = true
  app.updateWindowTitle()

proc addTab(app: App, command: seq[string] = @[], dir = "") =
  ## Open a tab next to the current one, in `dir` if given, else in the
  ## current tab's directory (or in working-directory, with
  ## inherit-directory off).
  let cwd = if dir.len > 0: dir
            elif app.opts.inheritDirectory: app.cur.pty.cwd
            else: ""
  let tab = app.newTab(cwd, command)
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
    # Selecting only blanks (e.g. double-clicking empty space) mustn't
    # wipe out what's on the clipboard.
    if s.strip.len > 0: discard setClipboardText(s.cstring)
    ghostty_free(nil, p, n)
  ghostty_formatter_free(fmt)

proc selectAllText(app: App) =
  app.selectAll()
  if app.opts.copyOnSelect: app.copySelection()

proc zoom(app: App, size: int) =
  app.rd.setFontSize(size)
  app.applySize()

proc reloadConfig(app: App) =
  ## Re-read the config file and apply it. Window size (cols/rows) only
  ## matters at startup; command and working-directory apply to new tabs.
  app.configStamp = stamp(configFile(app.cli.configPath))
  let cfg = reloadConfig(app.cli.configPath)
  if cfg.isNone: return            # unreadable or invalid: keep what we have
  let old = app.opts
  var o = merge(cfg.get, app.cli)
  o.screenshot = old.screenshot
  app.opts = o
  for tab in app.tabs:
    app.applyColors(tab.term)
    var sb = csize_t(o.scrollback)
    discard ghostty_terminal_set(tab.term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, addr sb)
  app.applySelectionColors()
  var fontChanged = false
  if o.font != old.font:
    try:
      app.rd.setFonts(resolveFonts(o.font))
      fontChanged = true
    except IOError as e:
      stderr.writeLine "ghostnim: " & e.msg
      app.opts.font = old.font
  if o.size != old.size: app.zoom(o.size)             # also resets any zoom
  elif fontChanged: app.zoom(app.rd.fontSize)        # new cell size
  app.needsFull = true
  stderr.writeLine "ghostnim: reloaded " & configFile(app.cli.configPath)

proc openExternal(target: string) =
  ## Hand a file or URL to the desktop (xdg-open, or open on macOS).
  let opener = when defined(macosx): "open" else: "xdg-open"
  if findExe(opener).len == 0:
    stderr.writeLine "ghostnim: can't open " & target & ": " & opener & " not found"
    return
  discard execShellCmd(opener & " " & quoteShell(target) & " >/dev/null 2>&1 &")

proc editorTab(app: App, path: string, dir = ""): bool =
  ## Run $VISUAL or $EDITOR on `path` in a new tab (in `dir`). False when
  ## neither is set.
  let editor = getEnv("VISUAL", getEnv("EDITOR"))
  if editor.len == 0: return false
  # Through sh so an $EDITOR with arguments ("code --wait") works.
  app.addTab(@["/bin/sh", "-c", "exec " & editor & " \"$1\"", "sh", path], dir)
  true

proc openConfig(app: App) =
  ## Open the config file for editing, creating it from the commented
  ## defaults first if needed. $VISUAL or $EDITOR runs in a new tab;
  ## without either, the desktop's handler for the file (xdg-open).
  let path = configFile(app.cli.configPath)
  if not ensureConfigFile(path): return
  if app.editorTab(path): discard
  elif findExe("xdg-open").len > 0:
    openExternal(path)
  else:
    app.addTab(@["vi", path])

proc openFolderInEditor(app: App) =
  ## Open the current folder (the file manager's, when it's shown, else the
  ## tab's) in $VISUAL/$EDITOR in a new tab there, or in vi without either.
  let dir = if app.paneOn and app.pane.dir.len > 0: app.pane.dir
            else: app.cur.pty.cwd
  if dir.len == 0 or not dirExists(dir): return
  if not app.editorTab(dir, dir):
    app.addTab(@["vi", dir], dir)

proc checkConfigChanged(app: App) =
  ## Poll the config file (at most once a second) and reload when it changes.
  let now = getTicks()
  if now - app.configChecked < 1000: return
  app.configChecked = now
  if stamp(configFile(app.cli.configPath)) != app.configStamp:
    app.reloadConfig()

# --- recent folders -----------------------------------------------------------

proc stateDir(): string =
  let xdg = getEnv("XDG_STATE_HOME")
  (if xdg.isAbsolute: xdg else: getHomeDir() / ".local" / "state") / "ghostnim"

proc folderBarHiddenFlag(): string = stateDir() / "folder-bar-hidden"
  ## Exists while the recent-folders strip is turned off.

proc recentDirsFile(): string = stateDir() / "recent-folders"
  ## Shared by all ghostnim windows. One folder per line, most used first:
  ## "VISITS LAST-VISIT-MS PATH".

proc readRecentDirs(): seq[RecentDir] =
  try:
    for line in readFile(recentDirsFile()).splitLines:
      let parts = line.split(' ', maxsplit = 2)
      if parts.len < 3 or not parts[2].isAbsolute: continue
      result.add RecentDir(path: parts[2], visits: parseInt(parts[0]),
                           lastVisit: parseBiggestInt(parts[1]))
  except IOError, OSError, ValueError:
    discard

proc sortAndTrim(dirs: var seq[RecentDir]) =
  dirs.sort(proc (a, b: RecentDir): int =
    result = cmp(b.visits, a.visits)
    if result == 0: result = cmp(b.lastVisit, a.lastVisit))
  if dirs.len > keptRecentDirs:
    # Make room by dropping the least recently visited, not the least used,
    # so new folders get a chance to build up visits.
    var byAge = dirs
    byAge.sort(proc (a, b: RecentDir): int = cmp(b.lastVisit, a.lastVisit))
    let cutoff = byAge[keptRecentDirs - 1].lastVisit
    dirs.keepItIf(it.lastVisit >= cutoff)

proc recentDirsStamp(): times.Time =
  try: getLastModificationTime(recentDirsFile()) except OSError: times.Time()

proc syncRecentDirs(app: App) =
  ## Merge this window's new visits (and folders found gone) into the shared
  ## file, and pick up what other windows added to it.
  let pending = app.newVisits.len > 0 or app.goneDirs.len > 0
  if not pending and recentDirsStamp() == app.dirsStamp: return
  var lock: cint = -1
  if pending:
    try:
      createDir(stateDir())
      lock = posix.open(cstring(recentDirsFile() & ".lock"), O_RDWR or O_CREAT, 0o644)
      if lock >= 0: discard lockf(lock, F_LOCK, 0)
    except OSError:
      discard
  var dirs = readRecentDirs()
  for v in app.newVisits:
    block found:
      for d in dirs.mitems:
        if d.path == v.path:
          inc d.visits
          d.lastVisit = max(d.lastVisit, v.at)
          break found
      dirs.add RecentDir(path: v.path, visits: 1, lastVisit: v.at)
  for gone in app.goneDirs:
    dirs.keepItIf(it.path != gone)
  dirs.sortAndTrim()
  if pending:
    app.newVisits.setLen(0)
    app.goneDirs.setLen(0)
    var text = ""
    for d in dirs:
      text.add $d.visits & " " & $d.lastVisit & " " & d.path & "\n"
    let tmp = recentDirsFile() & "." & $getpid()
    try:
      writeFile(tmp, text)
      moveFile(tmp, recentDirsFile())
    except OSError, IOError:
      stderr.writeLine "ghostnim: can't save the recent folders: " &
                       getCurrentExceptionMsg().splitLines[0]
    if lock >= 0: discard posix.close(lock)
  app.dirsStamp = recentDirsStamp()
  app.dirs = dirs

proc trackDirs(app: App) =
  ## Note each tab's working directory (a few times a second at most),
  ## counting a visit whenever one moves, in the list all tabs and windows
  ## share.
  let now = getTicks()
  if now - app.dirsChecked < 250: return
  app.dirsChecked = now
  for tab in app.tabs:
    let dir = tab.pty.cwd
    if dir.len == 0 or dir == tab.lastDir: continue
    tab.lastDir = dir
    app.newVisits.add (dir, int64(epochTime() * 1000))
  app.syncRecentDirs()

proc recentDirs(app: App): seq[string] =
  ## The most used folders, not counting the one the current tab is in.
  let here = app.cur.pty.cwd
  for d in app.dirs:
    if result.len >= shownRecentDirs: break
    if d.path != here: result.add d.path

proc folderLabel(dir: string): string =
  if dir == getHomeDir().strip(leading = false, chars = {'/'}): "~"
  elif dir == "/": "/"
  else: dir.lastPathPart

proc folderLabels(app: App): seq[string] = app.recentDirs.map(folderLabel)

proc goToDir(app: App, dir: string, newTab = false) =
  ## cd the current tab's shell into `dir`, or, if a program is running in
  ## it (or `newTab`), open a new tab there.
  if not dirExists(dir):
    app.goneDirs.add dir
    app.syncRecentDirs()
    return
  if newTab or not app.cur.pty.atPrompt:
    app.addTab(dir = dir)
  else:
    app.sendInput("cd " & quoteShell(dir) & "\r")

proc toggleFolderBar(app: App) =
  let on = not app.rd.folderBar
  app.rd.setFolderBar(on)
  app.folderHover = -1
  app.applySize()
  try:
    if on: removeFile(folderBarHiddenFlag())
    else:
      createDir(stateDir())
      writeFile(folderBarHiddenFlag(), "")
  except OSError, IOError:
    stderr.writeLine "ghostnim: can't save the folder bar setting: " &
                     getCurrentExceptionMsg().splitLines[0]

# --- file manager pane ---------------------------------------------------------

proc filePaneFile(): string = stateDir() / "file-pane"
  ## "on WIDTH" or "off WIDTH", plus "hidden" when it lists dotfiles:
  ## whether the file pane is shown, how wide, and what it lists.

proc loadPaneState(app: App) =
  app.paneW = defaultPaneWidth
  try:
    let parts = readFile(filePaneFile()).splitWhitespace
    if parts.len >= 2:
      app.paneOn = parts[0] == "on"
      app.paneW = max(1, parseInt(parts[1]))
      app.pane.showHidden = "hidden" in parts[2 .. ^1]
  except IOError, OSError, ValueError:
    discard

proc savePaneState(app: App) =
  try:
    createDir(stateDir())
    writeFile(filePaneFile(), (if app.paneOn: "on " else: "off ") & $app.paneW &
                              (if app.pane.showHidden: " hidden" else: "") & "\n")
  except OSError, IOError:
    stderr.writeLine "ghostnim: can't save the file manager setting: " &
                     getCurrentExceptionMsg().splitLines[0]

proc syncPane(app: App) =
  ## Keep the pane on the current tab's directory, and its listing current.
  if not app.paneOn: return
  let tab = app.cur
  let cwd = tab.pty.cwd
  if tab.id != app.paneTab or (cwd.len > 0 and cwd != app.paneCwd):
    # A new tab, or its shell moved: follow it. Otherwise the pane stays
    # wherever it was browsed to.
    app.paneTab = tab.id
    app.paneCwd = cwd
    if cwd.len > 0: app.pane.load(cwd)
    elif app.pane.dir.len == 0: app.pane.load(getCurrentDir())   # no /proc
    app.paneChecked = getTicks()
    return
  let now = getTicks()
  if now - app.paneChecked < 500: return
  app.paneChecked = now
  app.pane.refresh()

proc focusPane(app: App, on: bool) =
  ## Give the keyboard to the file pane, or back to the terminal (whose
  ## cursor then shows it has focus again).
  let on = on and app.paneOn
  if on == app.paneFocused: return
  app.paneFocused = on
  app.typeAhead = ""
  app.pane.filtering = false    # the filter stays, but typing no longer edits it
  app.rd.focused = app.windowFocused and not on
  app.needsFull = true

proc toggleFilePane(app: App, focusFirst = false) =
  ## Show the file pane and focus it, or hide it. With `focusFirst` (the
  ## shortcut), a pane that's shown but not focused gets focused instead.
  if focusFirst and app.paneOn and not app.paneFocused:
    app.focusPane(true)
    return
  app.paneOn = not app.paneOn
  app.paneTab = -1
  app.pane.hovered = -1
  app.applySize()
  app.savePaneState()
  app.syncPane()             # list the folder now, for the keyboard
  app.focusPane(app.paneOn)

proc paneOpenDir(app: App, dir: string) =
  ## Show `dir` in the pane, and cd the shell there when it's at its prompt.
  if not dirExists(dir):
    app.pane.refresh()
    return
  if app.cur.pty.atPrompt:
    app.sendInput("cd " & quoteShell(dir) & "\r")
  app.pane.load(dir)

proc toggleHiddenFiles(app: App) =
  ## List dotfiles in the file pane, or stop listing them.
  let (_, h) = app.outputSize()
  app.pane.setShowHidden(not app.pane.showHidden)
  if app.pane.selected >= 0: app.pane.select(app.pane.selected, app.rd.visibleRows(h))
  app.pane.scrollBy(app.rd, 0, h)   # keep the list's end at the bottom
  app.savePaneState()

proc paneRows(app: App): int = app.rd.visibleRows(app.outputSize()[1])

proc paneOpen(app: App) =
  ## Enter on the selected entry: go into a folder, open a file.
  let i = app.pane.selected
  if i < 0: return
  let path = app.pane.path(i)
  if app.pane.entries[i].isDir:
    let parent = app.pane.entries[i].name == ".."
    let came = app.pane.dir.lastPathPart
    app.paneOpenDir(path)
    app.pane.selectName(if parent: came else: "", app.paneRows)
  else:
    openExternal(path)

proc paneUp(app: App) =
  ## Go to the parent folder, with the one we were in selected.
  if app.pane.dir.len == 0 or app.pane.dir == "/": return
  let came = app.pane.dir.lastPathPart
  app.paneOpenDir(app.pane.dir.parentDir)
  app.pane.selectName(came, app.paneRows)

proc paneFilter(app: App, filter: string) =
  ## Show only the entries whose names contain `filter`.
  app.pane.setFilter(filter)
  if app.pane.selected >= 0: app.pane.select(app.pane.selected, app.paneRows)

proc paneKey(app: App, e: KeyboardEvent) =
  ## Keyboard handling while the file pane has focus; nothing reaches the
  ## terminal. Printable keys come back through SDL_TEXTINPUT as type-ahead,
  ## or into the filter while it's being typed.
  app.hasPendingKey = false
  app.suppressText = false
  let rows = app.paneRows
  let shift = (e.keysym.`mod` and KMOD_SHIFT) != 0
  let ctrl = (e.keysym.`mod` and KMOD_CTRL) != 0
  let sel = app.pane.selected
  let key = toGhosttyKey(e.keysym.scancode)
  if app.pane.filtering:
    case key
    of gkBackspace:
      # Delete the last character; on an empty filter, stop filtering.
      if app.pane.filter.len == 0: app.pane.filtering = false
      else: app.paneFilter(app.pane.filter.runeSubStr(0, app.pane.filter.runeLen - 1))
      return
    of gkEscape:
      app.pane.filtering = false
      app.paneFilter("")
      return
    of gkEnter, gkNumpadEnter:
      app.pane.filtering = false   # then open the selected entry, as below
    of gkArrowLeft, gkArrowRight:
      return                       # don't leave the folder while typing
    else: discard
  case key
  of gkArrowDown: app.pane.select(sel + 1, rows)
  of gkArrowUp: app.pane.select(if sel < 0: 0 else: sel - 1, rows)
  of gkPageDown: app.pane.select(sel + max(1, rows - 1), rows)
  of gkPageUp: app.pane.select(sel - max(1, rows - 1), rows)
  of gkHome: app.pane.select(0, rows)
  of gkEnd: app.pane.select(app.pane.entries.len - 1, rows)
  of gkEnter, gkNumpadEnter:
    if shift and sel >= 0:
      # Type the path into the terminal and go back to it.
      app.sendInput(quoteShell(app.pane.path(sel)) & " ")
      app.focusPane(false)
    else:
      app.paneOpen()
  of gkArrowRight:
    if sel >= 0 and app.pane.entries[sel].isDir: app.paneOpen()
  of gkArrowLeft, gkBackspace: app.paneUp()
  of gkEscape:
    if app.pane.filter.len > 0: app.paneFilter("")   # clear the filter first
    else: app.focusPane(false)
  of gkH:
    if not ctrl: return            # type-ahead
    app.toggleHiddenFiles()
  of gkF:
    if not ctrl: return            # type-ahead
    app.pane.filtering = true
  else: return
  app.typeAhead = ""

proc paneTypeAhead(app: App, text: string) =
  ## Letters typed into the focused pane select the entry they start, or go
  ## into the filter while it's being typed; "/" starts typing one.
  if app.pane.filtering:
    app.paneFilter(app.pane.filter & text)
    return
  if text == "/":
    app.pane.filtering = true
    app.typeAhead = ""
    return
  if text.strip.len == 0: return
  let now = getTicks()
  if now - app.typeAheadAt > 1000: app.typeAhead = ""
  app.typeAheadAt = now
  app.typeAhead.add text
  app.pane.jumpTo(app.typeAhead, app.paneRows)

proc onPaneClick(app: App, button, clicks: uint8, x, y: int) =
  let (_, h) = app.outputSize()
  app.focusPane(true)
  let i = app.pane.entryAt(app.rd, x, y, h)
  if i < 0: return
  let path = app.pane.path(i)
  let isDir = app.pane.entries[i].isDir
  case button
  of BUTTON_LEFT:
    app.pane.selected = i
    if isDir: app.paneOpenDir(path)
    elif clicks >= 2: openExternal(path)
  of BUTTON_MIDDLE:
    if isDir and dirExists(path): app.addTab(dir = path)
    elif not isDir: app.sendInput(quoteShell(path) & " ")
  else: discard

proc dragDivider(app: App, x: int32) =
  ## Resize the pane to end at window x coordinate `x`.
  let (w, _) = app.outputSize()
  let old = app.rd.left
  app.paneW = max(1, x.int)
  let px = app.paneWidth(w)
  app.paneW = int(px.float / app.rd.scale + 0.5)   # stay within the limits
  if px != old: app.applySize()

# --- context menu -----------------------------------------------------------

proc runMenuAction(app: App, action: MenuAction) =
  if action == maNone: return
  app.menu.close()
  case action
  of maCopy: app.copySelection()
  of maPaste: app.paste()
  of maSelectAll: app.selectAllText()
  of maZoomIn: app.zoom(app.rd.fontSize + 1)
  of maZoomOut: app.zoom(app.rd.fontSize - 1)
  of maZoomReset: app.zoom(app.opts.size)
  of maOpenConfig: app.openConfig()
  of maOpenFolderInEditor: app.openFolderInEditor()
  of maToggleFolderBar: app.toggleFolderBar()
  of maToggleFilePane: app.toggleFilePane()
  of maToggleHiddenFiles: app.toggleHiddenFiles()
  of maFilterFiles:
    app.focusPane(true)
    app.pane.filtering = true
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

proc runAction(app: App, b: Binding) =
  case b.action
  of acNone: discard
  of acCopy: app.copySelection()
  of acPaste: app.paste()
  of acSelectAll: app.selectAllText()
  of acNewTab: app.addTab()
  of acCloseTab: app.closeTab(app.active)
  of acNextTab: app.cycleTab(1)
  of acPreviousTab: app.cycleTab(-1)
  of acGotoTab:
    if b.num <= app.tabs.len: app.activate(b.num - 1)
  of acScrollPageUp, acScrollPageDown:
    var rows: uint16
    discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_ROWS, addr rows)
    let d = max(1, rows.int div 2)
    app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA,
                       if b.action == acScrollPageUp: -d else: d)
  of acScrollToTop: app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_TOP)
  of acScrollToBottom: app.scrollViewport(GHOSTTY_SCROLL_VIEWPORT_BOTTOM)
  of acFontBigger: app.zoom(app.rd.fontSize + 1)
  of acFontSmaller: app.zoom(app.rd.fontSize - 1)
  of acFontReset: app.zoom(app.opts.size)
  of acSendText: app.sendInput(b.text)
  of acReloadConfig: app.reloadConfig()
  of acOpenConfig: app.openConfig()
  of acOpenFolderInEditor: app.openFolderInEditor()
  of acToggleFilePane: app.toggleFilePane(focusFirst = true)
  of acToggleHiddenFiles: app.toggleHiddenFiles()

proc handleShortcut(app: App, scancode: cint, mods: uint16): bool =
  ## Keybindings from the config (or the defaults). True if the key was used.
  var chord = Chord(key: toGhosttyKey(scancode))
  if (mods and KMOD_CTRL) != 0: chord.mods.incl mCtrl
  if (mods and KMOD_SHIFT) != 0: chord.mods.incl mShift
  if (mods and KMOD_ALT) != 0: chord.mods.incl mAlt
  if (mods and KMOD_GUI) != 0: chord.mods.incl mSuper
  let b = app.opts.keybinds.getOrDefault(chord)
  if b.action == acNone: return false
  app.runAction(b)
  true

proc onKeyDown(app: App, e: KeyboardEvent) =
  let sym = e.keysym.sym
  let smods = e.keysym.`mod`
  if app.menu.open:
    app.menuKey(e)
    return
  if app.handleShortcut(e.keysym.scancode, smods):
    # A binding like shift+a or alt+1 would also type its character.
    app.hasPendingKey = false
    app.suppressText = producesText(sym, smods)
    return
  if app.paneFocused:
    app.paneKey(e)
    return
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
  if app.menu.open or app.paneFocused: return
  app.encodeKey(toGhosttyKey(e.keysym.scancode), GHOSTTY_KEY_ACTION_RELEASE,
                toGhosttyMods(e.keysym.`mod`), unshiftedCodepoint(e.keysym.sym), "")

proc onTextInput(app: App, e: TextInputEvent) =
  var text = $cast[cstring](unsafeAddr e.text[0])
  if app.suppressText:
    app.suppressText = false
    return
  if app.menu.open: return
  if app.paneFocused:
    app.paneTypeAhead(text)
    return
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
  let c = clamp(int((px - float(app.rd.left + app.rd.pad)) / app.rd.cellW.float), 0,
                max(0, cols.int - 1))
  let r = clamp(int((py - float(app.rd.top + app.rd.pad)) / app.rd.cellH.float), 0,
                max(0, rows.int - 1))
  (c, r)

proc inTabBar(app: App, y: int32): bool =
  float(y) * app.rd.scale < app.rd.top.float

proc cellText(r: var GhosttyGridRef): string =
  ## The cell's text for link detection: " " when blank, "" for the right
  ## half of a wide character.
  var cell: GhosttyCell
  var wide: cint
  if ghostty_grid_ref_cell(addr r, addr cell) == GHOSTTY_SUCCESS and
     ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, addr wide) == GHOSTTY_SUCCESS and
     wide == GHOSTTY_CELL_WIDE_SPACER_TAIL:
    return ""
  var cps: array[16, uint32]
  var n: csize_t
  if ghostty_grid_ref_graphemes(addr r, addr cps[0], csize_t(cps.len), addr n) != GHOSTTY_SUCCESS or
     n == 0:
    return " "
  for i in 0 ..< n.int: result.add codepointToUtf8(cps[i])

proc rowWraps(app: App, row: int): bool =
  ## Whether viewport row `row` soft-wraps onto the next one.
  var (ok, r) = app.gridRef(0, row)
  var gr: GhosttyRow
  var wraps: bool
  ok and ghostty_grid_ref_row(addr r, addr gr) == GHOSTTY_SUCCESS and
    ghostty_row_get(gr, GHOSTTY_ROW_DATA_WRAP, addr wraps) == GHOSTTY_SUCCESS and wraps

proc lineAt(app: App, row: int): tuple[first, last, cols: int, cells: seq[string]] =
  ## The (soft-wrapped) line through viewport row `row`: its first and last
  ## rows, and the text of each of its cells (see cellText).
  var cols, rows: uint16
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_COLS, addr cols)
  discard ghostty_terminal_get(app.cur.term, GHOSTTY_TERMINAL_DATA_ROWS, addr rows)
  result.cols = cols.int
  result.first = row
  while result.first > 0 and app.rowWraps(result.first - 1): dec result.first
  result.last = row
  while result.last < rows.int - 1 and app.rowWraps(result.last): inc result.last
  for y in result.first .. result.last:
    for x in 0 ..< cols.int:
      var (okc, rc) = app.gridRef(x, y)
      result.cells.add(if okc: cellText(rc) else: " ")

proc linkAt(app: App, col, row: int): string =
  ## The link under viewport cell (col, row): its OSC 8 hyperlink if it has
  ## one, else a URL found in the text of its (soft-wrapped) line.
  var (ok, r) = app.gridRef(col, row)
  if not ok: return ""
  var n: csize_t
  if ghostty_grid_ref_hyperlink_uri(addr r, nil, 0, addr n) == GHOSTTY_OUT_OF_SPACE and n > 0:
    result = newString(n.int)
    if ghostty_grid_ref_hyperlink_uri(addr r, cast[ptr uint8](addr result[0]), n,
                                      addr n) != GHOSTTY_SUCCESS:
      result = ""
    else:
      result.setLen(n.int)
    return
  let line = app.lineAt(row)
  result = urlAt(line.cells, (row - line.first) * line.cols + col)

proc pathAt(app: App, col, row: int): string =
  ## The existing file or directory named by the word under viewport cell
  ## (col, row), relative to the tab's directory, or "".
  let line = app.lineAt(row)
  let i = (row - line.first) * line.cols + col
  if i notin 0 ..< line.cells.len or line.cells[i] == " ": return ""
  let (a, b) = wordAt(line.cells, i)
  pathTarget(line.cells[a .. b].join, app.cur.pty.cwd)

proc openPath(app: App, path: string) =
  ## Ctrl+click on a path: a directory opens in a new tab; a file opens in
  ## $VISUAL/$EDITOR in a new tab in its directory, or with the desktop's
  ## handler without either.
  if dirExists(path):
    app.addTab(dir = path)
    return
  if not app.editorTab(path, path.parentDir):
    openExternal(path)

# --- mouse selection ----------------------------------------------------------

proc before(a, b: (int, int)): bool =
  ## Whether viewport cell `a` comes before `b` in reading order.
  a[1] < b[1] or (a[1] == b[1] and a[0] < b[0])

proc unitAt(app: App, cell: (int, int)): ((int, int), (int, int)) =
  ## The first and last cell of the word or line (per `selUnit`) at `cell`.
  let line = app.lineAt(cell[1])
  let cols = max(1, line.cols)
  template at(i: int): (int, int) = (i mod cols, line.first + i div cols)
  case app.selUnit
  of suCell: (cell, cell)
  of suLine: ((0, line.first), (cols - 1, line.last))
  of suWord:
    let (a, b) = wordAt(line.cells, (cell[1] - line.first) * cols + cell[0])
    (at(a), at(b))

proc startSelection(app: App, cell: (int, int), clicks: uint8) =
  ## A left press: one click starts a cell selection, two select the word
  ## under the pointer, three the line.
  app.selecting = true
  app.selAnchor = cell
  app.selUnit = case clicks
                of 0, 1: suCell
                of 2: suWord
                else: suLine
  if app.selUnit == suCell:
    app.clearSelection()
    return
  (app.selAnchorStart, app.selAnchorEnd) = app.unitAt(cell)
  app.setSelection(app.selAnchorStart, app.selAnchorEnd)

proc extendSelection(app: App, cell: (int, int)) =
  ## A drag: select from the anchor to `cell`, by whole words or lines after
  ## a double or triple click.
  if app.selUnit == suCell:
    app.setSelection(app.selAnchor, cell)
    return
  let (a, b) = app.unitAt(cell)
  if a.before(app.selAnchorStart): app.setSelection(a, app.selAnchorEnd)
  else: app.setSelection(app.selAnchorStart, if b.before(app.selAnchorEnd): app.selAnchorEnd else: b)

proc finishSelection(app: App) =
  ## The button went up: copy what was selected, with copy-on-select.
  app.selecting = false
  if app.opts.copyOnSelect and app.hasSelection(): app.copySelection()

proc linkModifier(): bool =
  ## Ctrl (or Cmd/Super) held: clicks open links.
  (getModState() and (KMOD_CTRL or KMOD_GUI)) != 0

proc updateLinkCursor(app: App) =
  ## Show a hand while Ctrl is held over a link or path, and over a recent
  ## folder or a file pane entry; a resize arrow over the file pane's divider.
  if app.tabs.len == 0: return   # the last tab just closed
  var x, y: cint
  discard getMouseState(addr x, addr y)
  let (px, py) = app.pixelPos(x, y)
  var want = app.arrowCursor
  if app.resizingPane:
    want = app.resizeCursor
  elif not app.menu.open and not app.selecting and app.ownButtons.len == 0:
    if app.inTabBar(y):
      if app.rd.hitFolderBar(app.folderLabels, px.int, py.int) >= 0: want = app.handCursor
    elif app.rd.onDivider(px.int, py.int):
      want = app.resizeCursor
    elif app.rd.contains(px.int, py.int):
      if app.pane.hovered >= 0: want = app.handCursor
    elif linkModifier():
      let (c, r) = app.cellAt(x, y)
      if app.linkAt(c, r).len > 0 or app.pathAt(c, r).len > 0: want = app.handCursor
  if want != app.shownCursor:
    app.shownCursor = want
    setCursor(want)

proc onTabBarClick(app: App, button, clicks: uint8, x, y: int32) =
  let (px, py) = app.pixelPos(x, y)
  if py.int >= app.rd.tabH:
    # The recent-folders strip: click to go there, middle-click for a new tab.
    let i = app.rd.hitFolderBar(app.folderLabels, px.int, py.int)
    if i >= 0 and button in {BUTTON_LEFT, BUTTON_MIDDLE}:
      app.goToDir(app.recentDirs[i], newTab = button == BUTTON_MIDDLE)
    return
  let hit = app.rd.hitTabBar(app.tabs.len, px.int, py.int)
  case hit.kind
  of hitTab:
    if button == BUTTON_LEFT: app.activate(hit.index)
    elif button == BUTTON_MIDDLE: app.closeTab(hit.index)
  of hitClose:
    if button in {BUTTON_LEFT, BUTTON_MIDDLE}: app.closeTab(hit.index)
  of hitNew:
    if button == BUTTON_LEFT: app.addTab()
  of hitNone:
    # Double-clicking the empty bar space opens a new tab.
    if button == BUTTON_LEFT and clicks == 2: app.addTab()

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
  let kb = app.opts.keybinds
  var paneItems: seq[MenuItem]
  if app.paneOn:
    let hiddenKey = kb.shortcutLabel(acToggleHiddenFiles)
    paneItems.add item(if app.pane.showHidden: "Hide Hidden Files" else: "Show Hidden Files",
                       maToggleHiddenFiles, if hiddenKey.len > 0: hiddenKey else: "Ctrl+H")
    paneItems.add item("Filter Files", maFilterFiles, "Ctrl+F")
  app.menu.show(app.rd, @[
    item("Copy", maCopy, kb.shortcutLabel(acCopy), app.hasSelection()),
    item("Paste", maPaste, kb.shortcutLabel(acPaste), hasClipboardText() != 0),
    item("Select All", maSelectAll, kb.shortcutLabel(acSelectAll)),
    separator(),
    item("Zoom In", maZoomIn, kb.shortcutLabel(acFontBigger)),
    item("Zoom Out", maZoomOut, kb.shortcutLabel(acFontSmaller)),
    item("Reset Zoom", maZoomReset, kb.shortcutLabel(acFontReset)),
    separator(),
    item(if app.rd.folderBar: "Hide Recent Folders" else: "Show Recent Folders",
         maToggleFolderBar),
    item(if app.paneOn: "Hide File Manager" else: "Show File Manager",
         maToggleFilePane, kb.shortcutLabel(acToggleFilePane))] & paneItems & @[
    item("Open Folder in Editor", maOpenFolderInEditor,
         kb.shortcutLabel(acOpenFolderInEditor)),
    item("Open Config", maOpenConfig, kb.shortcutLabel(acOpenConfig)),
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
  if down and not app.menu.open and app.mouseButtons.len == 0:
    if app.inTabBar(e.y):
      app.ownButtons.incl e.button
      app.onTabBarClick(e.button, e.clicks, e.x, e.y)
      return
    let (px, py) = app.pixelPos(e.x, e.y)
    if e.button == BUTTON_LEFT and app.rd.onDivider(px.int, py.int):
      app.ownButtons.incl e.button
      app.resizingPane = true
      return
    if app.rd.contains(px.int, py.int):
      if e.button == BUTTON_RIGHT:
        # The usual menu, whatever the terminal does with the mouse.
        app.mouseButtons.incl e.button
        app.openMenu(e.x, e.y)
      else:
        app.ownButtons.incl e.button
        app.onPaneClick(e.button, e.clicks, px.int, py.int)
      return
    app.focusPane(false)     # a click in the terminal gives it the keyboard back
    if e.button == BUTTON_LEFT and linkModifier():
      # Ctrl+click on a link opens it, even when the app reports the mouse.
      # A directory (a file:// link to one, or a path in the text) opens in
      # a new tab instead.
      let (c, r) = app.cellAt(e.x, e.y)
      let link = app.linkAt(c, r)
      if link.len > 0 and not link.startsWith("-"):
        app.ownButtons.incl e.button
        let dir = fileUrlPath(link)
        if dir.len > 0 and dirExists(dir): app.addTab(dir = dir)
        else: openExternal(link)
        return
      let path = app.pathAt(c, r)
      if path.len > 0:
        app.ownButtons.incl e.button
        app.openPath(path)
        return
  if not down and e.button in app.ownButtons:
    app.ownButtons.excl e.button
    if e.button == BUTTON_LEFT and app.resizingPane:
      app.resizingPane = false
      app.savePaneState()
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
    if down: app.startSelection(app.cellAt(e.x, e.y), e.clicks)
    elif app.selecting: app.finishSelection()
  elif e.button == BUTTON_MIDDLE and down:
    app.paste()
  elif e.button == BUTTON_RIGHT and down:
    app.openMenu(e.x, e.y)

proc onMouseMotion(app: App, e: MouseMotionEvent) =
  if app.resizingPane: app.dragDivider(e.x)
  let (mx, my) = app.pixelPos(e.x, e.y)
  let idle = not app.menu.open and app.mouseButtons.len == 0 and app.ownButtons.len == 0
  app.folderHover = if idle: app.rd.hitFolderBar(app.folderLabels, mx.int, my.int) else: -1
  let (_, h) = app.outputSize()
  app.pane.hovered = if idle: app.pane.entryAt(app.rd, mx.int, my.int, h) else: -1
  app.updateLinkCursor()
  if app.resizingPane: return
  if app.menu.open:
    let (px, py) = app.pixelPos(e.x, e.y)
    app.menu.motion(app.rd, int(px), int(py))
  elif app.reportMouse():
    if app.mouseButtons.len == 0 and (app.inTabBar(e.y) or app.rd.contains(mx.int, my.int)):
      return
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
    app.extendSelection(app.cellAt(e.x, e.y))

proc onMouseWheel(app: App, e: MouseWheelEvent) =
  var dy = e.y
  if e.direction == MOUSEWHEEL_FLIPPED: dy = -dy
  if dy == 0: return
  if app.menu.open:
    app.menu.close()
    return
  var x, y: cint
  discard getMouseState(addr x, addr y)
  let (px, py) = app.pixelPos(x, y)
  if app.inTabBar(y):
    app.cycleTab(if dy > 0: -1 else: 1)
  elif app.rd.contains(px.int, py.int):
    let (_, h) = app.outputSize()
    app.pane.scrollBy(app.rd, -3 * dy, h)
    app.pane.hovered = app.pane.entryAt(app.rd, px.int, py.int, h)
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
    app.updateLinkCursor()      # Ctrl pressed over a link
  elif t == EV_KEYUP:
    app.onKeyUp(e.key)
    app.updateLinkCursor()
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
    app.updateLinkCursor()      # other text under the pointer now
  elif t == EV_WINDOW:
    case e.window.event
    of WINDOWEVENT_SIZE_CHANGED:
      app.menu.close()
      app.applySize()
    of WINDOWEVENT_EXPOSED: app.needsFull = true
    of WINDOWEVENT_LEAVE:
      app.folderHover = -1
      app.pane.hovered = -1
    of WINDOWEVENT_FOCUS_GAINED, WINDOWEVENT_FOCUS_LOST:
      if e.window.event == WINDOWEVENT_FOCUS_LOST: app.menu.close()
      app.windowFocused = e.window.event == WINDOWEVENT_FOCUS_GAINED
      app.rd.focused = app.windowFocused and not app.paneFocused
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

# Window icon, embedded so it works without any installed files.
let iconBmp = static(staticRead("../packaging/ghostnim-128.bmp"))

proc setIcon(window: WindowPtr) =
  let icon = loadBMP_RW(rwFromConstMem(unsafeAddr iconBmp[0], cint(iconBmp.len)), 1)
  if icon == nil: return
  setWindowIcon(window, icon)
  freeSurface(icon)

proc main() =
  let cli = parseCli()
  let cfgStamp = stamp(configFile(cli.configPath))
  let opts = merge(loadConfig(cli.configPath), cli)
  # Before SDL starts any threads, since this forks.
  if opts.screenshot.len == 0: startUpdateCheck()
  discard setHint("SDL_IM_MODULE", "")   # let the platform pick its IME
  if sdl.init(INIT_VIDEO or INIT_EVENTS) != 0:
    quit("ghostnim: SDL_Init failed: " & $getError(), 1)
  defer: sdl.quit()
  if ttfInit() != 0:
    quit("ghostnim: TTF_Init failed: " & $getError(), 1)
  defer: ttfQuit()

  let app = App(opts: opts, cli: cli, configStamp: cfgStamp, running: true,
                needsFull: true, folderHover: -1, pane: initFilePane(), paneTab: -1,
                windowFocused: true)
  app.loadPaneState()
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
  app.applySelectionColors()
  app.rd.setFolderBar(not fileExists(folderBarHiddenFlag()))
  app.syncRecentDirs()
  let paneW = if app.paneOn: max(12 * app.rd.cellW, int(app.paneW.float * scale + 0.5)) else: 0
  let winW = (opts.cols * app.rd.cellW + 2 * app.rd.pad + paneW).float / scale
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
  app.arrowCursor = createSystemCursor(SYSTEM_CURSOR_ARROW)
  app.handCursor = createSystemCursor(SYSTEM_CURSOR_HAND)
  app.resizeCursor = createSystemCursor(SYSTEM_CURSOR_SIZEWE)
  app.shownCursor = app.arrowCursor

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
    if opts.screenshot.len == 0: app.checkConfigChanged()
    app.trackDirs()
    app.syncPane()
    app.rd.draw(app.cur.state, app.cur.term, app.needsFull, blinkOn)
    app.pane.draw(app.rd, app.outputSize()[1], app.paneFocused and app.windowFocused)
    app.rd.drawTabBar(app.tabs.mapIt(it.title), app.active)
    app.rd.drawFolderBar(app.folderLabels, app.folderHover)
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
  freeCursor(app.handCursor)
  freeCursor(app.resizeCursor)
  freeCursor(app.arrowCursor)
  app.rd.destroy()
  destroyRenderer(r)
  destroyWindow(app.window)

when isMainModule:
  main()
