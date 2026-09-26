## The config file, in KDL: `$XDG_CONFIG_HOME/ghostnim/config.kdl` (or
## `~/.config/ghostnim/config.kdl`). Each setting is a node named after the
## matching command-line option; the command line wins over the file.
##
##   font "JetBrains Mono"
##   font-size 13
##   cols 120
##   rows 36
##   scrollback 50000
##   command "fish" "--login"
##   working-directory "~/code"
##   inherit-directory #false   // new tabs start in working-directory too
##
## Colours go in a `colors` block, as "#rrggbb" or "#rgb":
##
##   colors {
##     foreground "#c0caf5"
##     background "#1a1b26"
##     cursor "#c0caf5"
##     selection-foreground "#c0caf5"
##     selection-background "#33467c"
##     palette 0 "#15161e"      // one node per 256-colour palette entry
##     palette 1 "#f7768e"
##   }
##
## Shortcuts go in a `keybinds` block, one `CHORD ACTION [ARG]` per line; see
## keybinds.nim for the names. They add to (or replace) the defaults, unless
## the block says `clear-defaults=#true`:
##
##   keybinds {
##     alt+1 goto-tab 1
##     ctrl+shift+enter send-text "\n"
##     ctrl+shift+w none          // unbind
##     "ctrl+=" font-bigger       // quote chords with = / ; [ ] ( ) { } \ "
##   }

import std/[os, strutils, options, times]
export options
import kdl, keybinds

type
  ConfigRgb* = tuple[r, g, b: uint8]

  Colors* = object
    ## Unset colours keep libghostty's (or, for selection, ghostnim's) defaults.
    foreground*, background*, cursor*: Option[ConfigRgb]
    selectionForeground*, selectionBackground*: Option[ConfigRgb]
    palette*: seq[(int, ConfigRgb)]   ## palette index overrides, in order

  Config* = object
    font*: string
    size*: int
    cols*, rows*: int
    scrollback*: int
    command*: seq[string]
    workingDirectory*: string   ## where the first tab starts; "" = inherit
    inheritDirectory*: bool     ## new tabs start in the current tab's directory
    colors*: Colors
    keybinds*: Keybinds

proc defaultConfig*(): Config =
  Config(size: 14, cols: 100, rows: 30, scrollback: 10_000,
         inheritDirectory: true, keybinds: defaultKeybinds())

proc configPath*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg.isAbsolute: xdg else: getHomeDir() / ".config"
  base / "ghostnim" / "config.kdl"

proc warn(path: string, line: int, msg: string) =
  stderr.writeLine "ghostnim: " & path & ":" & $line & ": " & msg

proc parseColor*(s: string): Option[ConfigRgb] =
  ## "#rrggbb" or "#rgb" (the leading # is optional).
  let h = if s.startsWith('#'): s[1 .. ^1] else: s
  if h.len notin [3, 6] or not h.allCharsInSet(HexDigits): return
  let full = if h.len == 3: h[0] & h[0] & h[1] & h[1] & h[2] & h[2] else: h
  some((fromHex[uint8](full[0 .. 1]), fromHex[uint8](full[2 .. 3]),
        fromHex[uint8](full[4 .. 5])))

proc parseColors(c: var Colors, nodes: seq[KdlNode], path: string) =
  for n in nodes:
    template bad(msg: string) =
      warn(path, n.line, "colors: " & n.name & ": " & msg)
      continue
    proc color(v: KdlVal): Option[ConfigRgb] =
      if v.kind == kString: parseColor(v.str) else: none(ConfigRgb)
    const colorHint = "expected a colour like \"#1a1b26\", got "
    if n.props.len != 0 or n.children.len != 0: bad("unexpected properties or block")
    if n.name == "palette":
      if n.args.len != 2 or n.args[0].kind != kInt:
        bad("expected an index and a colour, like: palette 1 \"#f7768e\"")
      let i = n.args[0].num
      if i < 0 or i > 255: bad("index must be between 0 and 255")
      let col = color(n.args[1])
      if col.isNone: bad(colorHint & $n.args[1])
      c.palette.add (i.int, col.get)
      continue
    if n.args.len != 1: bad("expected exactly one colour")
    let col = color(n.args[0])
    if col.isNone: bad(colorHint & $n.args[0])
    case n.name
    of "foreground": c.foreground = col
    of "background": c.background = col
    of "cursor": c.cursor = col
    of "selection-foreground": c.selectionForeground = col
    of "selection-background": c.selectionBackground = col
    else: bad("unknown colour")

proc parseKeybinds(kb: var Keybinds, n: KdlNode, path: string) =
  if n.args.len != 0: warn(path, n.line, "keybinds: expected a { ... } block")
  for (k, v) in n.props:
    if k == "clear-defaults" and v.kind == kBool:
      if v.bval: kb.clear()
    else: warn(path, n.line, "keybinds: unknown property " & k)
  for b in n.children:
    template bad(msg: string) =
      warn(path, b.line, "keybinds: " & b.name & ": " & msg)
      continue
    let (okChord, chord) = parseChord(b.name)
    if not okChord: bad("not a key chord like ctrl+shift+t")
    if b.args.len == 0 or b.args[0].kind != kString: bad("expected an action")
    let (okAction, action) = parseAction(b.args[0].str)
    if not okAction: bad("unknown action " & $b.args[0])
    var binding = Binding(action: action)
    let rest = b.args[1 .. ^1]
    case action
    of acGotoTab:
      if rest.len != 1 or rest[0].kind != kInt or rest[0].num < 1:
        bad("expected a tab number, like: goto-tab 1")
      binding.num = rest[0].num.int
    of acSendText:
      if rest.len != 1 or rest[0].kind != kString:
        bad("expected the text to send, like: send-text \"\\n\"")
      binding.text = rest[0].str
    else:
      if rest.len != 0: bad($action & " takes no arguments")
    if action == acNone: kb.del chord
    else: kb[chord] = binding

