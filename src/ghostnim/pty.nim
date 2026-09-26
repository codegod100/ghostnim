## Spawns a shell on a pseudo-terminal (forkpty) and exposes the master fd.

import std/[os, posix]

{.passL: "-lutil".}

type
  Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>", bycopy.} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

  Pty* = object
    fd*: cint      ## master side; read child output / write input here
    pid*: Pid

var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

proc setenv(name, value: cstring, overwrite: cint): cint {.importc, header: "<stdlib.h>".}
proc forkpty(amaster: ptr cint, name: cstring, termp: pointer,
             winp: ptr Winsize): Pid {.importc, header: "<pty.h>".}
proc ioctl(fd: cint, request: culong, arg: pointer): cint {.importc, header: "<sys/ioctl.h>", varargs.}

proc defaultShell*(): string =
  result = getEnv("SHELL")
  if result.len == 0:
    let pw = getpwuid(getuid())
    if pw != nil and pw.pw_shell != nil: result = $pw.pw_shell
  if result.len == 0: result = "/bin/sh"

proc spawn*(argv: seq[string], cols, rows: int, cellW, cellH: int, cwd = ""): Pty =
  ## Fork a child attached to a new pty running `argv`, optionally in `cwd`.
  var ws = Winsize(ws_row: rows.cushort, ws_col: cols.cushort,
                   ws_xpixel: (cols * cellW).cushort, ws_ypixel: (rows * cellH).cushort)
  # Build the exec arguments before forking; the child must not allocate.
  let cargs = allocCStringArray(argv)
  var master: cint
  let pid = forkpty(addr master, nil, nil, addr ws)
  if pid < 0:
    deallocCStringArray(cargs)
    raiseOSError(osLastError(), "forkpty failed")
  if pid == 0:
    # Child
    discard setenv("TERM", "xterm-256color", 1)
    discard setenv("COLORTERM", "truecolor", 1)
    discard setenv("TERM_PROGRAM", "ghostnim", 1)
    if cwd.len > 0: discard chdir(cwd.cstring)
    discard execvp(cargs[0], cargs)
    exitnow(127)
  deallocCStringArray(cargs)
  # Parent: make the master non-blocking so the UI loop never stalls.
  let flags = fcntl(master, F_GETFL)
  discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
  discard fcntl(master, F_SETFD, FD_CLOEXEC)
  Pty(fd: master, pid: pid)

proc resize*(p: Pty, cols, rows, cellW, cellH: int) =
  var ws = Winsize(ws_row: rows.cushort, ws_col: cols.cushort,
                   ws_xpixel: (cols * cellW).cushort, ws_ypixel: (rows * cellH).cushort)
  discard ioctl(p.fd, TIOCSWINSZ, addr ws)

proc writeAll*(p: Pty, data: pointer, len: int) =
  ## Write everything, retrying on EAGAIN (input is small, so spinning is fine).
  var off = 0
  let buf = cast[ptr UncheckedArray[char]](data)
  while off < len:
    let n = posix.write(p.fd, addr buf[off], len - off)
    if n > 0:
      off += n
    elif n < 0 and errno in [EAGAIN, EINTR]:
      var pfd = TPollfd(fd: p.fd, events: POLLOUT)
      discard poll(addr pfd, 1, 50)
    else:
      return

proc writeAll*(p: Pty, s: string) =
  if s.len > 0: p.writeAll(unsafeAddr s[0], s.len)

proc read*(p: Pty, buf: var openArray[uint8]): int =
  ## Returns bytes read, 0 if nothing available, -1 on EOF/error (child gone).
  let n = posix.read(p.fd, addr buf[0], buf.len)
  if n > 0: return n
  if n < 0 and errno in [EAGAIN, EINTR]: return 0
  -1

proc cwd*(p: Pty): string =
  ## The child's current working directory (Linux /proc), or "" if unknown.
  try: expandSymlink("/proc/" & $p.pid & "/cwd")
  except OSError: ""

proc childExited*(p: Pty): bool =
  var status: cint
  waitpid(p.pid, status, WNOHANG) == p.pid

proc close*(p: Pty) =
  discard posix.close(p.fd)
  discard kill(p.pid, SIGHUP)
