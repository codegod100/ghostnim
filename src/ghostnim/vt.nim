## Minimal Nim bindings for libghostty-vt (the C API of Ghostty's terminal core).
##
## Only the subset of the API ghostnim needs is bound here. Types are imported
## from `ghostty/vt.h` so struct layouts always come from the real headers;
## sized structs are marked `incompleteStruct` so `sizeof` is emitted as C.
##
## Header reference: https://github.com/ghostty-org/ghostty/tree/main/include/ghostty/vt

import std/[os, strutils]

const vtHeader = "ghostty/vt.h"

const ghosttyVtInclude {.strdefine.} = ""
  ## Set by config.nims to the libghostty-vt include directory.

when ghosttyVtInclude.len > 0:
  # Fail early with a useful message when the headers are missing or predate
  # the API these bindings target (e.g. a stale ./vendor/ghostty-vt), instead
  # of cryptic C "unknown type name" errors.
  proc firstMissingVtType(): string {.compileTime.} =
    const required = [
      # GhosttyRenderStateCursor is the newest (Ghostty, 2026-08-15).
      ("render.h", "GhosttyRenderStateCursor"),
      ("render.h", "GhosttyRenderStateColors"),
      ("grid_ref.h", "GhosttyGridRef"),
      ("mouse/encoder.h", "GhosttyMouseEncoderSize")]
    for (file, name) in required:
      let path = ghosttyVtInclude / "ghostty" / "vt" / file
      if not fileExists(path) or "} " & name & ";" notin staticRead(path):
        return name

  when not fileExists(ghosttyVtInclude / "ghostty" / "vt.h"):
    {.error: "libghostty-vt headers not found in " & ghosttyVtInclude &
      ". Run `nimble vt` (or set GHOSTTY_VT_PREFIX).".}
  elif firstMissingVtType().len > 0:
    {.error: "libghostty-vt headers in " & ghosttyVtInclude & " are too old " &
      "for ghostnim (no " & firstMissingVtType() & "). Rebuild with " &
      "`rm -rf vendor/ghostty-vt && nimble vt`.".}

{.pragma: vt, importc, header: vtHeader.}
{.pragma: vtType, importc, header: vtHeader, bycopy.}
{.pragma: vtSized, importc, header: vtHeader, bycopy, incompleteStruct.}

