## Finding file and directory paths in terminal text, for Ctrl+click.
##
## The word under the pointer (see wordsel) counts as a path when it names
## something that exists, relative to the tab's working directory. A few
## decorations programs add are looked through: `:line:col` after a file name
## (compilers, grep -n), `a/` and `b/` in git diffs, and the `*` / `@` that
## `ls -F` puts after executables and symlinks.

import std/[os, strutils, uri]

proc stripLineCol(s: string): string =
  ## "foo.nim:12:3" -> "foo.nim", "foo.nim:12" -> "foo.nim", "foo:" -> "foo".
  result = s
  for _ in 0 .. 1:
    let i = result.rfind(':')
    if i <= 0: break
    let tail = result[i + 1 .. ^1]
    if tail.len > 0 and not tail.allCharsInSet(Digits): break
    result.setLen(i)

proc candidates(word: string): seq[string] =
  result.add word
  let noLine = stripLineCol(word)
  if noLine != word: result.add noLine
  for s in [word, noLine]:
    if s.len > 2 and s[0] in {'a', 'b'} and s[1] == '/': result.add s[2 .. ^1]
    if s.len > 1 and s[^1] in {'*', '@'}: result.add s[0 .. ^2]

proc pathTarget*(word, cwd: string): string =
  ## The absolute path that `word` names, if that file or directory exists
  ## (relative paths are taken from `cwd`), else "".
  if word.len == 0 or word[0] == '-' or word.contains('\0'): return ""
  for c in candidates(word):
    var p = c
    if p == "~" or p.startsWith("~/"): p = getHomeDir() / p[min(2, p.len) .. ^1]
    if not p.isAbsolute:
      if cwd.len == 0: continue
      p = cwd / p
    if dirExists(p) or fileExists(p):
      return p.normalizedPath

proc fileUrlPath*(url: string): string =
  ## The local path of a file:// URL (as `ls --hyperlink` prints), or "".
  if not url.toLowerAscii.startsWith("file://"): return ""
  let slash = url.find('/', "file://".len)
  if slash < 0: return ""
  decodeUrl(url[slash .. ^1], decodePlus = false)

when isMainModule:
  let tmp = getTempDir() / "ghostnim-paths-test"
  createDir(tmp / "src" / "sub")
  writeFile(tmp / "src" / "foo.nim", "")
  writeFile(tmp / "run", "")
  doAssert pathTarget("src", tmp) == tmp / "src"
  doAssert pathTarget("src/", tmp) == tmp / "src"
  doAssert pathTarget("src/sub", tmp) == tmp / "src" / "sub"
  doAssert pathTarget("src/foo.nim:12:3", tmp) == tmp / "src" / "foo.nim"
  doAssert pathTarget("src/foo.nim:12", tmp) == tmp / "src" / "foo.nim"
  doAssert pathTarget("src/foo.nim:", tmp) == tmp / "src" / "foo.nim"
  doAssert pathTarget("a/src/foo.nim", tmp) == tmp / "src" / "foo.nim"
  doAssert pathTarget("b/src", tmp) == tmp / "src"
  doAssert pathTarget("run*", tmp) == tmp / "run"
  doAssert pathTarget("..", tmp / "src") == tmp
  doAssert pathTarget(tmp / "src", "") == tmp / "src"
  doAssert pathTarget("~", tmp) == getHomeDir().normalizedPath
  doAssert pathTarget("nope", tmp) == ""
  doAssert pathTarget("-la", tmp) == ""
  doAssert pathTarget("src", "") == ""
  doAssert fileUrlPath("file:///tmp/a%20b") == "/tmp/a b"
  doAssert fileUrlPath("file://host/etc/") == "/etc/"
  doAssert fileUrlPath("https://x.org/") == ""
  removeDir(tmp)
  echo "paths: ok"
