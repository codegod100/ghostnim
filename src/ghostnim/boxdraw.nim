## Procedural drawing of box-drawing (U+2500–U+257F) and block element
## (U+2580–U+259F) characters, so lines and blocks join seamlessly across
## cells regardless of the font's metrics (Ghostty does the same).

import sdl

const
  # Arm weights for U+2500..U+257F, packed as 2 bits each: up, right, down,
  # left (0 none, 1 light, 2 heavy, 3 double). 0 means "not handled" (the
  # diagonals), which falls back to the font. Generated from Unicode names.
  boxArms: array[128, uint8] = [
  0b00010001'u8, 0b00100010'u8, 0b01000100'u8, 0b10001000'u8, 0b00010001'u8, 0b00100010'u8, 0b01000100'u8, 0b10001000'u8,  # U+2500
  0b00010001'u8, 0b00100010'u8, 0b01000100'u8, 0b10001000'u8, 0b00010100'u8, 0b00100100'u8, 0b00011000'u8, 0b00101000'u8,  # U+2508
  0b00000101'u8, 0b00000110'u8, 0b00001001'u8, 0b00001010'u8, 0b01010000'u8, 0b01100000'u8, 0b10010000'u8, 0b10100000'u8,  # U+2510
  0b01000001'u8, 0b01000010'u8, 0b10000001'u8, 0b10000010'u8, 0b01010100'u8, 0b01100100'u8, 0b10010100'u8, 0b01011000'u8,  # U+2518
  0b10011000'u8, 0b10100100'u8, 0b01101000'u8, 0b10101000'u8, 0b01000101'u8, 0b01000110'u8, 0b10000101'u8, 0b01001001'u8,  # U+2520
  0b10001001'u8, 0b10000110'u8, 0b01001010'u8, 0b10001010'u8, 0b00010101'u8, 0b00010110'u8, 0b00100101'u8, 0b00100110'u8,  # U+2528
  0b00011001'u8, 0b00011010'u8, 0b00101001'u8, 0b00101010'u8, 0b01010001'u8, 0b01010010'u8, 0b01100001'u8, 0b01100010'u8,  # U+2530
  0b10010001'u8, 0b10010010'u8, 0b10100001'u8, 0b10100010'u8, 0b01010101'u8, 0b01010110'u8, 0b01100101'u8, 0b01100110'u8,  # U+2538
  0b10010101'u8, 0b01011001'u8, 0b10011001'u8, 0b10010110'u8, 0b10100101'u8, 0b01011010'u8, 0b01101001'u8, 0b10100110'u8,  # U+2540
  0b01101010'u8, 0b10011010'u8, 0b10101001'u8, 0b10101010'u8, 0b00010001'u8, 0b00100010'u8, 0b01000100'u8, 0b10001000'u8,  # U+2548
  0b00110011'u8, 0b11001100'u8, 0b00110100'u8, 0b00011100'u8, 0b00111100'u8, 0b00000111'u8, 0b00001101'u8, 0b00001111'u8,  # U+2550
  0b01110000'u8, 0b11010000'u8, 0b11110000'u8, 0b01000011'u8, 0b11000001'u8, 0b11000011'u8, 0b01110100'u8, 0b11011100'u8,  # U+2558
  0b11111100'u8, 0b01000111'u8, 0b11001101'u8, 0b11001111'u8, 0b00110111'u8, 0b00011101'u8, 0b00111111'u8, 0b01110011'u8,  # U+2560
  0b11010001'u8, 0b11110011'u8, 0b01110111'u8, 0b11011101'u8, 0b11111111'u8, 0b00010100'u8, 0b00000101'u8, 0b01000001'u8,  # U+2568
  0b01010000'u8, 0'u8, 0'u8, 0'u8, 0b00000001'u8, 0b01000000'u8, 0b00010000'u8, 0b00000100'u8,  # U+2570
  0b00000010'u8, 0b10000000'u8, 0b00100000'u8, 0b00001000'u8, 0b00100001'u8, 0b01001000'u8, 0b00010010'u8, 0b10000100'u8,  # U+2578
  ]

type FillFn = proc (x, y, w, h: int, alpha: uint8)

proc isSpecial*(cp: uint32): bool =
  (cp >= 0x2500'u32 and cp <= 0x257F'u32 and boxArms[cp - 0x2500] != 0) or
    (cp >= 0x2580'u32 and cp <= 0x259F'u32)

