## A small, dependency-free KDL parser (https://kdl.dev), enough for config
## files. It reads KDL v2 and also accepts v1's bare `true`/`false`/`null`.
##
## Supported: nodes, arguments, properties, children blocks, `;` and newline
## terminators, `\` line continuations, `//`, `/* */` (nested) and `/-`
## comments, bare identifiers, quoted strings with escapes, raw strings
## (`#"..."#`), multi-line strings (`"""`), decimal/hex/octal/binary numbers
## with `_` separators, `#inf`/`#-inf`/`#nan`, and `(type)` annotations
## (parsed and kept but not interpreted).

import std/strutils
from std/unicode import Rune, toUTF8, graphemeLen

type
  KdlKind* = enum kString, kInt, kFloat, kBool, kNull

  KdlVal* = object
    tag*: string                ## the `(type)` annotation, if any
    case kind*: KdlKind
    of kString: str*: string
    of kInt: num*: int64
    of kFloat: fnum*: float
    of kBool: bval*: bool
    of kNull: discard

  KdlNode* = object
    tag*: string
    name*: string
    args*: seq[KdlVal]
    props*: seq[(string, KdlVal)]   ## in source order; later keys win
    children*: seq[KdlNode]
    line*: int

  KdlError* = object of ValueError
    line*: int

  Parser = object
    s: string
    i: int
    line: int

proc `$`*(v: KdlVal): string =
  case v.kind
  of kString: v.str.escape
  of kInt: $v.num
  of kFloat: $v.fnum
  of kBool: (if v.bval: "#true" else: "#false")
  of kNull: "#null"

proc prop*(n: KdlNode, key: string): (bool, KdlVal) =
  ## The last value given for property `key`, if any.
  for i in countdown(n.props.high, 0):
    if n.props[i][0] == key: return (true, n.props[i][1])

proc fail(p: Parser, msg: string) {.noreturn.} =
  var e = newException(KdlError, "line " & $p.line & ": " & msg)
  e.line = p.line
  raise e

proc atEnd(p: Parser): bool {.inline.} = p.i >= p.s.len
proc peek(p: Parser, o = 0): char {.inline.} =
  if p.i + o < p.s.len: p.s[p.i + o] else: '\0'
proc startsWith(p: Parser, t: string): bool {.inline.} = p.s.continuesWith(t, p.i)

# Newlines: CRLF, CR, LF, NEL, FF, LS, PS.
proc newlineLen(p: Parser): int =
  let c = p.peek
  if c == '\r': return (if p.peek(1) == '\n': 2 else: 1)
  if c in {'\n', '\f'}: return 1
  if p.startsWith("\u0085"): return 2
  if p.startsWith(" ") or p.startsWith(" "): return 3

proc isSpace(p: Parser): int =
  ## Byte length of the unicode whitespace at the cursor, or 0.
  let c = p.peek
  if c in {' ', '\t'}: return 1
  if c.ord < 0x80: return 0
  if p.startsWith("﻿"): return 3
  for w in [" ", " ", " ", " ", " ", " ",
            " ", " ", " ", " ", " ", " ",
            " ", " ", " ", "　"]:
    if p.startsWith(w): return w.len

proc skipBlockComment(p: var Parser) =
  p.i += 2
  var depth = 1
  while depth > 0:
    if p.atEnd: p.fail("unterminated /* comment")
    if p.startsWith("/*"): inc depth; p.i += 2
    elif p.startsWith("*/"): dec depth; p.i += 2
    else:
      let n = p.newlineLen
      if n > 0: p.i += n; inc p.line
      else: inc p.i

proc skipLineComment(p: var Parser) =
  while not p.atEnd and p.newlineLen == 0: inc p.i

proc skipWs(p: var Parser) =
  ## Whitespace and block comments on the current line.
  while not p.atEnd:
    let n = p.isSpace
    if n > 0: p.i += n
    elif p.startsWith("/*"): p.skipBlockComment
    else: break

proc skipNodeSpace(p: var Parser) =
  ## Whitespace between a node's entries, including `\` line continuations.
  while true:
    p.skipWs
    if p.peek == '\\':
      inc p.i
      p.skipWs
      if p.startsWith("//"): p.skipLineComment
      let n = p.newlineLen
      if n > 0: p.i += n; inc p.line
      elif not p.atEnd: p.fail("expected newline after \\")
    else: break

