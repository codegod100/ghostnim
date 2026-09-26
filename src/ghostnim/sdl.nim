## Minimal SDL2 + SDL2_ttf bindings (just what ghostnim uses).
##
## Types are imported from the real SDL headers so layouts are always right.

{.passL: "-lSDL2 -lSDL2_ttf".}

const
  sdlHeader = "<SDL2/SDL.h>"
  ttfHeader = "<SDL2/SDL_ttf.h>"

{.pragma: sdl, importc, header: sdlHeader.}
{.pragma: sdlType, importc, header: sdlHeader, bycopy, incompleteStruct.}
{.pragma: ttf, importc, header: ttfHeader.}

type
  SdlWindow* {.importc: "SDL_Window", header: sdlHeader, incompleteStruct.} = object
  SdlRenderer* {.importc: "SDL_Renderer", header: sdlHeader, incompleteStruct.} = object
  Texture* {.importc: "SDL_Texture", header: sdlHeader, incompleteStruct.} = object
  SdlThread* {.importc: "SDL_Thread", header: sdlHeader, incompleteStruct.} = object
  Font* {.importc: "TTF_Font", header: ttfHeader, incompleteStruct.} = object

  WindowPtr* = ptr SdlWindow
  RendererPtr* = ptr SdlRenderer
  TexturePtr* = ptr Texture
  FontPtr* = ptr Font

  Color* {.importc: "SDL_Color", header: sdlHeader, bycopy.} = object
    r*, g*, b*, a*: uint8

  Rect* {.importc: "SDL_Rect", header: sdlHeader, bycopy.} = object
    x*, y*, w*, h*: cint

  Surface* {.importc: "SDL_Surface", header: sdlHeader, incompleteStruct.} = object
    w*, h*: cint
    pitch*: cint
    pixels*: pointer
  SurfacePtr* = ptr Surface

  Keysym* {.sdlType, importc: "SDL_Keysym".} = object
    scancode*: cint
    sym*: int32
    `mod`*: uint16

  KeyboardEvent* {.sdlType, importc: "SDL_KeyboardEvent".} = object
    `type`*: uint32
    windowID*: uint32
    state*: uint8
    repeat*: uint8
    keysym*: Keysym

  TextInputEvent* {.sdlType, importc: "SDL_TextInputEvent".} = object
    `type`*: uint32
    text*: array[32, char]

  WindowEvent* {.sdlType, importc: "SDL_WindowEvent".} = object
    `type`*: uint32
    event*: uint8
    data1*, data2*: int32

  MouseButtonEvent* {.sdlType, importc: "SDL_MouseButtonEvent".} = object
    `type`*: uint32
    button*: uint8
    state*: uint8
    clicks*: uint8
    x*, y*: int32

  MouseMotionEvent* {.sdlType, importc: "SDL_MouseMotionEvent".} = object
    `type`*: uint32
    state*: uint32
    x*, y*: int32

  MouseWheelEvent* {.sdlType, importc: "SDL_MouseWheelEvent".} = object
    `type`*: uint32
    x*, y*: int32
    direction*: uint32

  UserEvent* {.sdlType, importc: "SDL_UserEvent".} = object
    `type`*: uint32
    code*: int32

  Event* {.importc: "SDL_Event", header: sdlHeader, union, bycopy.} = object
    `type`*: uint32
    key*: KeyboardEvent
    text*: TextInputEvent
    window*: WindowEvent
    button*: MouseButtonEvent
    motion*: MouseMotionEvent
    wheel*: MouseWheelEvent
    user*: UserEvent
    padding: array[56, uint8]

  AtomicInt* {.importc: "SDL_atomic_t", header: sdlHeader, bycopy.} = object
    value: cint

  ThreadFunction* = proc (data: pointer): cint {.cdecl.}