proc parseConfig*(text: string, path = "config.kdl", ok: var bool): Config =
  ## Apply the settings in `text` over the defaults. Problems are reported on
  ## stderr and skipped, so a typo never keeps the terminal from starting.
  ## `ok` is false if the file isn't valid KDL at all (and nothing applied).
  result = defaultConfig()
  ok = true
  var nodes: seq[KdlNode]
  try:
    nodes = parseKdl(text)
  except KdlError as e:
    warn(path, e.line, e.msg.split(": ", 1)[^1] & "; ignoring the config file")
    ok = false
    return

  for n in nodes:
    template bad(msg: string) =
      warn(path, n.line, n.name & ": " & msg)
      continue
    template oneArg(): KdlVal =
      if n.args.len != 1 or n.props.len != 0 or n.children.len != 0:
        bad("expected exactly one value")
      n.args[0]
    template strArg(): string =
      let v = oneArg()
      if v.kind != kString: bad("expected a string, got " & $v)
      v.str
    template intArg(lo, hi: int): int =
      let v = oneArg()
      if v.kind != kInt: bad("expected a whole number, got " & $v)
      if v.num < lo or v.num > hi: bad("must be between " & $lo & " and " & $hi)
      v.num.int
    template boolArg(): bool =
      let v = oneArg()
      if v.kind != kBool: bad("expected #true or #false, got " & $v)
      v.bval

    case n.name
    of "font": result.font = strArg()
    of "font-size": result.size = intArg(4, 200)
    of "cols": result.cols = intArg(10, 1000)
    of "rows": result.rows = intArg(2, 1000)
    of "scrollback": result.scrollback = intArg(0, 10_000_000)
    of "command":
      if n.args.len == 0 or n.props.len != 0 or n.children.len != 0:
        bad("expected the program and its arguments")
      var cmd: seq[string]
      for a in n.args:
        if a.kind == kString: cmd.add a.str
      if cmd.len != n.args.len: bad("expected strings")
      result.command = cmd
    of "working-directory":
      let dir = expandTilde(strArg())
      if not dirExists(dir): bad("no such directory: " & dir)
      result.workingDirectory = dir
    of "inherit-directory": result.inheritDirectory = boolArg()
    of "keybinds": result.keybinds.parseKeybinds(n, path)
    of "colors":
      if n.args.len != 0 or n.props.len != 0:
        bad("expected a { ... } block of colours")
      result.colors.parseColors(n.children, path)
    else:
      bad("unknown setting")

proc parseConfig*(text: string, path = "config.kdl"): Config =
  var ok: bool
  parseConfig(text, path, ok)

const defaultConfigText* = staticRead("../../docs/config.kdl")
  ## Written out by "Open Config" when there's no config file yet.

proc ensureConfigFile*(path: string): bool =
  ## Create `path` from the commented defaults if it doesn't exist. False if
  ## it couldn't be created.
  if fileExists(path): return true
  try:
    createDir(path.parentDir)
    writeFile(path, defaultConfigText)
    true
  except OSError, IOError:
    warn(path, 0, "could not create: " & getCurrentExceptionMsg().splitLines[0])
    false

proc configFile*(path = ""): string =
  ## The file to read: `path` if given, else the default location.
  if path.len > 0: path else: configPath()

proc loadConfig*(path = ""): Config =
  ## Read the config file at `path`, or the default location. A missing file
  ## at the default location is fine; a missing explicit one is an error.
  let p = configFile(path)
  if not fileExists(p):
    if path.len > 0: quit("ghostnim: config file not found: " & path, 2)
    return defaultConfig()
  try:
    parseConfig(readFile(p), p)
  except IOError as e:
    warn(p, 0, e.msg)
    defaultConfig()

proc reloadConfig*(path = ""): Option[Config] =
  ## Like loadConfig, for a reload: none() if the file can't be read or isn't
  ## valid KDL, so a half-saved file doesn't reset everything to defaults.
  ## A deleted file means the defaults.
  let p = configFile(path)
  if not fileExists(p): return some(defaultConfig())
  try:
    var ok: bool
    let cfg = parseConfig(readFile(p), p, ok)
    if ok: some(cfg) else: none(Config)
  except IOError as e:
    warn(p, 0, e.msg)
    none(Config)

type ConfigStamp* = tuple[exists: bool, mtime: int64, size: int64]

proc stamp*(path: string): ConfigStamp =
  ## Cheap change detection for the config file.
  try:
    let info = getFileInfo(path)
    let t = info.lastWriteTime
    (true, t.toUnix * 1000 + t.nanosecond div 1_000_000, info.size.int64)
  except OSError:
    (false, 0'i64, 0'i64)
