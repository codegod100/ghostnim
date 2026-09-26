# Package

version       = "0.1.0"
author        = "ghostnim contributors"
description   = "A terminal emulator in Nim, powered by libghostty-vt"
license       = "MIT"
srcDir        = "src"
bin           = @["ghostnim"]

# Dependencies

requires "nim >= 1.6.0"

task vt, "Fetch and build libghostty-vt into ./vendor/ghostty-vt":
  exec "sh scripts/build-libghostty-vt.sh"
