## Self-update for the AppImage build.
##
## Release builds made by CI (compiled with -d:autoUpdate) check GitHub for a
## newer AppImage at most once a day, in a detached background process. The
## latest release carries a .zsync file next to the AppImage; its SHA-1 line
## identifies the release build. If it differs from the running AppImage, the
## new one is downloaded, verified against that SHA-1 and renamed over the old
## file, so the next launch runs it. The running instance is unaffected, since
## the AppImage runtime keeps the old file open.
##
## Needs curl and sha1sum on the host; without them it does nothing. Set
## GHOSTNIM_NO_UPDATE=1 to turn the launch check off.
##
## "Check for Updates" in the right-click menu runs the same script right away,
## skipping the once-a-day limit, and reports the outcome with notify-send.

import std/[os, posix]

const
  autoUpdate {.booldefine.} = false
  updateRepo {.strdefine.} = "codegod100/ghostnim"

  # Runs with $0 = the AppImage path and $1 = "manual" for a check the user
  # asked for. Everything it needs is on the host, so it keeps working after
  # ghostnim exits and the AppImage is unmounted.
  updateScript = """
set -eu
app=$0
manual=${1:-}
say() {
  [ -n "$manual" ] && command -v notify-send >/dev/null &&
    notify-send -a ghostnim ghostnim "$1" || true
}
command -v curl >/dev/null && command -v sha1sum >/dev/null ||
  { say "Can't check for updates: curl and sha1sum are needed."; exit 0; }
[ -w "$(dirname "$app")" ] && [ -w "$app" ] ||
  { say "Can't update: $app isn't writable."; exit 0; }
cache=${XDG_CACHE_HOME:-$HOME/.cache}/ghostnim
mkdir -p "$cache"
stamp=$cache/last-update-check
if [ -z "$manual" ]; then
  [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ] && exit 0
fi
touch "$stamp"
base=https://github.com/""" & updateRepo & """/releases/latest/download/ghostnim-$(uname -m).AppImage
want=$(curl -fsSL --max-time 30 "$base.zsync" | sed -n 's/^SHA-1: *\([0-9a-f]*\).*/\1/p')
[ -n "$want" ] || { say "Couldn't check for updates."; exit 0; }
[ "$(sha1sum "$app" | cut -d' ' -f1)" = "$want" ] && { say "ghostnim is up to date."; exit 0; }
say "Downloading an update..."
tmp=$(mktemp "$app.update.XXXXXX")
trap 'rm -f "$tmp"' EXIT
curl -fsSL --max-time 600 -o "$tmp" "$base" || { say "Downloading the update failed."; exit 0; }
[ "$(sha1sum "$tmp" | cut -d' ' -f1)" = "$want" ] ||
  { say "The downloaded update didn't verify; not installed."; exit 0; }
chmod 755 "$tmp"
mv -f "$tmp" "$app"
trap - EXIT
say "ghostnim updated. Restart it to run the new version."
"""

proc canUpdate*(): bool =
  ## Whether this is a self-updating build running from an AppImage.
  when autoUpdate:
    result = getEnv("APPIMAGE").len > 0

proc startUpdateCheck*(manual = false) =
  ## Kick off the background update check when running from a CI AppImage.
  ## A manual check ignores the daily limit and GHOSTNIM_NO_UPDATE.
  when autoUpdate:
    if not canUpdate(): return
    if not manual and getEnv("GHOSTNIM_NO_UPDATE").len > 0: return
    let args = allocCStringArray(["sh", "-c", updateScript, getEnv("APPIMAGE"),
                                  if manual: "manual" else: ""])
    defer: deallocCStringArray(args)
    # Double fork so the checker is reparented to init and never becomes our
    # zombie; the intermediate child is reaped right here.
    let pid = fork()
    if pid < 0: return
    if pid == 0:
      discard setsid()
      if fork() == 0:
        let devnull = open("/dev/null", O_RDWR)
        for fd in 0.cint .. 2.cint: discard dup2(devnull, fd)
        for fd in 3.cint ..< 1024.cint: discard close(fd)
        discard execv("/bin/sh", args)
      exitnow(0)
    var status: cint
    discard waitpid(pid, status, 0)
