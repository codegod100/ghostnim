## Double-click selection: which cells of a line make up the "word" under
## the pointer.
##
## A URL is taken whole. Otherwise a word runs until whitespace, a quote, a
## bracket or a separator like `,` `;` `|`, so paths, flags, e-mail
## addresses, host:port pairs and identifiers each select in one go. Sentence
## punctuation at the end ("see foo.nim:12.") is left out. Clicking a blank
## selects the run of blanks, and clicking a separator selects the run of
## that same character (e.g. a row of `=`).

import std/unicode
import links

const
  ## ASCII characters that end a word.
  boundaryChars = {'\t', '"', '\'', '`', '|', ';', ',', '(', ')', '[', ']', '{',
                   '}', '<', '>'}
  ## Trailing characters that usually belong to the sentence, not the word.
  trailingPunct = {'.', ':', '!', '?'}

type CellKind = enum ckBlank, ckWord, ckBoundary

proc isBlank(c: string): bool = c.len == 0 or c == " "

proc kind(c: string): CellKind =
  if c.isBlank: return ckBlank
  if c.len == 1:
    return if c[0] in boundaryChars or c[0] < ' ': ckBoundary else: ckWord
  # Box drawing and block elements are table borders, not text.
  let r = c.runeAt(0).int
  if r in 0x2500 .. 0x259F: ckBoundary else: ckWord

proc wordAt*(cells: openArray[string], col: int): (int, int) =
  ## The first and last cell (inclusive) of the word covering cell `col` of a
  ## line. Each entry of `cells` is that cell's text: " " for a blank cell and
  ## "" for the right half of a wide character.
  if cells.len == 0: return (0, 0)
  var col = clamp(col, 0, cells.len - 1)
  # The right half of a wide character belongs to its left half.
  while col > 0 and cells[col].len == 0: dec col

  # A URL, taken whole even across brackets and quotes.
  var text = ""
  var starts = newSeq[int](cells.len)
  for i, c in cells:
    starts[i] = text.len
    text.add c
  let (ua, ub) = urlSpan(text, starts[col])
  if ua >= 0:
    var a = col
    while a > 0 and starts[a] > ua: dec a
    var b = col
    while b + 1 < cells.len and starts[b + 1] < ub: inc b
    while b + 1 < cells.len and cells[b + 1].len == 0: inc b
    return (a, b)

  # The right half of a wide character goes with its left half.
  template owner(i: int): int =
    (if i > 0 and cells[i].len == 0 and cells[i - 1].len > 0: i - 1 else: i)
  let k = kind(cells[col])
  template same(i: int): bool =
    case k
    of ckBlank: owner(i) == i and cells[i].isBlank
    of ckWord: kind(cells[owner(i)]) == ckWord
    of ckBoundary: cells[owner(i)] == cells[col]
  var a = col
  while a > 0 and same(a - 1): dec a
  var b = col
  while b + 1 < cells.len and same(b + 1): inc b

  if k == ckWord:
    # Drop trailing sentence punctuation, unless that's what was clicked.
    var e = b
    while e > a and cells[e].len == 1 and cells[e][0] in trailingPunct: dec e
    if e >= col: b = e
  (a, b)

when isMainModule:
  proc cellsOf(s: string): seq[string] =
    for c in s: result.add $c
  proc word(s: string, col: int): string =
    let (a, b) = wordAt(cellsOf(s), col)
    s[a .. b]
  doAssert word("hello world", 1) == "hello"
  doAssert word("hello world", 8) == "world"
  doAssert word("vim src/ghostnim/wordsel.nim:12:3", 10) == "src/ghostnim/wordsel.nim:12:3"
  doAssert word("see foo.nim.", 5) == "foo.nim"
  doAssert word("see foo.nim.", 11) == "foo.nim."
  doAssert word("key: value", 1) == "key"
  doAssert word("ls --color=auto -la", 5) == "--color=auto"
  doAssert word("mail me@example.com, ok", 9) == "me@example.com"
  doAssert word("f(\"arg\", 10)", 3) == "arg"
  doAssert word("f(\"arg\", 10)", 0) == "f"
  doAssert word("a  ====  b", 5) == "===="
  doAssert word("a    b", 2) == "    "
  doAssert word("(see https://en.wikipedia.org/wiki/Nim_(lang)).", 10) ==
    "https://en.wikipedia.org/wiki/Nim_(lang)"
  doAssert word("x = 127.0.0.1:8080;", 6) == "127.0.0.1:8080"
  doAssert wordAt(@["│", " ", "c", "e", "l", "l", " ", "│"], 3) == (2, 5)
  doAssert wordAt(@["│", "│", "a"], 0) == (0, 1)
  doAssert wordAt(@["a", "日", "", "b", " ", "c"], 2) == (0, 3)
  doAssert wordAt(@["a", "日", "", "b", " ", "c"], 4) == (4, 4)
  doAssert wordAt(@["x", " ", "日", "", " "], 1) == (1, 1)
  doAssert wordAt(@[" ", "日", "", "本", "", " "], 3) == (1, 4)
  doAssert wordAt(@[" ", "日", "", "本", "", " "], 2) == (1, 4)
  echo "wordsel: ok"