proc skipLineSpace(p: var Parser) =
  ## Whitespace, newlines and comments between nodes.
  while not p.atEnd:
    p.skipWs
    if p.startsWith("//"): p.skipLineComment
    let n = p.newlineLen
    if n > 0: p.i += n; inc p.line
    else: break

const nonIdent = {'\\', '/', '(', ')', '{', '}', ';', '[', ']', '"', '#', '=',
                  ' ', '\t', '\r', '\n', '\f', '\0'}

proc atIdentChar(p: Parser): bool =
  not p.atEnd and p.peek notin nonIdent and p.isSpace == 0 and p.newlineLen == 0

proc parseBareIdent(p: var Parser): string =
  let start = p.i
  while p.atIdentChar:
    p.i += max(1, graphemeLen(p.s, p.i))
  result = p.s[start ..< p.i]
  if result.len == 0: p.fail("expected identifier")

proc dedent(p: Parser, body: string, raw: bool): string =
  ## Multi-line string rules: drop the first and last line; strip the last
  ## line's indentation (which must be whitespace only) from every line.
  var lines = body.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  if lines.len < 2 or lines[0].strip.len != 0:
    p.fail("multi-line string must start with a newline after \"\"\"")
  let indent = lines[^1]
  if indent.strip.len != 0:
    p.fail("multi-line string's closing \"\"\" must be on its own line")
  var outp: seq[string]
  for l in lines[1 .. ^2]:
    if l.strip.len == 0: outp.add ""
    elif l.startsWith(indent): outp.add l[indent.len .. ^1]
    else: p.fail("multi-line string line is less indented than its closing \"\"\"")
  outp.join("\n")

proc unescape(p: Parser, s: string): string =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c != '\\':
      result.add c; inc i; continue
    inc i
    if i >= s.len: p.fail("bad escape at end of string")
    case s[i]
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 't': result.add '\t'
    of '\\': result.add '\\'
    of '"': result.add '"'
    of 'b': result.add '\b'
    of 'f': result.add '\f'
    of 's': result.add ' '
    of 'u':
      if i + 1 >= s.len or s[i + 1] != '{': p.fail("bad \\u escape")
      let close = s.find('}', i)
      if close < 0: p.fail("bad \\u escape")
      let hex = s[i + 2 ..< close]
      if hex.len == 0 or hex.len > 6: p.fail("bad \\u escape")
      result.add Rune(parseHexInt(hex)).toUTF8
      i = close
    of ' ', '\t', '\n', '\r', '\f':
      # Escaped whitespace: skip it all.
      while i < s.len and s[i] in {' ', '\t', '\n', '\r', '\f'}: inc i
      continue
    else: p.fail("unknown escape \\" & s[i])
    inc i

proc parseQuoted(p: var Parser, hashes: int): string =
  ## At the opening quote(s). `hashes` > 0 means a raw string.
  let raw = hashes > 0
  let multi = p.startsWith("\"\"\"")
  let open = if multi: 3 else: 1
  p.i += open
  let closer = (if multi: "\"\"\"" else: "\"") & repeat('#', hashes)
  let start = p.i
  while true:
    if p.atEnd: p.fail("unterminated string")
    if not raw and p.peek == '\\':
      p.i += 2
      continue
    if p.startsWith(closer): break
    let n = p.newlineLen
    if n > 0:
      if not multi: p.fail("newline in single-line string (use \"\"\")")
      p.i += n; inc p.line
    else: inc p.i
  var body = p.s[start ..< p.i]
  p.i += closer.len
  if multi:
    if raw: result = p.dedent(body, true)
    else:
      # Escaped newlines are line continuations; resolve them after dedent
      # so indentation is computed from the literal text.
      result = p.unescape(p.dedent(body, false))
  else:
    result = if raw: body else: p.unescape(body)

proc parseString(p: var Parser): string =
  ## A quoted, raw or bare-identifier string.
  if p.peek == '"': return p.parseQuoted(0)
  if p.peek == '#':
    var h = 0
    while p.peek(h) == '#': inc h
    if p.peek(h) == '"':
      p.i += h
      return p.parseQuoted(h)
    p.fail("expected string")
  result = p.parseBareIdent
  if result in ["true", "false", "null", "inf", "-inf", "nan"]:
    p.fail("'" & result & "' must be quoted to use it as a string")

