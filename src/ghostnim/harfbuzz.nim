## Minimal HarfBuzz bindings (just what ghostnim uses to detect shaping).
##
## SDL_ttf does the actual shaped rendering; we only ask HarfBuzz whether a
## run of text comes out differently from drawing each character on its own.

{.passL: "-lharfbuzz".}

type
  HbBlob* = object
  HbFace* = object
  HbFont* = object
  HbBuffer* = object

  HbGlyphInfo* {.bycopy.} = object
    codepoint*: uint32       ## glyph index after shaping
    mask: uint32
    cluster*: uint32         ## byte offset of the source text
    var1, var2: uint32

  HbGlyphPosition* {.bycopy.} = object
    xAdvance*, yAdvance*, xOffset*, yOffset*: int32
    var0: uint32

const HB_DIRECTION_LTR* = 4.cint

{.push importc, cdecl.}
proc hb_blob_create_from_file*(path: cstring): ptr HbBlob
proc hb_blob_destroy*(b: ptr HbBlob)
proc hb_face_create*(b: ptr HbBlob, index: cuint): ptr HbFace
proc hb_face_destroy*(f: ptr HbFace)
proc hb_face_get_glyph_count*(f: ptr HbFace): cuint
proc hb_font_create*(f: ptr HbFace): ptr HbFont
proc hb_font_destroy*(f: ptr HbFont)
proc hb_font_get_nominal_glyph*(f: ptr HbFont, cp: uint32, glyph: ptr uint32): cint
proc hb_font_get_glyph_h_advance*(f: ptr HbFont, glyph: uint32): int32
proc hb_buffer_create*(): ptr HbBuffer
proc hb_buffer_destroy*(b: ptr HbBuffer)
proc hb_buffer_clear_contents*(b: ptr HbBuffer)
proc hb_buffer_add_utf8*(b: ptr HbBuffer, text: cstring, textLen: cint,
                         itemOffset: cuint, itemLen: cint)
proc hb_buffer_set_direction*(b: ptr HbBuffer, dir: cint)
proc hb_buffer_guess_segment_properties*(b: ptr HbBuffer)
proc hb_buffer_get_glyph_infos*(b: ptr HbBuffer, len: ptr cuint): ptr UncheckedArray[HbGlyphInfo]
proc hb_buffer_get_glyph_positions*(b: ptr HbBuffer, len: ptr cuint): ptr UncheckedArray[HbGlyphPosition]
proc hb_shape*(f: ptr HbFont, b: ptr HbBuffer, features: pointer, numFeatures: cuint)
{.pop.}
