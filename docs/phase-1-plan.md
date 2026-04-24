# Phase 1 — Skeleton MiSTer Backend (Implementation Plan)

**Document date:** 2026-04-24
**Status:** Plan (pre-implementation). Each step below is a self-contained `/implement` unit.
**Companion docs:** [mister-port-research.md](mister-port-research.md), [mister-port-plan.md](mister-port-plan.md).

---

## Goal

Produce a skeleton `MiSTerRenderDevice` backend for RSDKv5 that **compiles, links, and logs init/shutdown** on Mac (via `Darwin.cmake` path) and is ready to cross-compile to MiSTer armhf once Phase 0 lands. **No pixels.** Pixel output is Phase 2.

---

## Baked-in decisions (not revisitable)

| # | Decision | Value |
|---|---|---|
| 1 | Internal resolution | 320×240 4:3. `pixWidth=320` — wiring is Phase 2. |
| 3 | Platform identity | `RETRO_LINUX` (via `__linux__` on armhf). Do NOT add `RETRO_MISTER` ID to `RetroEngine.hpp` platform chain. |
| 4 | Game binary shape | `GAME_STATIC=ON`. |
| 5 | Cutscenes | Stubs ship empty. Actual stubbing is later. |

---

## Key resolved design question: `RETRO_RENDERDEVICE_MISTER` selection

### Background facts (verified in source)