proc parseNumber(p: var Parser, word: string): KdlVal =
  var w = word.replace("_", "")
  var neg = false
  if w.len > 0 and w[0] in {'+', '-'}:
    neg = w[0] == '-'
    w = w[1 .. ^1]
  try:
    if w.len > 2 and w[0] == '0' and w[1] in {'x', 'o', 'b'}:
      let digits = w[2 .. ^1]
      var n = case w[1]
        of 'x': parseHexInt(digits)
        of 'o': parseOctInt(digits)
        else: parseBinInt(digits)
      return KdlVal(kind: kInt, num: (if neg: -n else: n).int64)
    if w.contains({'.', 'e', 'E'}):
      let f = parseFloat(w)
      return KdlVal(kind: kFloat, fnum: (if neg: -f else: f))
    let n = parseBiggestInt(w)
    return KdlVal(kind: kInt, num: (if neg: -n else: n).int64)
  except ValueError:
    p.fail("bad number '" & word & "'")

proc parseTag(p: var Parser): string =
  if p.peek != '(': return ""
  inc p.i
  p.skipWs
  result = p.parseString
  p.skipWs
  if p.peek != ')': p.fail("expected ')'")
  inc p.i
  p.skipWs

proc parseValue(p: var Parser): KdlVal =
  let tag = p.parseTag
  let c = p.peek
  if c == '"' or (c == '#' and (p.peek(1) in {'"', '#'})):
    result = KdlVal(kind: kString, str: p.parseString)
  elif c == '#':
    inc p.i
    let w = p.parseBareIdent
    result = case w
      of "true": KdlVal(kind: kBool, bval: true)
      of "false": KdlVal(kind: kBool, bval: false)
      of "null": KdlVal(kind: kNull)
      of "inf": KdlVal(kind: kFloat, fnum: Inf)
      of "-inf": KdlVal(kind: kFloat, fnum: NegInf)
      of "nan": KdlVal(kind: kFloat, fnum: NaN)
      else: p.fail("unknown keyword #" & w)
  else:
    let w = p.parseBareIdent
    if w[0] in Digits or (w.len > 1 and w[0] in {'+', '-'} and w[1] in Digits):
      result = p.parseNumber(w)
    else:
      result = case w
        of "true": KdlVal(kind: kBool, bval: true)      # KDL v1
        of "false": KdlVal(kind: kBool, bval: false)
        of "null": KdlVal(kind: kNull)
        else: KdlVal(kind: kString, str: w)
  result.tag = tag

proc parseNodes(p: var Parser, nested: bool): seq[KdlNode]

proc atNodeEnd(p: Parser): bool =
  p.atEnd or p.peek in {';', '}'} or p.newlineLen > 0 or p.startsWith("//")

proc parseNode(p: var Parser): KdlNode =
  result.line = p.line
  result.tag = p.parseTag
  result.name = p.parseString
  while true:
    let before = p.i
    p.skipNodeSpace
    if p.atNodeEnd: break
    if p.i == before and p.peek != '{' and not p.startsWith("/-"):
      p.fail("expected whitespace between node entries")
    var skip = false
    if p.startsWith("/-"):
      p.i += 2
      p.skipNodeSpace
      skip = true
    if p.peek == '{':
      inc p.i
      let kids = p.parseNodes(nested = true)
      if p.peek != '}': p.fail("expected '}'")
      inc p.i
      if not skip: result.children.add kids
      continue
    # A property is `key=value`, where key is any string form.
    let save = p.i
    let saveLine = p.line
    var isProp = false
    if p.peek != '(':
      try:
        discard p.parseString
        p.skipWs
        isProp = p.peek == '='
      except KdlError: discard
    p.i = save
    p.line = saveLine
    if isProp:
      let key = p.parseString
      p.skipWs
      inc p.i            # '='
      p.skipWs
      let v = p.parseValue
      if not skip: result.props.add (key, v)
    else:
      let v = p.parseValue
      if not skip: result.args.add v
  if p.peek == ';': inc p.i

proc parseNodes(p: var Parser, nested: bool): seq[KdlNode] =
  while true:
    p.skipLineSpace
    if p.atEnd:
      if nested: p.fail("unterminated '{'")
      break
    if p.peek == '}':
      if not nested: p.fail("unexpected '}'")
      break
    if p.peek == ';': inc p.i; continue
    var skip = false
    if p.startsWith("/-"):
      p.i += 2
      p.skipNodeSpace
      skip = true
    let n = p.parseNode
    if not skip: result.add n

proc parseKdl*(s: string): seq[KdlNode] =
  ## Parse a KDL document. Raises `KdlError` on malformed input.
  var p = Parser(s: s, line: 1)
  if p.startsWith("﻿"): p.i = 3
  p.parseNodes(nested = false)