type
  GhosttyResult* = cint

  GhosttyTerminal* = distinct pointer
  GhosttyRenderState* = distinct pointer
  GhosttyRenderStateRowIterator* = distinct pointer
  GhosttyRenderStateRowCells* = distinct pointer
  GhosttyKeyEncoder* = distinct pointer
  GhosttyKeyEvent* = distinct pointer
  GhosttyMouseEncoder* = distinct pointer
  GhosttyMouseEvent* = distinct pointer
  GhosttyFormatter* = distinct pointer

  GhosttyCell* = uint64
  GhosttyMods* = uint16
  GhosttyMode* = uint16

  GhosttyString* {.vtType.} = object
    `ptr`*: ptr UncheckedArray[uint8]
    len*: csize_t

  GhosttyBuffer* {.vtType.} = object
    `ptr`*: ptr UncheckedArray[uint8]
    cap*: csize_t
    len*: csize_t

  GhosttyColorRgb* {.vtType.} = object
    r*, g*, b*: uint8

  GhosttyStyleColorValue* {.importc, header: vtHeader, union, bycopy.} = object
    palette*: uint8
    rgb*: GhosttyColorRgb
    padding {.importc: "_padding".}: uint64

  GhosttyStyleColor* {.vtType.} = object
    tag*: cint
    value*: GhosttyStyleColorValue

  GhosttyStyle* {.vtSized.} = object
    size*: csize_t
    fg_color*: GhosttyStyleColor
    bg_color*: GhosttyStyleColor
    underline_color*: GhosttyStyleColor
    bold*, italic*, faint*, blink*, inverse*, invisible*, strikethrough*,
      overline*: bool
    underline*: cint

  GhosttyRenderStateColors* {.vtSized.} = object
    size*: csize_t
    background*: GhosttyColorRgb
    foreground*: GhosttyColorRgb
    cursor*: GhosttyColorRgb
    cursor_has_value*: bool
    palette*: array[256, GhosttyColorRgb]

  GhosttyRenderStateCursor* {.vtSized.} = object
    size*: csize_t
    viewport_has_value*: bool
    viewport_x*: uint16
    viewport_y*: uint16
    wide_tail*: bool
    visible*: bool
    blinking*: bool
    password_input*: bool
    visual_style*: cint

  GhosttyRenderStateRowSelection* {.vtSized.} = object
    size*: csize_t
    start_x*: uint16
    end_x*: uint16

  GhosttyPointCoordinate* {.vtType.} = object
    x*: uint16
    y*: uint32

  GhosttyPointValue* {.importc, header: vtHeader, union, bycopy.} = object
    coordinate*: GhosttyPointCoordinate
    padding {.importc: "_padding".}: array[2, uint64]

  GhosttyPoint* {.vtType.} = object
    tag*: cint
    value*: GhosttyPointValue

  GhosttyGridRef* {.vtSized.} = object
    size*: csize_t
    node*: pointer
    x*: uint16
    y*: uint16

  GhosttySelection* {.vtSized.} = object
    size*: csize_t
    start*: GhosttyGridRef
    `end`*: GhosttyGridRef
    rectangle*: bool

  GhosttyTerminalScrollViewportValue* {.importc, header: vtHeader, union, bycopy.} = object
    delta*: int
    row*: csize_t
    padding {.importc: "_padding".}: array[2, uint64]

  GhosttyTerminalScrollViewport* {.vtType.} = object
    tag*: cint
    value*: GhosttyTerminalScrollViewportValue

  GhosttyTerminalModeConfig* {.vtType.} = object
    mode*: GhosttyMode
    value*: bool

  GhosttyMousePosition* {.vtType.} = object
    x*, y*: cfloat

  GhosttyMouseEncoderSize* {.vtSized.} = object
    size*: csize_t
    screen_width*, screen_height*: uint32
    cell_width*, cell_height*: uint32
    padding_top*, padding_bottom*, padding_right*, padding_left*: uint32

  GhosttyFormatterScreenExtra* {.vtSized.} = object
    size*: csize_t
    cursor*, style*, hyperlink*, protection*, kitty_keyboard*, charsets*: bool

  GhosttyFormatterTerminalExtra* {.vtSized.} = object
    size*: csize_t
    palette*, modes*, scrolling_region*, tabstops*, pwd*, keyboard*: bool
    screen*: GhosttyFormatterScreenExtra

  GhosttyFormatterTerminalOptions* {.vtSized.} = object
    size*: csize_t
    emit*: cint
    unwrap*: bool
    trim*: bool
    extra*: GhosttyFormatterTerminalExtra
    selection*: ptr GhosttySelection

  GhosttyTerminalWritePtyFn* = proc (t: GhosttyTerminal, userdata: pointer,
                                     data: ptr uint8, len: csize_t) {.cdecl.}
  GhosttyTerminalCallbackFn* = proc (t: GhosttyTerminal, userdata: pointer) {.cdecl.}

include keys

