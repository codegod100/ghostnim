# Build configuration: where to find libghostty-vt.
#
# By default we expect `scripts/build-libghostty-vt.sh` to have installed it
# into ./vendor/ghostty-vt. Override with GHOSTTY_VT_PREFIX=/some/prefix.
import std/os

let prefix = block:
  let env = getEnv("GHOSTTY_VT_PREFIX")
  if env.len > 0: env else: thisDir() / "vendor" / "ghostty-vt"

switch("passC", "-I" & quoteShell(prefix / "include"))
if getEnv("GHOSTTY_VT_SHARED") == "1":
  switch("passL", "-L" & quoteShell(prefix / "lib") & " -lghostty-vt -Wl,-rpath," &
         quoteShell(prefix / "lib"))
else:
  # Static by default so the binary has no runtime dependency on libghostty.
  switch("passC", "-DGHOSTTY_STATIC")
  switch("passL", quoteShell(prefix / "lib" / "libghostty-vt.a"))
switch("passL", "-lm -lpthread")

# ORC is Nim 2's default; opt in on Nim 1.6 as well.
when (NimMajor, NimMinor) < (2, 0):
  switch("gc", "orc")