1. **`RetroEngine.hpp` lines 163-169** declare every `RETRO_RENDERDEVICE_*` macro as `(0)` by default. Lines 260-420 then `#undef`/`#define` them based on `RETRO_PLATFORM` + an `RSDK_USE_<SUBSYSTEM>` define. Command-line `-DRETRO_RENDERDEVICE_MISTER=1` would be clobbered by line ~164 unless we also patch the block.
2. **`dependencies/RSDKv5/CMakeLists.txt:155`** emits `RSDK_USE_${RETRO_SUBSYSTEM}=1` as a compile define. With `-DRETRO_SUBSYSTEM=MiSTer`, this produces `RSDK_USE_MISTER=1`.
3. **`RetroEngine.hpp:330-365`** is the `#elif RETRO_PLATFORM == RETRO_LINUX` branch; it already selects SDL2/OGL/VK based on `RSDK_USE_SDL2` / `RSDK_USE_OGL` / `RSDK_USE_VK`. Adding `RSDK_USE_MISTER` here is the upstream-pattern-consistent extension point.
4. **`dependencies/RSDKv5/CMakeLists.txt:68`** does `include(platforms/${PLATFORM}.cmake)`. A new `MiSTer.cmake` is loaded when `-DPLATFORM=MiSTer`, but loading that file does **not** set `RETRO_PLATFORM` (that's all driven by compiler predefines like `__linux__`, `__APPLE__`, etc.). The `PLATFORM` CMake variable only chooses which `.cmake` is read.

### Decision

Use a **two-layer** selection mechanism that mirrors upstream precedent exactly:

**Layer A — Upstream-patched `RetroEngine.hpp`** (the ONLY upstream `.hpp` patch beyond Drawing.hpp):

Add to `RetroEngine.hpp` line 169 area (the block of `(0)` defaults):
```cpp
#define RETRO_RENDERDEVICE_MISTER (0)
```

Add an `#elif defined(RSDK_USE_MISTER)` arm inside the existing `#if RETRO_PLATFORM == RETRO_LINUX` block (lines 330-365). Intended insertion point: after the existing `RSDK_USE_VK` arm but before the closing `#else #error`. New arm:
```cpp
#elif defined(RSDK_USE_MISTER)
#undef RETRO_RENDERDEVICE_MISTER
#define RETRO_RENDERDEVICE_MISTER (1)
#undef RETRO_INPUTDEVICE_SDL2
#define RETRO_INPUTDEVICE_SDL2 (1)

#undef RETRO_AUDIODEVICE_MINI
#define RETRO_AUDIODEVICE_MINI (0)
#undef RETRO_AUDIODEVICE_SDL2
#define RETRO_AUDIODEVICE_SDL2 (1)
```

Also extend the `#else #error RSDK_USE_SDL2, RSDK_USE_OGL or RSDK_USE_VK must be defined.` message (line ~364) to mention `RSDK_USE_MISTER`.

**Rationale:** The pattern of `RSDK_USE_<X>` → selecting a `RETRO_RENDERDEVICE_<X>` inside the platform `#elif` block is the upstream-idiomatic way every other backend selects itself. We extend it by symmetry. The patch is small (<15 lines), guarded in a way that doesn't affect any other code path, and means NO upstream files break for any non-MiSTer build.

**Layer B — `MiSTer.cmake` driven by `-DPLATFORM=MiSTer`**:

`include(platforms/MiSTer.cmake)` fires when the user passes `-DPLATFORM=MiSTer`. That file:
- Sets `RETRO_SUBSYSTEM` to `MiSTer` (so submodule-side line 155 emits `RSDK_USE_MISTER=1`).
- Adds `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` to the build.
- Links SDL2 (for input + audio — per decision #3, the engine is `RETRO_LINUX` and its audio/input paths already use SDL2).
- On armhf targets, sets ARM hardening flags (mirrors 3sx's `ENABLE_MISTER_ARM_HARDENING` block).

**Mac iteration path:** User passes `-DPLATFORM=MiSTer` on Mac. `MiSTer.cmake` detects `CMAKE_SYSTEM_NAME==Darwin` (or absence of armhf target) and skips ARM hardening, but still compiles `MiSTerRenderDevice.cpp` and emits `RSDK_USE_MISTER=1`. Crucially, `__APPLE__` is still defined by the host compiler, so `RETRO_PLATFORM==RETRO_OSX` — meaning the Linux `#elif` block above never runs, and we need a SECOND small `#elif RETRO_PLATFORM == RETRO_OSX` arm for `RSDK_USE_MISTER` that mirrors the Linux one. This is intentional: Mac-hosted skeleton builds *must* be able to exercise the MiSTer backend selection to produce the log output that is the Phase 1 exit criterion.

**Summary:**
- ONE CMake entry point (`-DPLATFORM=MiSTer`), which cascades into `RETRO_SUBSYSTEM=MiSTer` → `RSDK_USE_MISTER=1`.
- TWO small `RetroEngine.hpp` patch sites (Linux arm + OSX arm). Both purely additive.
- Zero changes to the `RETRO_PLATFORM` ID chain (decision #3 honoured).
- Submodule upstream platform detection unaffected for all other builds.

---

## Phase 1 scope limits (what NOT to do)

- Do NOT wire `NativeVideoWriter.{h,c}` — that's Phase 2.
- Do NOT set `videoSettings.pixWidth = 320` — that's Phase 2.
- Do NOT implement real `/dev/mem` mmap inside `Init()` — log-only.
- Do NOT add the cutscene (`LoadVideo`/`ProcessVideo`) stubs beyond what RenderDevice surface requires.
- Do NOT build armhf in this phase — that's Phase 0. We only need Mac build artifact + log output.
- Do NOT add the game-root `PORT_MISTER` feature gating (config.c-style defaults) — that's for the port's game-side work, which Mania doesn't use yet.
- Do NOT attempt to make the binary *run* on MiSTer — only "ready to cross-compile once Phase 0 lands".

---

## Dependency graph

```
Step 1 (platform ID + RSDK_USE_MISTER wiring in RetroEngine.hpp)
  └─> Step 2 (MiSTer backend header + source skeleton)
        └─> Step 3 (Drawing.hpp + Drawing.cpp include-chain patches)
              └─> Step 4 (platforms/MiSTer.cmake)
                    └─> Step 5 (root game CMakeLists.txt PORT_MISTER passthrough)
                          └─> Step 6 (Mac build + log-smoke verification)
```

Each step is one `/implement` invocation. Steps 1–5 are pure file edits; Step 6 is the acceptance test.

---

## Step 1 — Extend `RetroEngine.hpp` with `RETRO_RENDERDEVICE_MISTER` + `RSDK_USE_MISTER` selection

### Why it matters
Without this, `RETRO_RENDERDEVICE_MISTER` is either undefined (compile error at Drawing.hpp dispatch) or zero (MiSTer `.hpp` never included). Nothing downstream works until the macro is defined and selected based on the `RSDK_USE_MISTER` define that CMake emits.

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp` — entire file, focus on lines 103-148 (platform ID chain — DO NOT TOUCH), 163-169 (render device defaults), 260-420 (platform-specific `#elif` blocks where SDL2/OGL/VK selection happens).
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md` Decisions table (lines 9-23).

### Files to modify
**Only `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp`.**

Three discrete insertions, all additive:

1. **Line ~169** (after the `RETRO_RENDERDEVICE_EGL (0)` default): add
   ```cpp
   #define RETRO_RENDERDEVICE_MISTER (0)
   ```

2. **Inside the `#elif RETRO_PLATFORM == RETRO_LINUX` block (current lines 330-365)**: after the existing `#elif defined(RSDK_USE_VK)` arm, BEFORE the closing `#else #error ...`, insert:
   ```cpp
   #elif defined(RSDK_USE_MISTER)
   #undef RETRO_RENDERDEVICE_MISTER
   #define RETRO_RENDERDEVICE_MISTER (1)
   #undef RETRO_INPUTDEVICE_SDL2
   #define RETRO_INPUTDEVICE_SDL2 (1)

   #undef RETRO_AUDIODEVICE_MINI
   #define RETRO_AUDIODEVICE_MINI (0)
   #undef RETRO_AUDIODEVICE_SDL2
   #define RETRO_AUDIODEVICE_SDL2 (1)

   ```
   And update the matching `#error` string to read `RSDK_USE_SDL2, RSDK_USE_OGL, RSDK_USE_VK, or RSDK_USE_MISTER must be defined.`

3. **Inside the `#elif RETRO_PLATFORM == RETRO_OSX || RETRO_PLATFORM == RETRO_iOS` block (current lines 409-420)**: wrap the existing SDL2 unconditional selection so that `RSDK_USE_MISTER` picks the MiSTer backend instead. Concretely, replace the block body with:
   ```cpp
   #if defined(RSDK_USE_MISTER)
   #undef RETRO_RENDERDEVICE_MISTER
   #define RETRO_RENDERDEVICE_MISTER (1)

   #undef RETRO_AUDIODEVICE_SDL2
   #define RETRO_AUDIODEVICE_SDL2 (1)

   #undef RETRO_INPUTDEVICE_SDL2
   #define RETRO_INPUTDEVICE_SDL2 (1)
   #else
   #undef RETRO_RENDERDEVICE_SDL2
   #define RETRO_RENDERDEVICE_SDL2 (1)

   #undef RETRO_AUDIODEVICE_SDL2
   #define RETRO_AUDIODEVICE_SDL2 (1)

   #undef RETRO_INPUTDEVICE_SDL2
   #define RETRO_INPUTDEVICE_SDL2 (1)
   #endif
   ```

   **VERIFICATION for reviewer/implementer:** After the edit, open the file and confirm that the `#else` branch contains verbatim the original three `#undef`/`#define` triples for SDL2 / SDL2 audio / SDL2 input. If a non-MiSTer Mac build (`cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON`) fails at compile time with "RETRO_RENDERDEVICE_SDL2 undefined" or similar, this branch was mis-edited.

### Success criteria
- `grep -n RETRO_RENDERDEVICE_MISTER dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp` returns at least 3 lines (default `(0)`, Linux arm define `(1)`, OSX arm define `(1)`).
- `grep -n RSDK_USE_MISTER dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp` returns at least 2 lines (Linux + OSX arms).
- No existing `#define RETRO_RENDERDEVICE_SDL2` line or `RSDK_USE_SDL2` arm is removed.
- Running `cmake -S . -B build -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON` from the game root still configures cleanly (sanity check that non-MiSTer builds aren't broken).
- **Linux+SDL2 regression smoke test:** on a Linux host (or a Linux CI runner),
  `cmake -S . -B build-linux-sdl -DPLATFORM=Linux -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON`
  followed by `cmake --build build-linux-sdl -j` still succeeds and produces a
  runnable binary. This is mandatory because our new `#elif defined(RSDK_USE_MISTER)`
  arm lives INSIDE the `RETRO_PLATFORM == RETRO_LINUX` block, right next to the
  pre-existing SDL2/OGL/VK arms. If the insertion is mis-placed, the SDL2 arm
  breaks. If no Linux host is available, the Darwin+SDL2 check above covers the
  most-likely failure modes but is NOT a substitute — flag any Linux-host
  regression as a Phase 1 blocker.

### Important ordering note: MINI ↔ SDL2 audio
`RetroEngine.hpp:332-335` (inside the `RETRO_PLATFORM == RETRO_LINUX` arm) does:
```cpp
#if !RETRO_AUDIODEVICE_SDL2
#undef RETRO_AUDIODEVICE_MINI
#define RETRO_AUDIODEVICE_MINI (1)
#endif
```
This runs BEFORE our new `#elif defined(RSDK_USE_MISTER)` arm sees any
`RSDK_USE_<X>` define. So the sequence for a MiSTer build is:
1. Line ~332-335: `RETRO_AUDIODEVICE_SDL2` is still `(0)` (default) at this
   point, so `RETRO_AUDIODEVICE_MINI` is flipped to `(1)`.
2. Our `#elif defined(RSDK_USE_MISTER)` arm then `#undef`s `MINI` back to `(0)`
   and flips `SDL2` to `(1)`.

This works, but it's fragile — any future upstream change that reorders those
two blocks could re-enable MINI on our build silently. Implementers should
NOT try to "clean it up" by moving the MINI guard; follow upstream symmetry
(SDL2/OGL/VK arms all live below the MINI guard) and trust the order.

### Dependencies
None (first step).

### What NOT to do
- Do NOT add a `RETRO_MISTER` platform ID to lines 84-93 — decision #3 forbids it.
- Do NOT touch the `#elif defined __linux__` / `__APPLE__` / etc. platform detection chain at lines 103-148.
- Do NOT rename any existing macro.

### Failure mode & recovery
- If `cmake -S . -B build -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2` fails after the patch, the insertion clobbered the pre-existing SDL2 arms. Inspect the `#elif RETRO_PLATFORM == RETRO_OSX` block carefully: the original unconditional `#undef/#define RETRO_RENDERDEVICE_SDL2 (1)` MUST still fire when `RSDK_USE_MISTER` is not defined. If the `#else` branch was lost, restore from git and redo step 1 with Edit operations instead of Write.

---

## Step 2 — Create `MiSTerRenderDevice.{hpp,cpp}` skeletons

### Why it matters
These files are the actual targets of the Drawing.hpp dispatch. Without them, step 3's include directive dangles.

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.hpp` — entire file (82 lines). This is the surface we mirror.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp` — read method-signature banner lines 21, 79, 98, 305, 339, 392, 398, 406, 408, 446, 553, 555, 594, 619, 675, 694, 1037, 1051, 1081, 1097, 1113. (Read via `grep -n "^bool RenderDevice::\|^void RenderDevice::"` if easier.) We match every public signature from the hpp + any private helper invoked by `Init`.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp` lines 189-243 (the `RenderDeviceBase` declaration; this is what our `RenderDevice` derives from).

### Files to create
**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp`** (~60 LOC).

Must mirror the SDL2RenderDevice.hpp public surface so Drawing.hpp's include is drop-in-compatible. Namespace is the default (no explicit `namespace RSDK { }` — SDL2 doesn't wrap itself either; it relies on the including `.cpp` being inside the namespace).

Required declarations (names MUST match the base class in Drawing.hpp:189-243):

```cpp
// File header with guard omitted for brevity; use #ifndef MISTER_RENDERDEVICE_H / #define / #endif.

using ShaderEntry = ShaderEntryBase;

class RenderDevice : public RenderDeviceBase
{
public:
    // Mirrors SDL2RenderDevice.hpp:6-19 but WITHOUT the SDL_DisplayMode / SDL_Rect
    // union members — the MiSTer backend does not use SDL types for display
    // enumeration, and we want to keep this header free of SDL includes. The
    // `displays` array and `displayInfo` static are REQUIRED because
    // Drawing.cpp:146 unconditionally defines `RenderDevice::WindowInfo
    // RenderDevice::displayInfo;`, and Drawing.cpp:313-347 dereferences
    // `displayInfo.displays[d].refresh_rate/.width/.height`. Omitting either
    // the struct or the static breaks compile AND link.
    struct WindowInfo {
        struct DisplayEntry {
            uint32 _pad;
            int32 width;
            int32 height;
            int32 refresh_rate;
        } *displays;
        // viewport is referenced by Drawing.cpp; keep the name but drop SDL_Rect.
        struct { int32 x, y, w, h; } viewport;
    };
    static WindowInfo displayInfo;

    static bool Init();
    static void CopyFrameBuffer();
    static void FlipScreen();
    static void Release(bool32 isRefresh);

    static void RefreshWindow();
    static void GetWindowSize(int32 *width, int32 *height);

    static void SetupImageTexture(int32 width, int32 height, uint8 *imagePixels);
    // NOTE: these 8-argument signatures MATCH SDL2RenderDevice.hpp and the call sites
    // in Video.cpp (lines 241-258). The older 3-argument form declared on
    // RenderDeviceBase in Drawing.hpp:201-203 is shadowed; follow SDL2's override here.
    static void SetupVideoTexture_YUV420(int32 width, int32 height, uint8 *yPlane, uint8 *uPlane, uint8 *vPlane, int32 strideY, int32 strideU, int32 strideV);
    static void SetupVideoTexture_YUV422(int32 width, int32 height, uint8 *yPlane, uint8 *uPlane, uint8 *vPlane, int32 strideY, int32 strideU, int32 strideV);
    static void SetupVideoTexture_YUV444(int32 width, int32 height, uint8 *yPlane, uint8 *uPlane, uint8 *vPlane, int32 strideY, int32 strideU, int32 strideV);

    static bool ProcessEvents();

    static void InitFPSCap();
    static bool CheckFPSCap();
    static void UpdateFPSCap();

    static bool InitShaders();
    static void LoadShader(const char *fileName, bool32 linear);

    static inline void ShowCursor(bool32 shown) { (void)shown; }
    static inline bool GetCursorPos(Vector2 *pos) { (void)pos; return false; }
    static inline void SetWindowTitle() { /* no-op */ }

private:
    static bool SetupRendering();
    static void InitVertexBuffer();
    static bool InitGraphicsAPI();
    static void GetDisplays();

    static unsigned long long targetFreq;
    static unsigned long long curTicks;
    static unsigned long long prevTicks;
};
```

**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`** (~80 LOC — overshot the ~50 LOC estimate because each stub needs a log line).

Start of file (no `#include` — this file is `#include`d by Drawing.cpp which has already included RetroEngine.hpp):
```cpp
// MiSTer render device — Phase 1 skeleton. Logs every entry point; does not touch hardware.
// Pixel output lands in Phase 2 via NativeVideoWriter.

// --- WindowInfo static storage ---
// Drawing.cpp:146 does `RenderDevice::WindowInfo RenderDevice::displayInfo;`
// UNCONDITIONALLY for every backend. We must define our own WindowInfo type
// (see .hpp) and supply this one-line definition here. Missing it => link error.
MiSTerRenderDevice::WindowInfo MiSTerRenderDevice::displayInfo = {};
// NOTE: if the class is named `RenderDevice` inside this compile unit via the
// `class RenderDevice : public RenderDeviceBase` alias, use:
//     RenderDevice::WindowInfo RenderDevice::displayInfo = {};
// SDL2RenderDevice.cpp uses the `RenderDevice::` spelling since `RenderDevice`
// IS the class name in that translation unit. Match the same spelling here.

// --- RenderDeviceBase static-member definitions (MANDATORY) ---
// `RenderDeviceBase` (Drawing.hpp:189-243) only DECLARES these statics; every
// backend `.cpp` must DEFINE them or the linker emits
// "undefined reference to `RSDK::RenderDeviceBase::isRunning'" etc.
// Mirror the block near SDL2RenderDevice.cpp:21 (the lines immediately above
// `bool RenderDevice::Init()`). Concretely, define at minimum:
//     bool  RenderDeviceBase::isRunning;
//     int32 RenderDeviceBase::windowRefreshDelay;
//     int32 RenderDeviceBase::displayWidth[16];
//     int32 RenderDeviceBase::displayHeight[16];
//     int32 RenderDeviceBase::displayCount;
//     int32 RenderDeviceBase::lastShaderID;
//     int32 RenderDeviceBase::startVertex_2P;
//     int32 RenderDeviceBase::startVertex_3P;   // only if RETRO_REV02
//     float RenderDeviceBase::pixelSize[2];
//     float RenderDeviceBase::textureSize[2];
//     float RenderDeviceBase::viewSize[2];
// Initializers are not load-bearing (zero-init is fine); types must match
// Drawing.hpp exactly. Reviewer: grep `RenderDeviceBase::` in
// SDL2RenderDevice.cpp between the top of file and `bool RenderDevice::Init()`
// and copy every definition verbatim, then replace initializers with `{}` if
// the SDL2 version references SDL types we don't have.
// This block MUST live here — NOT in the .hpp — because C++ allows multiple
// DECLARATIONS but exactly ONE DEFINITION of a static data member.

unsigned long long RenderDevice::targetFreq = 0;
unsigned long long RenderDevice::curTicks   = 0;
unsigned long long RenderDevice::prevTicks  = 0;

bool RenderDevice::Init()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Init()");
    if (!SetupRendering())
        return false;
    return true;
}

bool RenderDevice::SetupRendering()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::SetupRendering()");
    if (!InitGraphicsAPI())
        return false;
    InitVertexBuffer();
    return true;
}

bool RenderDevice::InitGraphicsAPI()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::InitGraphicsAPI() [stub]");
    return true;
}