const
  # GhosttyResult
  GHOSTTY_SUCCESS* = 0.GhosttyResult
  GHOSTTY_NO_VALUE* = -4.GhosttyResult

  # GhosttyStyleColorTag
  GHOSTTY_STYLE_COLOR_NONE* = 0.cint
  GHOSTTY_STYLE_COLOR_PALETTE* = 1.cint
  GHOSTTY_STYLE_COLOR_RGB* = 2.cint

  # GhosttySgrUnderline (subset)
  GHOSTTY_SGR_UNDERLINE_NONE* = 0.cint
  GHOSTTY_SGR_UNDERLINE_DOUBLE* = 2.cint
  GHOSTTY_SGR_UNDERLINE_CURLY* = 3.cint

  # GhosttyTerminalOption
  GHOSTTY_TERMINAL_OPT_USERDATA* = 0.cint
  GHOSTTY_TERMINAL_OPT_WRITE_PTY* = 1.cint
  GHOSTTY_TERMINAL_OPT_BELL* = 2.cint
  GHOSTTY_TERMINAL_OPT_TITLE_CHANGED* = 5.cint
  GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND* = 11.cint
  GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND* = 12.cint
  GHOSTTY_TERMINAL_OPT_COLOR_CURSOR* = 13.cint
  GHOSTTY_TERMINAL_OPT_SELECTION* = 21.cint
  GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES* = 28.cint

  # GhosttyTerminalData
  GHOSTTY_TERMINAL_DATA_COLS* = 1.cint
  GHOSTTY_TERMINAL_DATA_ROWS* = 2.cint
  GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING* = 11.cint
  GHOSTTY_TERMINAL_DATA_TITLE* = 12.cint
  GHOSTTY_TERMINAL_DATA_SELECTION* = 31.cint
  GHOSTTY_TERMINAL_DATA_MODE* = 37.cint

  # GhosttyTerminalScrollViewportTag
  GHOSTTY_SCROLL_VIEWPORT_TOP* = 0.cint
  GHOSTTY_SCROLL_VIEWPORT_BOTTOM* = 1.cint
  GHOSTTY_SCROLL_VIEWPORT_DELTA* = 2.cint

  # GhosttyPointTag
  GHOSTTY_POINT_TAG_ACTIVE* = 0.cint
  GHOSTTY_POINT_TAG_VIEWPORT* = 1.cint

  # GhosttyRenderStateDirty
  GHOSTTY_RENDER_STATE_DIRTY_FALSE* = 0.cint
  GHOSTTY_RENDER_STATE_DIRTY_PARTIAL* = 1.cint
  GHOSTTY_RENDER_STATE_DIRTY_FULL* = 2.cint

  # GhosttyRenderStateCursorVisualStyle
  GHOSTTY_CURSOR_BAR* = 0.cint
  GHOSTTY_CURSOR_BLOCK* = 1.cint
  GHOSTTY_CURSOR_UNDERLINE* = 2.cint
  GHOSTTY_CURSOR_BLOCK_HOLLOW* = 3.cint

  # GhosttyRenderStateData
  GHOSTTY_RENDER_STATE_DATA_COLS* = 1.cint
  GHOSTTY_RENDER_STATE_DATA_ROWS* = 2.cint
  GHOSTTY_RENDER_STATE_DATA_DIRTY* = 3.cint
  GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR* = 4.cint
  GHOSTTY_RENDER_STATE_DATA_CURSOR* = 18.cint
  GHOSTTY_RENDER_STATE_DATA_COLORS* = 19.cint

  # GhosttyRenderStateRowData
  GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY* = 1.cint
  GHOSTTY_RENDER_STATE_ROW_DATA_CELLS* = 3.cint
  GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION* = 4.cint

  # GhosttyRenderStateRowCellsData
  GHOSTTY_CELLS_DATA_RAW* = 1.cint
  GHOSTTY_CELLS_DATA_STYLE* = 2.cint
  GHOSTTY_CELLS_DATA_GRAPHEMES_LEN* = 3.cint
  GHOSTTY_CELLS_DATA_BG_COLOR* = 5.cint
  GHOSTTY_CELLS_DATA_FG_COLOR* = 6.cint
  GHOSTTY_CELLS_DATA_GRAPHEMES_UTF8* = 9.cint

  # GhosttyRenderStateRowOption
  GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY* = 0.cint

  # GhosttyCellData / GhosttyCellWide
  GHOSTTY_CELL_DATA_WIDE* = 3.cint
  GHOSTTY_CELL_WIDE_NARROW* = 0.cint
  GHOSTTY_CELL_WIDE_WIDE* = 1.cint
  GHOSTTY_CELL_WIDE_SPACER_TAIL* = 2.cint

  # Key actions / mods
  GHOSTTY_KEY_ACTION_RELEASE* = 0.cint
  GHOSTTY_KEY_ACTION_PRESS* = 1.cint
  GHOSTTY_KEY_ACTION_REPEAT* = 2.cint
  GHOSTTY_MODS_SHIFT* = 1'u16 shl 0
  GHOSTTY_MODS_CTRL* = 1'u16 shl 1
  GHOSTTY_MODS_ALT* = 1'u16 shl 2
  GHOSTTY_MODS_SUPER* = 1'u16 shl 3
  GHOSTTY_MODS_CAPS_LOCK* = 1'u16 shl 4
  GHOSTTY_MODS_NUM_LOCK* = 1'u16 shl 5

  # Mouse
  GHOSTTY_MOUSE_ACTION_PRESS* = 0.cint
  GHOSTTY_MOUSE_ACTION_RELEASE* = 1.cint
  GHOSTTY_MOUSE_ACTION_MOTION* = 2.cint
  GHOSTTY_MOUSE_BUTTON_LEFT* = 1.cint
  GHOSTTY_MOUSE_BUTTON_RIGHT* = 2.cint
  GHOSTTY_MOUSE_BUTTON_MIDDLE* = 3.cint
  GHOSTTY_MOUSE_BUTTON_FOUR* = 4.cint   # wheel up
  GHOSTTY_MOUSE_BUTTON_FIVE* = 5.cint   # wheel down
  GHOSTTY_MOUSE_ENCODER_OPT_SIZE* = 2.cint
  GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED* = 3.cint

  # GhosttyFormatterFormat
  GHOSTTY_FORMATTER_FORMAT_PLAIN* = 0.cint

