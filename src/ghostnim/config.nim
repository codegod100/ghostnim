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

import std/[os, strutils]
import kdl

type
  Config* = object
    font*: string
    size*: int
    cols*, rows*: int
    scrollback*: int
    command*: seq[string]

const defaultConfig* = Config(size: 14, cols: 100, rows: 30, scrollback: 10_000)

proc configPath*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg.isAbsolute: xdg else: getHomeDir() / ".config"
  base / "ghostnim" / "config.kdl"

proc warn(path: string, line: int, msg: string) =
  stderr.writeLine "ghostnim: " & path & ":" & $line & ": " & msg

proc parseConfig*(text: string, path = "config.kdl"): Config =
  ## Apply the settings in `text` over the defaults. Problems are reported on
  ## stderr and skipped, so a typo never keeps the terminal from starting.
  result = defaultConfig
  var nodes: seq[KdlNode]
  try:
    nodes = parseKdl(text)
  except KdlError as e:
    warn(path, e.line, e.msg.split(": ", 1)[^1] & "; ignoring the config file")
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
    else:
      bad("unknown setting")

proc loadConfig*(path = ""): Config =
  ## Read the config file at `path`, or the default location. A missing file
  ## at the default location is fine; a missing explicit one is an error.
  let p = if path.len > 0: path else: configPath()
  if not fileExists(p):
    if path.len > 0: quit("ghostnim: config file not found: " & path, 2)
    return defaultConfig
  try:
    parseConfig(readFile(p), p)
  except IOError as e:
    warn(p, 0, e.msg)
    defaultConfig