const
  INIT_VIDEO* = 0x00000020'u32
  INIT_EVENTS* = 0x00004000'u32

  WINDOWPOS_CENTERED* = 0x2FFF0000'i32
  WINDOW_RESIZABLE* = 0x00000020'u32
  WINDOW_ALLOW_HIGHDPI* = 0x00002000'u32

  RENDERER_ACCELERATED* = 0x00000002'u32
  RENDERER_PRESENTVSYNC* = 0x00000004'u32
  RENDERER_TARGETTEXTURE* = 0x00000008'u32

  PIXELFORMAT_ARGB8888* = 0x16362004'u32
  TEXTUREACCESS_TARGET* = 2.cint
  BLENDMODE_NONE* = 0.cint
  BLENDMODE_BLEND* = 1.cint
  SCALEMODE_LINEAR* = 1.cint

  # Event types
  EV_QUIT* = 0x100'u32
  EV_WINDOW* = 0x200'u32
  EV_KEYDOWN* = 0x300'u32
  EV_KEYUP* = 0x301'u32
  EV_TEXTINPUT* = 0x303'u32
  EV_MOUSEMOTION* = 0x400'u32
  EV_MOUSEBUTTONDOWN* = 0x401'u32
  EV_MOUSEBUTTONUP* = 0x402'u32
  EV_MOUSEWHEEL* = 0x403'u32
  EV_USER* = 0x8000'u32

  # Window event ids
  WINDOWEVENT_EXPOSED* = 3'u8
  WINDOWEVENT_SIZE_CHANGED* = 6'u8
  WINDOWEVENT_FOCUS_GAINED* = 12'u8
  WINDOWEVENT_FOCUS_LOST* = 13'u8

  BUTTON_LEFT* = 1'u8
  BUTTON_MIDDLE* = 2'u8
  BUTTON_RIGHT* = 3'u8
  MOUSEWHEEL_FLIPPED* = 1'u32

  # Keymods
  KMOD_LSHIFT* = 0x0001'u16
  KMOD_RSHIFT* = 0x0002'u16
  KMOD_LCTRL* = 0x0040'u16
  KMOD_RCTRL* = 0x0080'u16
  KMOD_LALT* = 0x0100'u16
  KMOD_RALT* = 0x0200'u16
  KMOD_LGUI* = 0x0400'u16
  KMOD_RGUI* = 0x0800'u16
  KMOD_NUM* = 0x1000'u16
  KMOD_CAPS* = 0x2000'u16
  KMOD_SHIFT* = KMOD_LSHIFT or KMOD_RSHIFT
  KMOD_CTRL* = KMOD_LCTRL or KMOD_RCTRL
  KMOD_ALT* = KMOD_LALT or KMOD_RALT
  KMOD_GUI* = KMOD_LGUI or KMOD_RGUI

  TTF_STYLE_NORMAL* = 0.cint
  TTF_STYLE_BOLD* = 1.cint
  TTF_STYLE_ITALIC* = 2.cint

proc init*(flags: uint32): cint {.sdl, importc: "SDL_Init".}
proc quit*() {.sdl, importc: "SDL_Quit".}
proc getError*(): cstring {.sdl, importc: "SDL_GetError".}
proc setHint*(name, value: cstring): bool {.sdl, importc: "SDL_SetHint".}

proc createWindow*(title: cstring, x, y, w, h: cint, flags: uint32): WindowPtr {.
  sdl, importc: "SDL_CreateWindow".}
proc destroyWindow*(w: WindowPtr) {.sdl, importc: "SDL_DestroyWindow".}
proc setWindowTitle*(w: WindowPtr, title: cstring) {.sdl, importc: "SDL_SetWindowTitle".}
proc setWindowSize*(w: WindowPtr, width, height: cint) {.sdl, importc: "SDL_SetWindowSize".}
proc getWindowSize*(w: WindowPtr, width, height: ptr cint) {.sdl, importc: "SDL_GetWindowSize".}

proc createRenderer*(w: WindowPtr, index: cint, flags: uint32): RendererPtr {.
  sdl, importc: "SDL_CreateRenderer".}
proc destroyRenderer*(r: RendererPtr) {.sdl, importc: "SDL_DestroyRenderer".}
proc getRendererOutputSize*(r: RendererPtr, w, h: ptr cint): cint {.
  sdl, importc: "SDL_GetRendererOutputSize".}
proc setRenderDrawColor*(r: RendererPtr, red, green, blue, alpha: uint8): cint {.
  sdl, importc: "SDL_SetRenderDrawColor".}
proc setRenderDrawBlendMode*(r: RendererPtr, mode: cint): cint {.
  sdl, importc: "SDL_SetRenderDrawBlendMode".}
proc renderClear*(r: RendererPtr): cint {.sdl, importc: "SDL_RenderClear".}
proc renderFillRect*(r: RendererPtr, rect: ptr Rect): cint {.sdl, importc: "SDL_RenderFillRect".}
proc renderDrawRect*(r: RendererPtr, rect: ptr Rect): cint {.sdl, importc: "SDL_RenderDrawRect".}
proc renderDrawLine*(r: RendererPtr, x1, y1, x2, y2: cint): cint {.
  sdl, importc: "SDL_RenderDrawLine".}
proc renderCopy*(r: RendererPtr, t: TexturePtr, src, dst: ptr Rect): cint {.
  sdl, importc: "SDL_RenderCopy".}
proc renderPresent*(r: RendererPtr) {.sdl, importc: "SDL_RenderPresent".}
proc setRenderTarget*(r: RendererPtr, t: TexturePtr): cint {.sdl, importc: "SDL_SetRenderTarget".}
proc renderReadPixels*(r: RendererPtr, rect: ptr Rect, format: uint32, pixels: pointer,
                       pitch: cint): cint {.sdl, importc: "SDL_RenderReadPixels".}