proc ghostty_mode_new*(value: uint16, ansi: bool): GhosttyMode {.vt.}

# Allocation
proc ghostty_free*(allocator: pointer, p: pointer, len: csize_t) {.vt.}

# Terminal
proc ghostty_terminal_new*(allocator: pointer, terminal: ptr GhosttyTerminal,
                           cols, rows: uint16): GhosttyResult {.vt.}
proc ghostty_terminal_free*(terminal: GhosttyTerminal) {.vt.}
proc ghostty_terminal_resize*(terminal: GhosttyTerminal, cols, rows: uint16,
                              cellWidthPx, cellHeightPx: uint32): GhosttyResult {.vt.}
proc ghostty_terminal_set*(terminal: GhosttyTerminal, option: cint,
                           value: pointer): GhosttyResult {.vt.}
proc ghostty_terminal_get*(terminal: GhosttyTerminal, data: cint,
                           outp: pointer): GhosttyResult {.vt.}
proc ghostty_terminal_vt_write*(terminal: GhosttyTerminal, data: ptr uint8,
                                len: csize_t) {.vt.}
proc ghostty_terminal_scroll_viewport*(terminal: GhosttyTerminal,
                                       behavior: GhosttyTerminalScrollViewport) {.vt.}
proc ghostty_terminal_grid_ref*(terminal: GhosttyTerminal, point: GhosttyPoint,
                                outRef: ptr GhosttyGridRef): GhosttyResult {.vt.}

proc ghostty_cell_get*(cell: GhosttyCell, data: cint, outp: pointer): GhosttyResult {.vt.}

# Render state
proc ghostty_render_state_new*(allocator: pointer,
                               state: ptr GhosttyRenderState): GhosttyResult {.vt.}
proc ghostty_render_state_free*(state: GhosttyRenderState) {.vt.}
proc ghostty_render_state_update*(state: GhosttyRenderState,
                                  terminal: GhosttyTerminal): GhosttyResult {.vt.}
proc ghostty_render_state_clean*(state: GhosttyRenderState): GhosttyResult {.vt.}
proc ghostty_render_state_get*(state: GhosttyRenderState, data: cint,
                               outp: pointer): GhosttyResult {.vt.}
proc ghostty_render_state_row_iterator_new*(allocator: pointer,
    outIter: ptr GhosttyRenderStateRowIterator): GhosttyResult {.vt.}
proc ghostty_render_state_row_iterator_free*(it: GhosttyRenderStateRowIterator) {.vt.}
proc ghostty_render_state_row_iterator_next*(it: GhosttyRenderStateRowIterator): bool {.vt.}
proc ghostty_render_state_row_get*(it: GhosttyRenderStateRowIterator, data: cint,
                                   outp: pointer): GhosttyResult {.vt.}
proc ghostty_render_state_row_set*(it: GhosttyRenderStateRowIterator, option: cint,
                                   value: pointer): GhosttyResult {.vt.}
proc ghostty_render_state_row_cells_new*(allocator: pointer,
    outCells: ptr GhosttyRenderStateRowCells): GhosttyResult {.vt.}
proc ghostty_render_state_row_cells_free*(cells: GhosttyRenderStateRowCells) {.vt.}
proc ghostty_render_state_row_cells_next*(cells: GhosttyRenderStateRowCells): bool {.vt.}
proc ghostty_render_state_row_cells_get*(cells: GhosttyRenderStateRowCells,
                                         data: cint, outp: pointer): GhosttyResult {.vt.}

# Key encoding
proc ghostty_key_encoder_new*(allocator: pointer,
                              encoder: ptr GhosttyKeyEncoder): GhosttyResult {.vt.}
proc ghostty_key_encoder_free*(encoder: GhosttyKeyEncoder) {.vt.}
proc ghostty_key_encoder_setopt_from_terminal*(encoder: GhosttyKeyEncoder,
                                               terminal: GhosttyTerminal) {.vt.}
