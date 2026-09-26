## Finding plain-text URLs in a line of terminal cells, for Ctrl+click.
##
## OSC 8 hyperlinks come straight from libghostty; this covers the URLs
## programs just print.

import std/strutils

const
  schemes = ["https://", "http://", "ftp://", "file://", "ssh://", "git://",
             "mailto:", "www."]
  ## Characters that end a URL even without whitespace.
  stopChars = {'"', '\'', '`', '<', '>', '{', '}', '|', '\\', '^', '\x7F'}
  ## Punctuation that usually belongs to the sentence, not the URL.
  trailingPunct = {'.', ',', ':', ';', '!', '?'}

proc isUrlChar(c: char): bool = c > ' ' and c notin stopChars

proc trimUrl(s: string, a: int, b: var int) =
  ## Drop trailing sentence punctuation and closing brackets that have no
  ## opening partner inside the URL, e.g. "(see https://x.org/a)."
  while b > a:
    let c = s[b - 1]
    if c in trailingPunct:
      dec b
    elif c in {')', ']'}:
      let open = if c == ')': '(' else: '['
      if s[a ..< b].count(open) < s[a ..< b].count(c): dec b
      else: break
    else:
      break

proc schemeAt(s: string, i: int): string =
  for sc in schemes:
    if i + sc.len <= s.len and cmpIgnoreCase(s[i ..< i + sc.len], sc) == 0:
      return sc

proc urlSpan*(text: string, target: int): (int, int) =
  ## The byte range [a, b) of the URL in `text` that covers byte `target`, or
  ## (-1, -1) if there's none.
  var i = 0
  while i < text.len:
    let sc = if i == 0 or not text[i - 1].isAlphaNumeric: text.schemeAt(i) else: ""
    if sc.len == 0:
      inc i
      continue
    var e = i
    while e < text.len and isUrlChar(text[e]): inc e
    trimUrl(text, i, e)
    if e - i > sc.len and target in i ..< e:
      return (i, e)
    i = max(e, i + 1)
  (-1, -1)

proc urlAt*(cells: openArray[string], col: int): string =
  ## The URL covering cell `col` of a line, or "". Each entry of `cells` is
  ## that cell's text: " " for a blank cell and "" for the right half of a
  ## wide character.
  if col < 0 or col >= cells.len: return ""
  var text = ""
  var target = -1
  for i, c in cells:
    if i == col: target = text.len
    text.add c
  if cells[col].len == 0:
    target = max(0, target - 1)   # right half of a wide char: its left half
  let (a, b) = urlSpan(text, target)
  if a < 0: return ""
  result = text[a ..< b]
  if result.toLowerAscii.startsWith("www."): result = "https://" & result

when isMainModule:
  proc cellsOf(s: string): seq[string] =
    for c in s: result.add $c
  doAssert urlAt(cellsOf("see https://ghostty.org/docs now"), 8) == "https://ghostty.org/docs"
  doAssert urlAt(cellsOf("see https://ghostty.org/docs now"), 2) == ""
  doAssert urlAt(cellsOf("(https://en.wikipedia.org/wiki/Nim_(lang))."), 5) ==
    "https://en.wikipedia.org/wiki/Nim_(lang)"
  doAssert urlAt(cellsOf("go to www.nim-lang.org, then"), 10) == "https://www.nim-lang.org"
  doAssert urlAt(cellsOf("\"http://a.b/c\""), 1) == "http://a.b/c"
  doAssert urlAt(cellsOf("https://"), 3) == ""
  doAssert urlAt(cellsOf("xhttp://a.b"), 5) == ""
  doAssert urlAt(@["h", "t", "t", "p", ":", "/", "/", "a", "/", "日", "", "x"], 10) ==
    "http://a/日x"
  echo "links: ok"