proc createTexture*(r: RendererPtr, format: uint32, access, w, h: cint): TexturePtr {.
  sdl, importc: "SDL_CreateTexture".}
proc createTextureFromSurface*(r: RendererPtr, s: SurfacePtr): TexturePtr {.
  sdl, importc: "SDL_CreateTextureFromSurface".}
proc destroyTexture*(t: TexturePtr) {.sdl, importc: "SDL_DestroyTexture".}
proc setTextureColorMod*(t: TexturePtr, r, g, b: uint8): cint {.
  sdl, importc: "SDL_SetTextureColorMod".}
proc setTextureScaleMode*(t: TexturePtr, mode: cint): cint {.
  sdl, importc: "SDL_SetTextureScaleMode".}
proc setTextureAlphaMod*(t: TexturePtr, a: uint8): cint {.sdl, importc: "SDL_SetTextureAlphaMod".}
proc setTextureBlendMode*(t: TexturePtr, mode: cint): cint {.
  sdl, importc: "SDL_SetTextureBlendMode".}
proc freeSurface*(s: SurfacePtr) {.sdl, importc: "SDL_FreeSurface".}
proc rwFromConstMem*(mem: pointer, size: cint): pointer {.sdl, importc: "SDL_RWFromConstMem".}
proc loadBMP_RW*(src: pointer, freesrc: cint): SurfacePtr {.sdl, importc: "SDL_LoadBMP_RW".}
proc setWindowIcon*(w: WindowPtr, icon: SurfacePtr) {.sdl, importc: "SDL_SetWindowIcon".}

proc pollEvent*(e: ptr Event): cint {.sdl, importc: "SDL_PollEvent".}
proc waitEventTimeout*(e: ptr Event, timeout: cint): cint {.sdl, importc: "SDL_WaitEventTimeout".}
proc pushEvent*(e: ptr Event): cint {.sdl, importc: "SDL_PushEvent".}
proc registerEvents*(n: cint): uint32 {.sdl, importc: "SDL_RegisterEvents".}
proc startTextInput*() {.sdl, importc: "SDL_StartTextInput".}
proc getMouseState*(x, y: ptr cint): uint32 {.sdl, importc: "SDL_GetMouseState".}
proc getModState*(): uint16 {.sdl, importc: "SDL_GetModState".}
proc getTicks*(): uint32 {.sdl, importc: "SDL_GetTicks".}

proc setClipboardText*(text: cstring): cint {.sdl, importc: "SDL_SetClipboardText".}
proc getClipboardText*(): cstring {.sdl, importc: "SDL_GetClipboardText".}
proc hasClipboardText*(): cint {.sdl, importc: "SDL_HasClipboardText".}
proc sdlFree*(p: pointer) {.sdl, importc: "SDL_free".}

proc atomicSet*(a: ptr AtomicInt, v: cint): cint {.sdl, importc: "SDL_AtomicSet", discardable.}
proc atomicGet*(a: ptr AtomicInt): cint {.sdl, importc: "SDL_AtomicGet".}
proc sdlCreateThread*(fn: ThreadFunction, name: cstring, data: pointer): ptr SdlThread {.
  sdl, importc: "SDL_CreateThread".}
proc sdlDetachThread*(t: ptr SdlThread) {.sdl, importc: "SDL_DetachThread".}
proc sdlWaitThread*(t: ptr SdlThread, status: ptr cint) {.sdl, importc: "SDL_WaitThread".}

# SDL_ttf
proc ttfInit*(): cint {.ttf, importc: "TTF_Init".}
proc ttfQuit*() {.ttf, importc: "TTF_Quit".}
proc openFont*(file: cstring, ptsize: cint): FontPtr {.ttf, importc: "TTF_OpenFont".}
proc closeFont*(f: FontPtr) {.ttf, importc: "TTF_CloseFont".}
proc setFontStyle*(f: FontPtr, style: cint) {.ttf, importc: "TTF_SetFontStyle".}
proc fontHeight*(f: FontPtr): cint {.ttf, importc: "TTF_FontHeight".}
proc fontAscent*(f: FontPtr): cint {.ttf, importc: "TTF_FontAscent".}
proc fontLineSkip*(f: FontPtr): cint {.ttf, importc: "TTF_FontLineSkip".}
proc glyphMetrics32*(f: FontPtr, ch: uint32, minx, maxx, miny, maxy, advance: ptr cint): cint {.
  ttf, importc: "TTF_GlyphMetrics32".}
proc glyphIsProvided32*(f: FontPtr, ch: uint32): cint {.ttf, importc: "TTF_GlyphIsProvided32".}
proc renderUTF8Blended*(f: FontPtr, text: cstring, fg: Color): SurfacePtr {.
  ttf, importc: "TTF_RenderUTF8_Blended".}
