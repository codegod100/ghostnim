## Translation from SDL keyboard state to libghostty-vt key events.

import vt, sdl

proc toGhosttyKey*(scancode: cint): GhosttyKey =
  ## Map an SDL scancode (physical key, USB HID usage) to a GhosttyKey
  ## (W3C UI Events KeyboardEvent.code).
  case scancode
  of 4..29: GhosttyKey(ord(gkA) + (scancode - 4))           # A..Z
  of 30..38: GhosttyKey(ord(gkDigit1) + (scancode - 30))    # 1..9
  of 39: gkDigit0
  of 40: gkEnter
  of 41: gkEscape
  of 42: gkBackspace
  of 43: gkTab
  of 44: gkSpace
  of 45: gkMinus
  of 46: gkEqual
  of 47: gkBracketLeft
  of 48: gkBracketRight
  of 49, 50: gkBackslash
  of 51: gkSemicolon
  of 52: gkQuote
  of 53: gkBackquote
  of 54: gkComma
  of 55: gkPeriod
  of 56: gkSlash
  of 57: gkCapsLock
  of 58..69: GhosttyKey(ord(gkF1) + (scancode - 58))        # F1..F12
  of 70: gkPrintScreen
  of 71: gkScrollLock
  of 72: gkPause
  of 73: gkInsert
  of 74: gkHome
  of 75: gkPageUp
  of 76: gkDelete
  of 77: gkEnd
  of 78: gkPageDown
  of 79: gkArrowRight
  of 80: gkArrowLeft
  of 81: gkArrowDown
  of 82: gkArrowUp
  of 83: gkNumLock
  of 84: gkNumpadDivide
  of 85: gkNumpadMultiply
  of 86: gkNumpadSubtract
  of 87: gkNumpadAdd
  of 88: gkNumpadEnter
  of 89..97: GhosttyKey(ord(gkNumpad1) + (scancode - 89))   # KP 1..9
  of 98: gkNumpad0
  of 99: gkNumpadDecimal
  of 100: gkIntlBackslash
  of 101: gkContextMenu
  of 103: gkNumpadEqual
  of 104..115: GhosttyKey(ord(gkF13) + (scancode - 104))    # F13..F24
  of 224: gkControlLeft
  of 225: gkShiftLeft
  of 226: gkAltLeft
  of 227: gkMetaLeft
  of 228: gkControlRight
  of 229: gkShiftRight
  of 230: gkAltRight
  of 231: gkMetaRight
  else: gkUnidentified

proc toGhosttyMods*(m: uint16): GhosttyMods =
  if (m and KMOD_SHIFT) != 0: result = result or GHOSTTY_MODS_SHIFT
  if (m and KMOD_CTRL) != 0: result = result or GHOSTTY_MODS_CTRL
  if (m and KMOD_ALT) != 0: result = result or GHOSTTY_MODS_ALT
  if (m and KMOD_GUI) != 0: result = result or GHOSTTY_MODS_SUPER
  if (m and KMOD_CAPS) != 0: result = result or GHOSTTY_MODS_CAPS_LOCK
  if (m and KMOD_NUM) != 0: result = result or GHOSTTY_MODS_NUM_LOCK

proc unshiftedCodepoint*(sym: int32): uint32 =
  ## SDL keycodes for printable keys are the layout's unshifted character.
  const scancodeMask = 1'i32 shl 30
  if sym >= 0x20 and sym != 0x7f and (sym and scancodeMask) == 0: uint32(sym)
  else: 0

proc producesText*(sym: int32, mods: uint16): bool =
  ## Whether SDL will follow this key press with an SDL_TEXTINPUT event.
  unshiftedCodepoint(sym) != 0 and (mods and (KMOD_CTRL or KMOD_ALT or KMOD_GUI)) == 0

proc codepointToUtf8*(cp: uint32): string =
  if cp < 0x80:
    result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or (cp shr 18))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
