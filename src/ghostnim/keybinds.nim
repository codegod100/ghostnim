## Keyboard shortcuts: which key chords run which ghostnim actions.
##
## Chords are written like `ctrl+shift+t`: any of `ctrl`, `shift`, `alt` and
## `super`, then one key. Keys are physical keys named as on a US layout:
## `a`-`z`, `0`-`9`, `f1`-`f25`, `enter`, `tab`, `space`, `escape`,
## `backspace`, `delete`, `insert`, `home`, `end`, `page-up`, `page-down`,
## `up`, `down`, `left`, `right`, punctuation such as `=`, `-`, `,`, `/`,
## or any libghostty key name (`numpad-add`, `bracket-left`, ...).

import std/[strutils, tables]
import keys
export tables

type
  Action* = enum
    acNone = "none"                  ## unbinds the chord
    acCopy = "copy"
    acPaste = "paste"
    acSelectAll = "select-all"
    acNewTab = "new-tab"
    acCloseTab = "close-tab"
    acNextTab = "next-tab"
    acPreviousTab = "previous-tab"
    acGotoTab = "goto-tab"           ## arg: tab number, from 1
    acScrollPageUp = "scroll-page-up"      ## half a screen
    acScrollPageDown = "scroll-page-down"
    acScrollToTop = "scroll-to-top"
    acScrollToBottom = "scroll-to-bottom"
    acFontBigger = "font-bigger"
    acFontSmaller = "font-smaller"
    acFontReset = "font-reset"
    acSendText = "send-text"         ## arg: text written to the program
    acReloadConfig = "reload-config"
    acOpenConfig = "open-config"

  Mod* = enum mCtrl, mShift, mAlt, mSuper

  Chord* = object
    key*: GhosttyKey
    mods*: set[Mod]

  Binding* = object
    action*: Action
    num*: int        ## goto-tab's tab number
    text*: string    ## send-text's text

  Keybinds* = Table[Chord, Binding]

proc hash*(c: Chord): int =
  var m = 0
  for x in c.mods: m = m or (1 shl x.ord)
  c.key.ord * 16 + m

proc `==`*(a, b: Chord): bool = a.key == b.key and a.mods == b.mods

const keyAliases = {
  "=": gkEqual, "-": gkMinus, ",": gkComma, ".": gkPeriod, "/": gkSlash,
  ";": gkSemicolon, "'": gkQuote, "`": gkBackquote, "[": gkBracketLeft,
  "]": gkBracketRight, "\\": gkBackslash,
  "up": gkArrowUp, "down": gkArrowDown, "left": gkArrowLeft, "right": gkArrowRight,
  "esc": gkEscape, "return": gkEnter, "del": gkDelete, "ins": gkInsert,
  "pgup": gkPageUp, "pgdn": gkPageDown, "pagedown": gkPageDown, "pageup": gkPageUp,
  "plus": gkEqual, "grave": gkBackquote, "menu": gkContextMenu}

proc parseKey(name: string): (bool, GhosttyKey) =
  let n = name.toLowerAscii
  for (alias, k) in keyAliases:
    if n == alias: return (true, k)
  if n.len == 1 and n[0] in Digits:
    return (true, GhosttyKey(gkDigit0.ord + (n[0].ord - '0'.ord)))
  let norm = n.replace("-", "").replace("_", "")
  for k in GhosttyKey:
    if k != gkUnidentified and ($k)[2 .. ^1].toLowerAscii == norm: return (true, k)

proc parseChord*(s: string): (bool, Chord) =
  ## "ctrl+shift+t" → Chord. The `+`/`=` key is spelled `=` or `plus`.
  let parts = s.split('+')
  if parts.len == 0 or parts[^1].len == 0: return
  var c: Chord
  for p in parts[0 .. ^2]:
    case p.toLowerAscii
    of "ctrl", "control": c.mods.incl mCtrl
    of "shift": c.mods.incl mShift
    of "alt", "opt", "option": c.mods.incl mAlt
    of "super", "meta", "cmd", "gui", "win": c.mods.incl mSuper
    else: return
  let (ok, k) = parseKey(parts[^1])
  if not ok: return
  c.key = k
  (true, c)

proc parseAction*(s: string): (bool, Action) =
  for a in Action:
    if $a == s: return (true, a)

proc bindingDoc*(c: Chord): string =
  for m in [mCtrl, mShift, mAlt, mSuper]:
    if m in c.mods: result.add ["ctrl", "shift", "alt", "super"][m.ord] & "+"
  result.add ($c.key)[2 .. ^1].toLowerAscii

proc defaultKeybinds*(): Keybinds =
  template b(chord: string, a: Action, n = 0) =
    result[parseChord(chord)[1]] = Binding(action: a, num: n)
  b "ctrl+shift+c", acCopy
  b "ctrl+shift+v", acPaste
  b "ctrl+shift+t", acNewTab
  b "ctrl+shift+w", acCloseTab
  b "ctrl+tab", acNextTab
  b "ctrl+shift+tab", acPreviousTab
  b "ctrl+page-down", acNextTab
  b "ctrl+page-up", acPreviousTab
  b "shift+page-up", acScrollPageUp
  b "shift+page-down", acScrollPageDown
  b "ctrl+=", acFontBigger
  b "ctrl+shift+=", acFontBigger         # ctrl++ on a US layout
  b "ctrl+numpad-add", acFontBigger
  b "ctrl+-", acFontSmaller
  b "ctrl+numpad-subtract", acFontSmaller
  b "ctrl+0", acFontReset
  b "ctrl+shift+,", acReloadConfig
  b "ctrl+,", acOpenConfig

proc label(c: Chord): string =
  ## "Ctrl+Shift+C", for showing in the menu.
  for m in [mCtrl, mShift, mAlt, mSuper]:
    if m in c.mods: result.add ["Ctrl", "Shift", "Alt", "Super"][m.ord] & "+"
  const punct = {gkEqual: "=", gkMinus: "-", gkComma: ",", gkPeriod: ".",
                 gkSlash: "/", gkSemicolon: ";", gkQuote: "'", gkBackquote: "`",
                 gkBracketLeft: "[", gkBracketRight: "]", gkBackslash: "\\"}
  for (k, s) in punct:
    if k == c.key: return result & s
  var name = ($c.key)[2 .. ^1]
  if name.startsWith("Digit"): name = name[5 .. ^1]
  elif name.startsWith("Arrow"): name = name[5 .. ^1]
  result.add name

proc shortcutLabel*(kb: Keybinds, action: Action): string =
  ## The shortest chord bound to `action`, or "" if none.
  for c, b in kb:
    if b.action == action:
      let l = c.label
      if result.len == 0 or l.len < result.len or (l.len == result.len and l < result):
        result = l