proc drawBox(cp: uint32, x, y, w, h: int, fill: FillFn) =
  let arms = boxArms[cp - 0x2500]
  let up = int((arms shr 6) and 3)
  let right = int((arms shr 4) and 3)
  let down = int((arms shr 2) and 3)
  let left = int(arms and 3)
  let light = max(1, (min(w, h) + 4) div 9)
  let heavy = light * 2
  proc thick(weight: int): int =
    case weight
    of 1: light
    of 2: heavy
    else: light * 3   # double: two light strokes with a light-sized gap
  let cx = x + (w - light) div 2    # left edge of a light vertical stroke
  let cy = y + (h - light) div 2    # top edge of a light horizontal stroke
  # How far the horizontal / vertical arms must reach past the centre so
  # they meet the perpendicular strokes without gaps.
  let vReach = max(thick(up), thick(down))
  let hReach = max(thick(left), thick(right))

  proc hArm(x0, x1, weight: int) =
    let t = thick(weight)
    let top = cy + light div 2 - t div 2
    if weight == 3:
      fill(x0, top, x1 - x0, light, 255)
      fill(x0, top + 2 * light, x1 - x0, light, 255)
    else:
      fill(x0, top, x1 - x0, t, 255)

  proc vArm(y0, y1, weight: int) =
    let t = thick(weight)
    let lft = cx + light div 2 - t div 2
    if weight == 3:
      fill(lft, y0, light, y1 - y0, 255)
      fill(lft + 2 * light, y0, light, y1 - y0, 255)
    else:
      fill(lft, y0, t, y1 - y0, 255)

  let midX = cx + light div 2
  let midY = cy + light div 2
  if left > 0: hArm(x, midX + (if vReach > 0: (vReach + 1) div 2 else: (light + 1) div 2), left)
  if right > 0: hArm(midX - (if vReach > 0: vReach div 2 else: light div 2), x + w, right)
  if up > 0: vArm(y, midY + (if hReach > 0: (hReach + 1) div 2 else: (light + 1) div 2), up)
  if down > 0: vArm(midY - (if hReach > 0: hReach div 2 else: light div 2), y + h, down)

proc drawBlock(cp: uint32, x, y, w, h: int, fill: FillFn) =
  let hw = w div 2
  let hh = h div 2
  template quad(ul, ur, ll, lr: bool) =
    if ul: fill(x, y, hw, hh, 255)
    if ur: fill(x + hw, y, w - hw, hh, 255)
    if ll: fill(x, y + hh, hw, h - hh, 255)
    if lr: fill(x + hw, y + hh, w - hw, h - hh, 255)
  case cp
  of 0x2580: fill(x, y, w, hh, 255)                           # upper half
  of 0x2581..0x2587:                                          # lower n/8
    let eh = h * int(cp - 0x2580) div 8
    fill(x, y + h - eh, w, eh, 255)
  of 0x2588: fill(x, y, w, h, 255)                            # full block
  of 0x2589..0x258F:                                          # left n/8
    fill(x, y, w * int(0x2590 - cp) div 8, h, 255)
  of 0x2590: fill(x + hw, y, w - hw, h, 255)                  # right half
  of 0x2591: fill(x, y, w, h, 64)                             # light shade
  of 0x2592: fill(x, y, w, h, 128)                            # medium shade
  of 0x2593: fill(x, y, w, h, 192)                            # dark shade
  of 0x2594: fill(x, y, w, max(1, h div 8), 255)              # upper 1/8
  of 0x2595: fill(x + w - max(1, w div 8), y, max(1, w div 8), h, 255)
  of 0x2596: quad(false, false, true, false)
  of 0x2597: quad(false, false, false, true)
  of 0x2598: quad(true, false, false, false)
  of 0x2599: quad(true, false, true, true)
  of 0x259A: quad(true, false, false, true)
  of 0x259B: quad(true, true, true, false)
  of 0x259C: quad(true, true, false, true)
  of 0x259D: quad(false, true, false, false)
  of 0x259E: quad(false, true, true, false)
  of 0x259F: quad(false, true, true, true)
  else: discard

proc drawSpecial*(r: RendererPtr, cp: uint32, x, y, w, h: int,
                  color: tuple[r, g, b: uint8], alpha: uint8) =
  ## Draw special character `cp` into the cell rectangle (x, y, w, h).
  let fill: FillFn = proc (fx, fy, fw, fh: int, a: uint8) =
    if fw <= 0 or fh <= 0: return
    discard setRenderDrawColor(r, color.r, color.g, color.b,
                               uint8(int(a) * int(alpha) div 255))
    var rect = Rect(x: cint(fx), y: cint(fy), w: cint(fw), h: cint(fh))
    discard renderFillRect(r, addr rect)
  discard setRenderDrawBlendMode(r, BLENDMODE_BLEND)
  if cp < 0x2580'u32: drawBox(cp, x, y, w, h, fill)
  else: drawBlock(cp, x, y, w, h, fill)
  discard setRenderDrawBlendMode(r, BLENDMODE_NONE)