void RenderDevice::InitVertexBuffer()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::InitVertexBuffer() [stub]");
}

void RenderDevice::CopyFrameBuffer() { PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::CopyFrameBuffer() [stub]"); }
void RenderDevice::FlipScreen()      { PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::FlipScreen() [stub]"); }
void RenderDevice::Release(bool32 isRefresh)
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Release(isRefresh=%d) [stub]", (int)isRefresh);
}
void RenderDevice::RefreshWindow()   { PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::RefreshWindow() [stub]"); }

void RenderDevice::GetWindowSize(int32 *width, int32 *height)
{
    if (width)  *width  = 320;  // placeholder; Phase 2 sets pixWidth
    if (height) *height = SCREEN_YSIZE;
}

void RenderDevice::GetDisplays()     { PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::GetDisplays() [stub]"); }

void RenderDevice::SetupImageTexture(int32 width, int32 height, uint8 *imagePixels)
{
    (void)width; (void)height; (void)imagePixels;
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::SetupImageTexture() [stub]");
}
void RenderDevice::SetupVideoTexture_YUV420(int32 w, int32 h, uint8 *y, uint8 *u, uint8 *v, int32 sy, int32 su, int32 sv)
{ (void)w;(void)h;(void)y;(void)u;(void)v;(void)sy;(void)su;(void)sv; PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::SetupVideoTexture_YUV420() [stub]"); }
void RenderDevice::SetupVideoTexture_YUV422(int32 w, int32 h, uint8 *y, uint8 *u, uint8 *v, int32 sy, int32 su, int32 sv)
{ (void)w;(void)h;(void)y;(void)u;(void)v;(void)sy;(void)su;(void)sv; PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::SetupVideoTexture_YUV422() [stub]"); }
void RenderDevice::SetupVideoTexture_YUV444(int32 w, int32 h, uint8 *y, uint8 *u, uint8 *v, int32 sy, int32 su, int32 sv)
{ (void)w;(void)h;(void)y;(void)u;(void)v;(void)sy;(void)su;(void)sv; PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::SetupVideoTexture_YUV444() [stub]"); }

bool RenderDevice::ProcessEvents() { return isRunning; }

void RenderDevice::InitFPSCap()    { PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::InitFPSCap() [stub]"); }
bool RenderDevice::CheckFPSCap()   { return true; }
void RenderDevice::UpdateFPSCap()  { /* no-op */ }

bool RenderDevice::InitShaders()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::InitShaders() [stub: no shaders]");
    videoSettings.shaderSupport = false;
    return true;
}
void RenderDevice::LoadShader(const char *fileName, bool32 linear)
{
    (void)fileName; (void)linear;
    // Intentionally quiet — called often.
}
```

### Success criteria
- Both files exist at the exact paths above.
- `grep -c PrintLog dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` ≥ 12.
- File compiles in isolation is NOT testable until Step 3 wires it into Drawing.cpp; Step 6 is the true verification.

### Dependencies
Step 1 (we rely on `RETRO_RENDERDEVICE_MISTER` being defined in the compile-define chain).

### Namespace note (reviewer-verified)
Drawing.cpp at line 3 contains `using namespace RSDK;`. Since `MiSTerRenderDevice.cpp` is textually `#include`d by Drawing.cpp (see Step 3), the `RSDK::` namespace is already active. Do NOT wrap `MiSTerRenderDevice.cpp` in `namespace RSDK { ... }` — SDL2RenderDevice.cpp doesn't, and neither should we.

### Static `window` member — deliberate omission
`RetroEngine.cpp:62` references `RenderDevice::window`, but that call is gated by `#if RETRO_PLATFORM == RETRO_ANDROID`. Our targets (RETRO_OSX for Mac iteration, RETRO_LINUX for armhf) never trigger that branch, so omitting `static <type>* window;` from our class is safe. SDL2RenderDevice.cpp declares one (line 2), but it's only used by the SDL2 backend itself. If a future phase adds Android support, this needs to be revisited.

### What NOT to do
- Do NOT `#include` SDL2, stdio, sys/mman, etc. in this file. Drawing.cpp includes RetroEngine.hpp before including us, and that pulls in everything we need.
- Do NOT add any `/dev/mem` logic. That's Phase 2.
- Do NOT set `videoSettings.pixWidth = 320` in `Init()`. That's Phase 2 per the decisions.
- Do NOT copy `native_video_writer.{h,c}` yet.
- Do NOT declare a `static <type>* window` or `static windowHandle` member — see "Static `window` member" note above.

### Failure mode & recovery
- If the file doesn't compile at Step 6 because `SCREEN_YSIZE` / `isRunning` / `videoSettings` / `PrintLog` / `bool32` / `int32` / `uint8` / `Vector2` are undefined: confirm the `.cpp` is being included via Drawing.cpp (which is inside `namespace RSDK`), not built as a standalone compile unit. The CMake source-list wiring in Step 4 must NOT add `MiSTerRenderDevice.cpp` to `RETRO_FILES` — Drawing.cpp includes it textually.
- If `RenderDeviceBase` members like `isRunning` are inaccessible: they're `static` on the base class and declared at `Drawing.hpp:219` as `public`. Should Just Work.

---

## Step 3 — Patch `Drawing.hpp` and `Drawing.cpp` include chains

### Why it matters
This is the upstream seam. Without these 8 total lines of patch, the MiSTer backend is never compiled even with every other piece in place.

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp` — specifically lines 245-257.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — specifically lines 132-144.

### Files to modify

**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp`** — append a `#elif` branch to the block at lines 245-257.

Exact text to insert before the closing `#endif` at line 257:
```cpp
#elif RETRO_RENDERDEVICE_MISTER
#include "MiSTer/MiSTerRenderDevice.hpp"
```

After the edit, the block reads:
```cpp
#if RETRO_RENDERDEVICE_DIRECTX9
#include "DX9/DX9RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_DIRECTX11
#include "DX11/DX11RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_SDL2
#include "SDL2/SDL2RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_GLFW
#include "GLFW/GLFWRenderDevice.hpp"
#elif RETRO_RENDERDEVICE_VK
#include "Vulkan/VulkanRenderDevice.hpp"
#elif RETRO_RENDERDEVICE_EGL
#include "EGL/EGLRenderDevice.hpp"
#elif RETRO_RENDERDEVICE_MISTER
#include "MiSTer/MiSTerRenderDevice.hpp"
#endif
```

**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp`** — matching `#elif` branch to the block at lines 132-144.

Insert before the closing `#endif` at line 144:
```cpp
#elif RETRO_RENDERDEVICE_MISTER
#include "MiSTer/MiSTerRenderDevice.cpp"
```

### Success criteria
- `git diff dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp` shows exactly +2 lines, all additive.
- `git diff dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` shows exactly +2 lines, all additive.
- Non-MiSTer configure still works: `cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON` succeeds.

### Dependencies
Step 2 (the `MiSTerRenderDevice.hpp` and `.cpp` must exist; otherwise the include resolves to nothing and fails at compile).

### What NOT to do
- Do NOT reorder existing `#elif` arms.
- Do NOT touch the `#if RETRO_REV0U / #include "Legacy/DrawingLegacy.cpp"` block at the top of Drawing.cpp.
- Do NOT add a corresponding patch to any other file (no other include chain needs to know about us).

### Failure mode & recovery
- If a non-MiSTer configure (Darwin + SDL2) breaks: the patch went in the wrong block. Verify you edited the block starting `#if RETRO_RENDERDEVICE_DIRECTX9` (NOT any random `#if` in the file — Drawing.cpp has dozens).

---

## Step 4 — Create `platforms/MiSTer.cmake`

### Why it matters
This is the new platform entry point. `-DPLATFORM=MiSTer` causes `dependencies/RSDKv5/CMakeLists.txt:68` to `include(platforms/MiSTer.cmake)`, which is the ONE place we declare source files, compile defines, and dependency links.

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Linux.cmake` — entire (96 lines). Canonical pkg-config pattern.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Darwin.cmake` — entire (77 lines). Shows the `_STATIC_LIBRARY_DIRS` fix (lines 30, 42, 50, 56, 62, 71) that Linux.cmake lacks.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/CMakeLists.txt` lines 58-68 (platform selection), 149-166 (`GAME_STATIC` and compile defines emission incl. `RSDK_USE_${RETRO_SUBSYSTEM}=1` on line 155).
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt` lines 13-44 (3sx PORT_MISTER option), 169-215 (ARM hardening block).

### Files to create
**`dependencies/RSDKv5/platforms/MiSTer.cmake`** (~100 LOC).

Structure:

```cmake
# MiSTer build file — mirrors Linux.cmake / Darwin.cmake (pkg-config driven).
# Selects the MiSTer render backend (Graphics/MiSTer/*) and link SDL2 for
# input + audio. On armhf targets, applies ARM hardening flags (mirrors 3sx).
#
# Phase 1 scope: backend compiles and links with stubbed methods. No /dev/mem
# mmap, no NativeVideoWriter (that lands in Phase 2).

find_package(PkgConfig REQUIRED)

# Force the subsystem tag so RSDK_USE_MISTER=1 is emitted by the parent
# CMakeLists.txt line 155 regardless of what the caller passed.
set(RETRO_SUBSYSTEM "MiSTer" CACHE STRING "The subsystem to use" FORCE)

option(USE_SDL_AUDIO "Whether or not to use SDL for audio instead of the default MiniAudio." ON)

add_executable(RetroEngine ${RETRO_FILES})

find_package(Threads REQUIRED)
target_link_libraries(RetroEngine Threads::Threads)

# --- Mac-host iteration build requirement ---
# RetroEngine.hpp:473-478 unconditionally `#include "cocoaHelpers.hpp"` when
# RETRO_PLATFORM==RETRO_OSX. When we build this platform file on a Mac host
# (for the Phase 1 validation loop), RETRO_PLATFORM is still RETRO_OSX (the
# `__APPLE__` predef sets it), so cocoaHelpers.mm MUST be compiled and the
# Cocoa/Foundation frameworks MUST be linked — otherwise the Mac build fails
# at link. This mirrors the Darwin.cmake pattern (lines 8-21).
if(APPLE)
    enable_language(OBJCXX)
    target_sources(RetroEngine PRIVATE dependencies/mac/cocoaHelpers.mm)
    target_include_directories(RetroEngine PRIVATE dependencies/mac)
    target_link_libraries(RetroEngine "-framework Cocoa" "-framework Foundation")
    message(STATUS "MiSTer.cmake: Mac-host build detected; linking Cocoa/Foundation for cocoaHelpers.mm")
endif()

# libogg + libtheora — mirror Darwin.cmake's _STATIC_LIBRARY_DIRS fix.
pkg_check_modules(OGG ogg)
if(NOT OGG_FOUND)
    set(COMPILE_OGG TRUE)
    message(NOTICE "libogg not found, attempting to build from source")
else()
    message("found libogg")
    target_link_libraries(RetroEngine ${OGG_STATIC_LIBRARIES})
    target_link_directories(RetroEngine PRIVATE ${OGG_STATIC_LIBRARY_DIRS})
    target_link_options(RetroEngine PRIVATE ${OGG_STATIC_LDLIBS_OTHER})
    target_compile_options(RetroEngine PRIVATE ${OGG_STATIC_CFLAGS})
endif()

pkg_check_modules(THEORA theora theoradec)
if(NOT THEORA_FOUND)
    message("could not find libtheora, attempting to build manually")
    set(COMPILE_THEORA TRUE)
else()
    message("found libtheora")
    target_link_libraries(RetroEngine ${THEORA_STATIC_LIBRARIES})
    target_link_directories(RetroEngine PRIVATE ${THEORA_STATIC_LIBRARY_DIRS})
    target_link_options(RetroEngine PRIVATE ${THEORA_STATIC_LDLIBS_OTHER})
    target_compile_options(RetroEngine PRIVATE ${THEORA_STATIC_CFLAGS})
endif()

# SDL2 for input (+ audio if USE_SDL_AUDIO=ON, which defaults to ON here).
pkg_check_modules(SDL2 sdl2 REQUIRED)
target_link_libraries(RetroEngine ${SDL2_STATIC_LIBRARIES})
target_link_directories(RetroEngine PRIVATE ${SDL2_STATIC_LIBRARY_DIRS})
target_link_options(RetroEngine PRIVATE ${SDL2_STATIC_LDLIBS_OTHER})
target_compile_options(RetroEngine PRIVATE ${SDL2_STATIC_CFLAGS})

if(USE_SDL_AUDIO)
    target_compile_definitions(RetroEngine PRIVATE RETRO_AUDIODEVICE_SDL2=1)
endif()

# Phase 1 hook: the MiSTer backend compiles via Drawing.cpp's textual include
# (see Drawing.cpp:132-144). We do NOT add the .cpp to RETRO_FILES; we only
# need to make the include path resolvable, which it is by default since
# Drawing.cpp sits in the same dir as Graphics/MiSTer/.
# Sanity: surface the file to CMake so it shows up in IDE browsing.
target_sources(RetroEngine PRIVATE
    RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp
)

# ARM hardening: only on armhf cross-builds. Skip on Darwin / x86 hosts.
option(ENABLE_MISTER_ARM_HARDENING "Conservative ARMv7 hard-float / NEON flags for MiSTer" OFF)

string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _mister_sys_proc_lc)
string(TOLOWER "${CMAKE_C_COMPILER_TARGET}" _mister_ctarget_lc)
set(_mister_armv7_target OFF)

if((_mister_ctarget_lc MATCHES "armv7") OR (_mister_ctarget_lc MATCHES "arm-linux-gnueabihf"))
    set(_mister_armv7_target ON)
elseif((_mister_sys_proc_lc MATCHES "armv7") OR (_mister_sys_proc_lc MATCHES "armhf"))
    set(_mister_armv7_target ON)
endif()

if(_mister_armv7_target)
    set(ENABLE_MISTER_ARM_HARDENING ON CACHE BOOL "" FORCE)
endif()

if(ENABLE_MISTER_ARM_HARDENING AND _mister_armv7_target)
    if((CMAKE_C_COMPILER_ID STREQUAL "Clang") OR (CMAKE_C_COMPILER_ID STREQUAL "GNU"))
        target_compile_options(RetroEngine PRIVATE
            -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard)
        target_link_options(RetroEngine PRIVATE
            -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard)
        message(STATUS "MiSTer ARM hardening enabled: -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard")
    else()
        message(WARNING "MiSTer ARM hardening supports Clang/GNU only; skipping.")
    endif()
elseif(ENABLE_MISTER_ARM_HARDENING)
    message(WARNING
        "ENABLE_MISTER_ARM_HARDENING=ON but non-armv7 target detected "
        "(system='${CMAKE_SYSTEM_PROCESSOR}', target='${CMAKE_C_COMPILER_TARGET}'). "
        "Skipping hardening flags — Mac iteration build will still compile.")
endif()

message(STATUS "MiSTer.cmake loaded. RETRO_SUBSYSTEM=${RETRO_SUBSYSTEM} ENABLE_MISTER_ARM_HARDENING=${ENABLE_MISTER_ARM_HARDENING}")
```

### Mac host build — iteration/validation only
The Mac-host branch above is for Phase 1 iteration/validation only: it uses our
`MiSTerRenderDevice` to exercise the selection chain and produces the log
output that is the Phase 1 exit criterion (Step 6). There is no actual DDR3 or
FPGA on a Mac — the backend stubs just log and return. The Cocoa/Foundation
framework link is required because `RetroEngine.hpp:473` unconditionally
forces `#include "cocoaHelpers.hpp"` on OSX; without the `.mm` source + frameworks
the Mac build fails at link.

### Success criteria
- File exists at `dependencies/RSDKv5/platforms/MiSTer.cmake`.
- `cmake -S . -B build-mister -DPLATFORM=MiSTer -DGAME_STATIC=ON` from the game root configures without errors on Mac.
- Configure log contains `MiSTer.cmake loaded. RETRO_SUBSYSTEM=MiSTer`.
- Configure log contains `ENABLE_MISTER_ARM_HARDENING=OFF` (or the warning about non-armv7 target) when invoked on Mac.
- Non-MiSTer configure (`cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON`) still succeeds.

### Dependencies
Step 2 and Step 3 (referenced file paths and include-chain must already be in place for the subsequent build step to succeed).

### What NOT to do
- Do NOT add `MiSTerRenderDevice.cpp` to `RETRO_FILES` or any `add_executable` / `target_sources` as a compiled unit. It is textually `#include`d by Drawing.cpp. Adding it separately would produce duplicate-symbol link errors.
- Do NOT require `_mister_armv7_target` to pass on Mac. Decision: warn, then skip ARM flags — this is a deliberate concession so Mac iteration builds work.
- Do NOT import any 3sx `src/port/*` files. Phase 2 handles that.

### Failure mode & recovery
- If CMake emits `Unknown CMake command "pkg_check_modules"`: `PkgConfig` package not installed on host; on Mac run `brew install pkg-config`. Document in the plan but don't fail the step — Phase 0 handles the armhf sysroot.
- If libogg/libtheora are not found via pkg-config: the existing `COMPILE_OGG`/`COMPILE_THEORA` fallbacks in `dependencies/RSDKv5/CMakeLists.txt:80-134` build them from vendored sources. No action needed here.

---

## Step 5 — Root `CMakeLists.txt` passthrough

### Why it matters
So a user can just run `cmake -S . -B build -DPLATFORM=MiSTer ...` from the game root without having to pass `-DWITH_RSDK`, `-DGAME_STATIC`, etc. explicitly, and so that `GAME_STATIC=ON` is forced when building for MiSTer (per decision #4).

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/CMakeLists.txt` — entire (103 lines). Note that this file does NOT have a `PORT_MISTER` option today.
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt` lines 13-44 as reference pattern.

### Files to modify
**`/Users/sb/Developer/sonic-mania-mister/CMakeLists.txt`** — two small additions:

1. **After line 3 `project(SonicMania)`**, add:
   ```cmake
   option(PORT_MISTER "Enable MiSTer-oriented build profile (pulls in platforms/MiSTer.cmake)" OFF)

   if(PORT_MISTER)
       # MiSTer implies static game + MiSTer platform.
       set(PLATFORM "MiSTer" CACHE STRING "The platform to compile for." FORCE)
       set(GAME_STATIC ON CACHE BOOL "Static game binary (MiSTer default)" FORCE)
       message(STATUS "PORT_MISTER=ON: platform=MiSTer, GAME_STATIC=ON")
   endif()
   ```

2. No other edits needed. The existing `add_subdirectory(${RSDK_PATH})` at line 72 triggers inclusion of `platforms/MiSTer.cmake` via the submodule's include logic.

### Success criteria
- `grep -n PORT_MISTER CMakeLists.txt` in the game root shows at least 3 hits (option, if-block, message).
- `cmake -S . -B build-mister -DPORT_MISTER=ON` from the game root sets `PLATFORM=MiSTer` and `GAME_STATIC=ON` automatically.
- Configure output includes `PORT_MISTER=ON: platform=MiSTer, GAME_STATIC=ON`.
- Non-MiSTer configure still works unchanged: `cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2` produces no PORT_MISTER messages.

### Dependencies
Step 4 (`platforms/MiSTer.cmake` must exist for `PORT_MISTER=ON` to succeed).

### What NOT to do
- Do NOT replicate 3sx's `ENABLE_NETPLAY`, `ENABLE_ISO_IMPORT`, etc. options — Mania doesn't use any of those.
- Do NOT add cutscene-stub / `RETRO_DISABLE_VIDEO` macro here. That's a later phase; for now cutscenes are ignored at runtime because the engine never reaches them in a skeleton boot.
- Do NOT pass any `CMAKE_TOOLCHAIN_FILE` here — cross-compile toolchain is Phase 0's responsibility.

### Failure mode & recovery
- If `PORT_MISTER=ON` still ends up building SDL2 backend: the `RETRO_SUBSYSTEM` cache variable was already set from a previous invocation and isn't being overridden. Workaround: delete the build dir and re-configure. (Phase 0 build-driver scripts will do this automatically.)

---

## Step 6 — Mac acceptance test (the Phase 1 exit criterion)

### Why it matters
This is the verification gate. If this step succeeds, Phase 1 is done and Phase 2 can begin.

### Files to read first
- All files created or modified in Steps 1–5.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` — search for where `RenderDevice::Init()` is called from (should be inside `InitEngine` / `RunRetroEngine`) — only to understand the log timing, no edit.

### Files to create/modify
**None.** This step is invocation + verification only.

### Acceptance test procedure

**Pre-flight (on Mac host):**
```bash
brew install sdl2 libogg theora pkg-config    # idempotent
```

**Configure and build:**
```bash
cd /Users/sb/Developer/sonic-mania-mister
rm -rf build-mister
cmake -S . -B build-mister -DPORT_MISTER=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-mister -j
```

**Expected build artifacts:**
- `build-mister/dependencies/RSDKv5/RSDKv5U` (executable, Mach-O arm64 or x86_64 depending on Mac host).
- `build-mister/libGame.a` (static game library).

**Run and capture log:**
```bash
# IMPORTANT: RSDK's PrintLog() writes to a log FILE, not stdout (see
# RSDKv5/RSDK/Core/Link.cpp / PrintLog() — it opens and appends to `log.txt`
# in the RSDK resource dir on macOS). Teeing stdout will capture zero
# MiSTerRenderDevice lines. We must check the log file directly.
#
# On macOS the RSDK log lives at:
#     ~/Library/Application Support/RSDKv5/log.txt
# (If that path comes up empty on this Mac, grep the binary dir and
# Application Support for `log.txt` — the exact dir is driven by
# `SKU.userFileDir` which is platform-specific.)

# Start clean so stale lines don't pollute the grep:
rm -f "$HOME/Library/Application Support/RSDKv5/log.txt"

./build-mister/dependencies/RSDKv5/RSDKv5U &
RSDK_PID=$!
# Give it ~10s to reach Init() and exit on missing Data.rsdk:
sleep 10
kill $RSDK_PID 2>/dev/null || true
wait $RSDK_PID 2>/dev/null || true
```

**Expected log lines in `~/Library/Application Support/RSDKv5/log.txt` (order may interleave):**
```
MiSTerRenderDevice::Init()
MiSTerRenderDevice::SetupRendering()
MiSTerRenderDevice::InitGraphicsAPI() [stub]
MiSTerRenderDevice::InitVertexBuffer() [stub]
MiSTerRenderDevice::InitFPSCap() [stub]
MiSTerRenderDevice::InitShaders() [stub: no shaders]
```

Verification one-liner:
```bash
grep -c "MiSTerRenderDevice::" "$HOME/Library/Application Support/RSDKv5/log.txt"
# expect >= 4
```
If the grep returns 0 but the binary clearly started, the log file is
elsewhere. Fallback search:
```bash
find "$HOME/Library/Application Support" ./build-mister -name 'log.txt' -mmin -5 2>/dev/null
```

### Success criteria
- Build completes without errors (warnings are fine).
- Binary exists and is executable.
- After running the binary, `~/Library/Application Support/RSDKv5/log.txt` contains at least 4 `MiSTerRenderDevice::` log lines before the engine crashes or exits on missing asset. (RSDK's `PrintLog` writes to this file, not stdout — see Step 6 note.)
- No `Undefined symbols for architecture` linker errors.
- No runtime `SIGSEGV` before `MiSTerRenderDevice::Init()` logs.

### Dependencies
Steps 1–5 all complete.

### What NOT to do
- Do NOT attempt to provide a `Data.rsdk` — we WANT the engine to fail after logging Init. That failure confirms we've reached and completed Init/SetupRendering.
- Do NOT modify RSDK log levels / verbosity — default levels already print `PRINT_NORMAL` to stdout.
- Do NOT try to run this on MiSTer HPS — we have no armhf toolchain until Phase 0 lands.

### Failure mode & recovery
- **"Undefined reference to `RenderDevice::Init`" at link time:** MiSTerRenderDevice.cpp is NOT being textually included by Drawing.cpp. Verify Step 3's Drawing.cpp patch fired in the right block, and that `RETRO_RENDERDEVICE_MISTER` is `1` at that point (dump `-E` output if needed).
- **`RETRO_RENDERDEVICE_MISTER` is 0 at compile time:** RSDK_USE_MISTER not getting defined. Check `build-mister/CMakeCache.txt` for `RETRO_SUBSYSTEM:STRING=MiSTer` and confirm `dependencies/RSDKv5/CMakeLists.txt:155` emits it.
- **Binary crashes before logging Init:** unlikely, but could be an STL init issue. Rebuild with `-DCMAKE_BUILD_TYPE=Debug`, run under `lldb`, get backtrace. Defer; open a follow-up, don't block Phase 1.
- **Build succeeds but no `log.txt` appears:** check `RETRO_DISABLE_LOG` isn't being defined somewhere. Also confirm the RSDK user-file dir exists and is writable: `ls -la "$HOME/Library/Application Support/RSDKv5/"`. If the dir is missing, create it (`mkdir -p`) and rerun. If logs still don't appear, grep the source for where `PrintLog` opens the file (`grep -rn "log.txt" dependencies/RSDKv5/RSDKv5/RSDK/`) and confirm the path at runtime.

---

## Risk register (phase-level)

| Risk | Severity | Mitigation |
|---|---|---|
| `RetroEngine.hpp` upstream merge conflicts | Medium | Our 3 insertions are all additive and in stable blocks. Document the patches in `docs/upstream-patches.md` (future) so a rebase can re-apply mechanically. |
| Mac iteration path diverges from armhf build too much | Low | Phase 0 will run the same CMake wiring against an armhf sysroot; the only cross-specific code is the `_mister_armv7_target` flag in MiSTer.cmake, which gates the hardening flags without affecting source selection. |
| SDL2 being linked but never used on pure-stub Phase 1 | None | The linker will drop unused SDL symbols. Binary size is irrelevant. |
| Mod loader (C++17 `<filesystem>`) on Mac iteration | Low | `filesystem` ships in libc++ on any macOS ≥ 10.15. No action. |
| Non-MiSTer builds regress | Medium-High | Step 1, 3, and 5 all include "non-MiSTer configure still works" as explicit success criteria. |

## Rollback plan

Every patch is in one of:
- `dependencies/RSDKv5/` (submodule) — revert via `cd dependencies/RSDKv5 && git checkout -- RSDKv5/RSDK/Core/RetroEngine.hpp RSDKv5/RSDK/Graphics/Drawing.{hpp,cpp}`.
- `dependencies/RSDKv5/platforms/MiSTer.cmake` — new file, delete.
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/` — new dir, delete.
- Game root `CMakeLists.txt` — revert via `git checkout -- CMakeLists.txt`.

Full rollback is under 60 seconds with no dependents.

## Notes carried forward for later phases

- **Phase 2 tasks to pick up here:**
  1. Set `videoSettings.pixWidth = 320` inside `MiSTerRenderDevice::Init()` (or `SetupRendering`).
  2. Copy `src/port/sdl/native_video_writer.{h,c}` from 3sx → `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/`.
  3. Reparameterize constants per `mister-port-plan.md:109-118` (320×240, 153600 bytes, BUF1_OFFSET=0x25900).
  4. Implement `CopyFrameBuffer` to call `NativeVideoWriter_WriteFrame`.
  5. Implement `FlipScreen` trigger.
  6. Add `.c` to `MiSTer.cmake` `target_sources(RetroEngine PRIVATE ...)` explicitly (since it's a compile unit, not a textual include).
- **Phase 3 tasks:** wire real SDL2 gamepad/keyboard events through `ProcessEvents()` (currently returns `isRunning` blindly).
- **Cutscene stubbing (decision #5):** the `SetupVideoTexture_YUV*` methods already log "[stub]". At Phase 7 polish, decide whether to implement CPU YUV→RGB565 or stub `LoadVideo`/`ProcessVideo` in `Video.cpp`.

## References

- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp` — platform ID chain and render-device macro defaults.
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.{hpp,cpp}` — backend dispatch seam.
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.{cpp,hpp}` — reference backend (smallest).
- `dependencies/RSDKv5/platforms/{Linux,Darwin}.cmake` — platform-file templates.
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt:13-44, 169-215` — PORT_MISTER option + ARM hardening reference.
- `docs/mister-port-research.md` §2.4, §2.6 — backend seam, minimum method surface.
- `docs/mister-port-plan.md` Phase 1 (lines 59-91), Decisions (lines 9-23).