proc ghostty_key_encoder_encode*(encoder: GhosttyKeyEncoder, event: GhosttyKeyEvent,
                                 outBuf: cstring, outBufSize: csize_t,
                                 outLen: ptr csize_t): GhosttyResult {.vt.}
proc ghostty_key_event_new*(allocator: pointer,
                            event: ptr GhosttyKeyEvent): GhosttyResult {.vt.}
proc ghostty_key_event_free*(event: GhosttyKeyEvent) {.vt.}
proc ghostty_key_event_set_action*(event: GhosttyKeyEvent, action: cint) {.vt.}
proc ghostty_key_event_set_key*(event: GhosttyKeyEvent, key: GhosttyKey) {.vt.}
proc ghostty_key_event_set_mods*(event: GhosttyKeyEvent, mods: GhosttyMods) {.vt.}
proc ghostty_key_event_set_consumed_mods*(event: GhosttyKeyEvent, mods: GhosttyMods) {.vt.}
proc ghostty_key_event_set_utf8*(event: GhosttyKeyEvent, utf8: cstring, len: csize_t) {.vt.}
proc ghostty_key_event_set_unshifted_codepoint*(event: GhosttyKeyEvent,
                                                codepoint: uint32) {.vt.}

# Mouse encoding
proc ghostty_mouse_encoder_new*(allocator: pointer,
                                encoder: ptr GhosttyMouseEncoder): GhosttyResult {.vt.}
proc ghostty_mouse_encoder_free*(encoder: GhosttyMouseEncoder) {.vt.}
proc ghostty_mouse_encoder_setopt*(encoder: GhosttyMouseEncoder, option: cint,
                                   value: pointer) {.vt.}
proc ghostty_mouse_encoder_setopt_from_terminal*(encoder: GhosttyMouseEncoder,
                                                 terminal: GhosttyTerminal) {.vt.}
proc ghostty_mouse_encoder_encode*(encoder: GhosttyMouseEncoder, event: GhosttyMouseEvent,
                                   outBuf: cstring, outBufSize: csize_t,
                                   outLen: ptr csize_t): GhosttyResult {.vt.}
proc ghostty_mouse_event_new*(allocator: pointer,
                              event: ptr GhosttyMouseEvent): GhosttyResult {.vt.}
proc ghostty_mouse_event_free*(event: GhosttyMouseEvent) {.vt.}
proc ghostty_mouse_event_set_action*(event: GhosttyMouseEvent, action: cint) {.vt.}
proc ghostty_mouse_event_set_button*(event: GhosttyMouseEvent, button: cint) {.vt.}
proc ghostty_mouse_event_clear_button*(event: GhosttyMouseEvent) {.vt.}
proc ghostty_mouse_event_set_mods*(event: GhosttyMouseEvent, mods: GhosttyMods) {.vt.}
proc ghostty_mouse_event_set_position*(event: GhosttyMouseEvent,
                                       position: GhosttyMousePosition) {.vt.}

# Paste encoding
proc ghostty_paste_encode*(data: cstring, dataLen: csize_t, bracketed: bool,
                           buf: cstring, bufLen: csize_t,
                           outWritten: ptr csize_t): GhosttyResult {.vt.}

# Formatter (used for copying the selection as plain text)
proc ghostty_formatter_terminal_new*(allocator: pointer, formatter: ptr GhosttyFormatter,
                                     terminal: GhosttyTerminal,
                                     options: GhosttyFormatterTerminalOptions): GhosttyResult {.vt.}
proc ghostty_formatter_format_alloc*(formatter: GhosttyFormatter, allocator: pointer,
                                     outPtr: ptr ptr uint8,
                                     outLen: ptr csize_t): GhosttyResult {.vt.}
proc ghostty_formatter_free*(formatter: GhosttyFormatter) {.vt.}

proc isNil*(p: GhosttyTerminal | GhosttyRenderState | GhosttyRenderStateRowIterator |
            GhosttyRenderStateRowCells | GhosttyKeyEncoder | GhosttyKeyEvent |
            GhosttyMouseEncoder | GhosttyMouseEvent | GhosttyFormatter): bool =
  pointer(p) == nil

template initSized*[T](t: typedesc[T]): T =
  ## Equivalent of GHOSTTY_INIT_SIZED(T): zeroed with `size` set.
  var v: T
  v.size = csize_t(sizeof(T))
  v
