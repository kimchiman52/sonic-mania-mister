# Phase 2 — Native Video Writer (Linux side) — Implementation Plan

**Document date:** 2026-04-24
**Status:** Draft plan (pre-implementation). Each step is a self-contained `/implement` unit.
**Companion docs:** [mister-port-research.md](mister-port-research.md) §3.2/§3.3/§3.7, [mister-port-plan.md](mister-port-plan.md) Phase 2, [phase-1-plan.md](phase-1-plan.md), [phase-4-plan.md](phase-4-plan.md).

---

## Roles executed (three-agent loop, run sequentially by a single assistant)

The `/plan` skill calls for three fresh agents (plan → review → fix). In this
invocation the Task tool was not available to spawn sub-agents, so a single
assistant executed the three roles sequentially, re-reading source at each
stage. Each role is documented in its own section below so a reviewer can audit
that the review pass actually happened and that the fix pass addressed each
finding:

- **§ Role 1 — Planner**: drafted steps 1–4 by reading current source (§ Source
  read for the plan).
- **§ Role 2 — Reviewer**: walked every factual claim in the draft against
  source, producing P-1 / P-2 findings (see § Review log).
- **§ Role 3 — Fixer**: applied review findings in place and called out skipped
  findings with justification (see § Fix log).

Future revisions of this doc MUST preserve this header if the Task-tool
constraint persists; otherwise the review trail becomes invisible.

---

## Objective & scope

**Goal:** RGB565 frames rendered by RSDKv5's software rasterizer land in MiSTer
DDR3 at the 320×240 buffer layout that Phase 4's RTL expects. Verifiable from
a MiSTer shell with `devmem2` while no FPGA core is loaded. On Mac, everything
compiles but the writer is a runtime no-op (no `/dev/mem`).

**Inputs to this phase (all already landed in Phase 1):**
- `MiSTerRenderDevice.{hpp,cpp}` stubs at
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/` (see the current files —
  `Init()`, `SetupRendering()`, `CopyFrameBuffer()`, `FlipScreen()`,
  `Release()` are all present and logging-only).
- Backend-dispatch arm at `Drawing.cpp:144-145` and `Drawing.hpp` (MiSTer
  include path is already wired).
- `RETRO_RENDERDEVICE_MISTER=1` emitted when `RSDK_USE_MISTER=1`.
- `platforms/MiSTer.cmake` with pkg-config SDL2 + libtheora + libogg, ARM
  hardening block, Cocoa link for Mac host iteration builds.
- Game-root `CMakeLists.txt` honours `-DPORT_MISTER=ON`.

**Outputs (what /implement cycles must produce):**
1. NEW: `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
2. NEW: `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c`
3. MODIFIED: `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
   — `Init`, `Release`, `FlipScreen` call into NativeVideoWriter; `Init`
   clamps `videoSettings.pixWidth = 320`. **No new `#include` lines in this
   file** (see Phase 1 guardrail comment at lines 6-10 of that file). The
   header is injected from `Drawing.cpp` instead (item 4 below).
4. MODIFIED: `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — add
   `#include "MiSTer/NativeVideoWriter.h"` on the line **immediately above**
   the existing `#include "MiSTer/MiSTerRenderDevice.cpp"` at line ~144, so
   the writer header is visible inside the textual-include TU without
   violating `MiSTerRenderDevice.cpp`'s "no includes" invariant.
5. MODIFIED: `dependencies/RSDKv5/platforms/MiSTer.cmake` — add `.c` to compiled
   sources (it is a real compile unit, NOT textually included).
6. No upstream engine patches beyond those already landed by Phase 1.

**Non-goals for this phase:**
- No visible picture. The FPGA core is Phase 4; without it, writes to DDR3
  are invisible. `devmem2` is our visibility mechanism.
- No vsync-feedback loop. `NV_FEEDBACK_*` symbols are exposed in the header
  for forward-compat, but the engine side does not read them yet (that is
  Phase 6 per mister-port-plan.md).
- No input / audio / SDL integration work (Phase 3).
- No 424×240 widescreen. Decision #1 locks 320×240 4:3.
- No RGB565 pixel-format conversion. RSDKv5's `ScreenInfo::frameBuffer` is
  already `uint16` RGB565 (see `Drawing.hpp:76-88` — verified).

---

## Decisions baked in (not revisitable in Phase 2)

| # | Decision | Value |
|---|---|---|
| 1 | Internal resolution | 320×240 4:3; height locked by `SCREEN_YSIZE=240` (`RetroEngine.hpp:155`). `videoSettings.pixWidth = 320` is set by `MiSTerRenderDevice::Init()`. |
| 3 | Sub-flag | `RSDK_USE_MISTER`, emitted by `platforms/MiSTer.cmake` (Phase 1). |
| 4 | Pixel format | RGB565 native, **no conversion**. |
| — | Writer placement | `Graphics/MiSTer/NativeVideoWriter.{h,c}`, textually a sibling of `MiSTerRenderDevice.cpp`. The `.c` is a normal compile unit (NOT textually included) — compiled by `platforms/MiSTer.cmake`. |

---

## Parameter table (must match Phase 4 RTL exactly)

These are the source of truth for Phase 2. Phase 4 RTL constants are derived
from these (see `phase-4-plan.md` §6.1 for the dual table). **Any change here
forces Phase 4 RTL re-synthesis.**

| Constant | Value (hex / decimal) | Rationale / RTL cross-ref |
|---|---|---|
| `NV_DDR_PHYS_BASE` | `0x3A000000` | Same physical base as 3S-ARM. Contract frozen; only one core loaded at a time, so the two cores cannot collide at runtime. |
| `NV_DDR_REGION_SIZE` | `0x00060000` (393,216 B, 384 KB) | 3sx value, preserved. Fits 2 × 153,600 B buffers + ctrl + feedback with ~85.7 KB slack (see the cross-check arithmetic below and phase-4-plan.md §0). |
| `NV_FRAME_WIDTH` | `320` | Decision #1. |
| `NV_FRAME_HEIGHT` | `240` | Decision #1. `SCREEN_YSIZE` in RetroEngine.hpp line 155 is also 240 — matches. |
| `NV_FRAME_BYTES` | `153,600` (`0x25800`) | `320 * 240 * 2`. |
| `NV_CTRL_OFFSET` | `0x00000000` | RTL reads frame_counter and active_buf here. |
| `NV_FEEDBACK_OFFSET` | `0x00000040` | RTL writes vsync feedback here. Read-only from ARM side (phase 2 does not consume it). |
| `NV_BUF0_OFFSET` | `0x00000100` (256) | 256 B reserved: ctrl (4 B at 0x00) + feedback (8 B at 0x40-0x47) + 244 B pad. |
| `NV_BUF1_OFFSET` | `0x00025900` | `NV_BUF0_OFFSET + NV_FRAME_BYTES = 0x100 + 0x25800`. Phase 4 RTL has `BUF1_ADDR = 29'h07404B20` which is `(0x3A025900 >> 3)`. |

**Cross-check arithmetic (from `phase-4-plan.md:336`):**
- Buf0 occupies `[0x00000100 .. 0x000258FF]` (153,600 B) ✓
- Buf1 occupies `[0x00025900 .. 0x0004B0FF]` (153,600 B) ✓
- 0x4B0FF < 0x60000 (end of region). Slack = `0x60000 - 0x4B100 = 0x14F00` = 85,760 B ≈ 84 KB. ✓

---

## Engine-side integration facts (verified from source)

These facts drive the integration points in Step 3. Each is footnoted with
the actual source line.

1. **`ScreenInfo::frameBuffer` is uint16 RGB565** — `Drawing.hpp:78`:
   `uint16 frameBuffer[SCREEN_XMAX * SCREEN_YSIZE];`. Layout is row-major.
2. **Frame-buffer row stride is `ScreenInfo::pitch` uint16 pixels** (not
   `SCREEN_XMAX`). Reference: `SDL2RenderDevice.cpp:87-91`:
   ```cpp
   uint16 *frameBuffer = screens[s].frameBuffer;
   ...
   memcpy(pixels, frameBuffer, screens[s].size.x * sizeof(uint16));
   frameBuffer += screens[s].pitch;
   ```
   `pitch` is stored in uint16 pixels (see `SetScreenSize` at
   `Drawing.cpp:388`: `screen->pitch = (screen->size.x + 15) & 0xFFFFFFF0`).
   For `size.x = 320`, `pitch = 320`. Bytes-per-row = `pitch * 2 = 640`.
3. **Frame-buffer in-memory row stride (bytes) is determined by ScreenInfo's
   static sizing**, not `SCREEN_XMAX`. The `frameBuffer` is declared as a flat
   1D array `uint16[SCREEN_XMAX * SCREEN_YSIZE]`, but only the first
   `pitch * SCREEN_YSIZE` uint16s are used when `pixWidth == 320` — the
   rasterizer advances by `pitch`, not by `SCREEN_XMAX`. This means at
   pixWidth=320 the logical row stride is 320 pixels / 640 bytes, stored
   contiguously at the top of the buffer. **Leftover storage after
   `pitch * SCREEN_YSIZE` pixels is unused.**
4. **`RenderDevice::Init()` runs AFTER `LoadSettingsINI()`** — `RetroEngine.cpp:35`
   calls `LoadSettingsINI()`, then `RetroEngine.cpp:51` (under
   `RETRO_USE_MOD_LOADER`) calls `RenderDevice::Init()`. With the mod loader
   off, the `Init()` call at `RetroEngine.cpp:98` runs AFTER `InitEngine()`.
   Either way, `Init()` observes a fully-populated `videoSettings` struct.
5. **`videoSettings.pixWidth` default** = `DEFAULT_PIXWIDTH = 424`
   (`Drawing.hpp:18`), set by `UserCore.cpp:354` from INI or `:497` from
   hardcoded fallback. The INI may override to any value; we overwrite
   unconditionally in `Init()` to honour Decision #1.
6. **`CopyFrameBuffer()` and `FlipScreen()` are called every frame** —
   `RetroEngine.cpp:313,320`. With ModAPI also: `ModAPI.cpp:331,332,...` and
   `Debug.cpp:1945,1946`. Any MiSTer-side writer invocation from either hook
   must be idempotent / tolerant of multiple calls per frame (the 3sx writer
   already is — it just flips the control word).
7. **`SetScreenSize` is called by the backend's `InitGraphicsAPI()`** after
   reading `videoSettings.pixWidth` (see `SDL2RenderDevice.cpp:483-506`). Our
   stub `InitGraphicsAPI` in Phase 1 currently only logs. Phase 2 MUST call
   `SetScreenSize(s, videoSettings.pixWidth, SCREEN_YSIZE)` for at least
   screen 0 (Mania is single-screen — `screenCount=1`) so the rasterizer knows
   the right pitch/clip bounds. Without this, `screens[0].size.x` stays 0 and
   the engine renders into corrupted state.
8. **`screenCount = 1`** is set by `RetroEngine.cpp:54` after `Init()`
   succeeds. We do not override this.
9. **`currentScreen = &screens[0]`** is also set by `RetroEngine.cpp:53`.

---

## Mac no-op strategy

**Preprocessor guard:** `#if defined(__linux__)` in `NativeVideoWriter.c`.
- Rationale: Mac is the iteration host; `__linux__` is the exact predicate
  that separates MiSTer HPS builds from Mac iteration builds. Note the 3sx
  reference uses `PORT_MISTER` as the gate; we could do the same, but
  `__linux__` is stricter — it protects against a hypothetical Linux dev box
  accidentally running the `/dev/mem` path, by leaving us one more explicit
  knob.

**Decision: guard with `#if defined(__linux__) && defined(PORT_MISTER)`.**
Both conditions must hold:
- `__linux__`: guarantees POSIX mman.h / fcntl.h / unistd.h are available.
- `PORT_MISTER=1`: emitted by `platforms/MiSTer.cmake:139` (verified). Without
  it, we do not commit to the MiSTer DDR3 contract — a generic Linux dev box
  (e.g. CI runner, Docker builder) does not have the FPGA, and we do not want
  it writing to `0x3A000000`.

On Mac (`__APPLE__`), or on any non-`PORT_MISTER` Linux build, all
NativeVideoWriter functions compile as return-early stubs (matches the
`#else` branch of the 3sx reference).

**Pattern in the `.c` file:**
```c
#include "NativeVideoWriter.h"
#if defined(__linux__) && defined(PORT_MISTER)
    // real implementation
#else
    // stub: Init returns false, others are empty, readers return 0
#endif
```

The **header is always compilable** — no guard. It only declares prototypes
+ inline field extractors; no OS types leak.

---

## File manifest

### New files

#### `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`

Target size: **~45 LOC** (41 in 3sx plus a 320/240 comment block).

Structure:
```c
#ifndef RSDK_MISTER_NATIVE_VIDEO_WRITER_H
#define RSDK_MISTER_NATIVE_VIDEO_WRITER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Writer constants — must match Phase 4 RTL.
// (Values repeated as defines here for ARM-side consumers that want to check
//  the contract from test harnesses; also canonical source for the .c file.)
#define NV_DDR_PHYS_BASE    0x3A000000u
#define NV_DDR_REGION_SIZE  0x00060000u   // 384 KB
#define NV_CTRL_OFFSET      0x00000000u
#define NV_FEEDBACK_OFFSET  0x00000040u
#define NV_BUF0_OFFSET      0x00000100u   // ctrl (4 B at 0x00) + feedback (8 B at 0x40-0x47) + 244 B pad
#define NV_BUF1_OFFSET      0x00025900u   // 0x100 + 0x25800 (NV_FRAME_BYTES)
#define NV_FRAME_WIDTH      320
#define NV_FRAME_HEIGHT     240
#define NV_FRAME_BYTES      (NV_FRAME_WIDTH * NV_FRAME_HEIGHT * 2)  // 153,600

bool    NativeVideoWriter_Init(void);
void    NativeVideoWriter_Shutdown(void);
void    NativeVideoWriter_WriteFrame(const void *pixels_rgb565, int width, int height, int pitch_bytes);
bool    NativeVideoWriter_IsActive(void);
uint32_t NativeVideoWriter_ReadFeedback(void);
uint32_t NativeVideoWriter_ReadFeedbackSeq(void);

static inline uint8_t  NV_FeedbackFrameCounter(uint32_t fb) { return (uint8_t)(fb & 0xFF); }
static inline uint32_t NV_FeedbackTimestampUs(uint32_t fb) { return fb >> 8; }

#ifdef __cplusplus
}
#endif

#endif
```

Differences vs 3sx reference:
- Include guard renamed (`RSDK_MISTER_...` prefix to match RSDKv5 conventions).
- Dimensions changed to 320/240.
- `NV_BUF1_OFFSET` recomputed.
- `extern "C"` wrapper so the C++ render device can call the C API without
  name-mangling issues. (3sx also uses C++ callers; it works because the
  header is textually included into `.cpp` with no `extern "C"`, relying on
  the `static inline` functions being C-compatible. We add the explicit
  `extern "C"` guard because this header is included from
  `Drawing.cpp` (a C++ TU) alongside `MiSTerRenderDevice.cpp` — safer and
  future-proof.)
- Parameter name `pitch_bytes` (vs 3sx's `pitch`): see `.c` spec note below
  — renamed to avoid the footgun where RSDK's `ScreenInfo::pitch` is in
  uint16 pixels. Callers MUST multiply by `sizeof(uint16)`.

**Fragility note on layout constants:** the writer uses `#define` for
`NV_FRAME_WIDTH` / `NV_FRAME_HEIGHT` / `NV_FRAME_BYTES`. If a downstream TU
later `#define`s `NV_FRAME_WIDTH` to a different value before including this
header (or redefines it via `-D`), `NV_FRAME_BYTES` would silently diverge
because it is computed as `NV_FRAME_WIDTH * NV_FRAME_HEIGHT * 2`. Phase 2
accepts this fragility to match 3sx's macro style. Phase 6 should switch
these to `static const uint32_t` and add compile-time assertions
(`_Static_assert(NV_FRAME_BYTES == 153600, …)`) once the toolchain surface
guarantees C11.

#### `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c`

Target size: **~155 LOC** (153 in 3sx; trivial diff from parameter changes).

Structure — **copy 3sx verbatim except**:
1. Include path changes to match the new header location (just `#include
   "NativeVideoWriter.h"` since the header is a sibling).
2. Guard changes from `#if defined(PORT_MISTER)` to
   `#if defined(__linux__) && defined(PORT_MISTER)`.
3. Parameter block: dims/bytes/offsets change per § Parameter table.
4. `NativeVideoWriter_WriteFrame` input validation changes: accept
   `width=320`, `height=240`.
5. **pitch parameter is renamed `pitch_bytes`** (was `pitch` in 3sx, also in
   bytes but with an implicit unit). Clarifies the calling contract at the
   `MiSTerRenderDevice::FlipScreen` site, where the source pitch is
   `screens[0].pitch * 2` (pitch in uint16 pixels → bytes). This name
   divergence from 3sx is INTENTIONAL — RSDKv5's `ScreenInfo::pitch` is in
   uint16 pixels (see `Drawing.cpp:388`'s `screen->pitch = (screen->size.x
   + 15) & 0xFFFFFFF0`), while 3sx's raw byte pitch on its internal path
   was already in bytes. Without the rename, a future RSDKv5 contributor
   who looks at the writer's `pitch` parameter and passes `screens[0].pitch`
   directly (without the `* sizeof(uint16)` multiplier) would silently get
   half-row writes. The `_bytes` suffix forces the question.
6. All `memset`s of the buffer use `NV_FRAME_BYTES` (now 153,600).

Everything else — mmap / O_SYNC / control-word layout / buffer flip — is
byte-for-byte identical to 3sx.

**Critical invariant preserved:** the control-word ordering comment at 3sx
`native_video_writer.c:95-100` must be carried forward verbatim. It documents
why no DSB barrier is needed under `O_SYNC` + `MAP_SHARED`. Any future cache
change invalidates this assumption.

### Modified files

#### `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`

Phase 1 is the current state. Diff described by Step 3 below.

Expected size after Phase 2: **~200 LOC** (currently 180). Adds:
- **No new `#include` lines** (Phase 1 guardrail at lines 6-10 forbids them).
  The writer header is injected from `Drawing.cpp` above the textual
  `#include "MiSTer/MiSTerRenderDevice.cpp"` — see the Drawing.cpp edit below
  and Step 3 §1.
- In `Init()`: set `videoSettings.pixWidth = 320` as the FIRST statement
  (before `SetupRendering`), then call `NativeVideoWriter_Init()`, log status.
- In `SetupRendering()` or `InitGraphicsAPI()`: call
  `SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE)` so screens[0] has
  valid `size.x`, `pitch`, and clip bounds.
- In `FlipScreen()`: call `NativeVideoWriter_WriteFrame(...)` with
  `screens[0].frameBuffer`, `NV_FRAME_WIDTH`, `NV_FRAME_HEIGHT`,
  `screens[0].pitch * sizeof(uint16)`.
- In `Release()`: call `NativeVideoWriter_Shutdown()`.
- **`CopyFrameBuffer()` stays empty**. See ADR below.

#### ADR — Do we call WriteFrame from CopyFrameBuffer or FlipScreen?

3sx puts the write in a frame-loop hook that is the moral equivalent of
FlipScreen (there is no CopyFrameBuffer abstraction in the 3sx port). RSDK
calls `CopyFrameBuffer` then `FlipScreen` back-to-back every frame (see
`RetroEngine.cpp:313,320`). In the SDL2 backend, `CopyFrameBuffer` uploads
the rasterizer's `screens[s].frameBuffer` to a `screenTexture`, and
`FlipScreen` submits geometry that samples those textures — so the texture
upload happens in CopyFrameBuffer but the present happens in FlipScreen.

On MiSTer there is no texture to upload — the rasterizer's frameBuffer IS the
source for our writer, and the writer IS the present. So we should put the
write in whichever hook fires last per frame. Per RSDK ordering that is
`FlipScreen`. CopyFrameBuffer stays empty.

**Decision: write in `FlipScreen`.** Plan step 3 documents this clearly.

##### CopyFrameBuffer left-empty explainer
SDL2 does meaningful work in `CopyFrameBuffer` — specifically, the
`SDL_LockTexture` / `memcpy` / `SDL_UnlockTexture` upload pipeline at
`SDL2RenderDevice.cpp:80-96`. We don't, because on MiSTer there is no
intermediate texture: the rasterizer's `screens[0].frameBuffer` IS the
source of truth and `FlipScreen` writes it directly to DDR3. A side effect
is that SDL2 skips its CopyFrameBuffer work when the window is unfocused,
while our writer always writes. On MiSTer there is no focus concept
(there's no SDL2 window — the FPGA scanout is the display), so this
behavioural divergence is academic. Document here once; do not revisit
unless we ever add an SDL2-style pipeline on MiSTer.

#### `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp`

Exactly one line is added. Above the existing
`#include "MiSTer/MiSTerRenderDevice.cpp"` at line ~144, insert:
```cpp
#elif RETRO_RENDERDEVICE_MISTER
#include "MiSTer/NativeVideoWriter.h"   // Phase 2: must precede the .cpp include
#include "MiSTer/MiSTerRenderDevice.cpp"
```
Rationale: the Phase 1 guardrail at
`MiSTerRenderDevice.cpp:6-10` explicitly forbids `#include` directives
inside that file. Because the `.cpp` is textually pulled into this TU, an
`#include` on the line immediately above has the exact same effect as
placing it at the top of `MiSTerRenderDevice.cpp` — the writer's C API
declarations become visible to the render-device methods — without
touching the guarded file.

Safety: `NativeVideoWriter.h` is self-contained and `extern "C"`-wrapped,
so inclusion in this C++ TU is safe and produces no transitive side
effects.

#### `dependencies/RSDKv5/platforms/MiSTer.cmake`

Add `NativeVideoWriter.c` and `NativeVideoWriter.h` to
`target_sources(RetroEngine PRIVATE ...)`:
```cmake
target_sources(RetroEngine PRIVATE
    RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp
    RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h
    RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c
)
```

Rationale: `MiSTerRenderDevice.cpp` is textually `#include`d by Drawing.cpp
and thus **must not** be a compiled unit (would cause duplicate-symbol errors).
`NativeVideoWriter.c` is the **opposite** — a normal C compile unit, NOT
textually included. It MUST be added to `target_sources` so it compiles.

---

## Dependency graph

```
Step 1 — NativeVideoWriter.h (pure header, no build side effects)
Step 2 — NativeVideoWriter.c (implementation, guarded)
   └── Step 3 — MiSTerRenderDevice.cpp integration
         └── Step 4 — MiSTer.cmake source list (compiles the .c)
               └── Step 5 — Mac build verification
                     └── Step 6 — armhf cross-compile
                           └── Step 7 — MiSTer deploy + devmem2 probe
```

Each step is one `/implement` invocation. Steps 1–4 are edits only; 5–7 are
verification gates and may trigger go-back-and-fix loops in earlier steps.

---

## Step 1 — Create `NativeVideoWriter.h`

### Why it matters
Header declares the public API consumed by `MiSTerRenderDevice.cpp`. Must be
first so subsequent steps have a compilable target. No runtime side effects.

### Files to read first
- `/Users/sb/Developer/3sx-mister/src/port/sdl/native_video_writer.h` (41 LOC).
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-4-plan.md` §0 and §6.1 to
  verify parameter constants against RTL side.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp`
  (to confirm no conflicting definitions).

### Files to create
**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`**

Follow the exact structure in § File manifest above. Key requirements:
- Include guard `RSDK_MISTER_NATIVE_VIDEO_WRITER_H`.
- `#include <stdbool.h>` and `<stdint.h>`.
- `extern "C"` brackets for C++ callers.
- All numeric constants as `#define` with the exact values from the Parameter
  table.
- `uint32_t` return type on `ReadFeedback` / `ReadFeedbackSeq`.
- Parameter on `WriteFrame` named `pitch_bytes` (not `pitch`) — clarifies unit.
- **No** `<stdio.h>` / `<sys/mman.h>` / `<fcntl.h>` includes — those are
  `.c`-only.

### Files to modify
None.

### Success criteria
- File exists at the exact path.
- `grep -c '^#define NV_' dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
  ≥ 9 (the 9 constants in § Parameter table).
- Compiles cleanly when included from a C++ unit:
  `clang -fsyntax-only -xc++ dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
  (tolerates -std=c++11 and up).
- Compiles cleanly when included from a C unit:
  `clang -fsyntax-only -xc dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
- `grep -cE 'NV_FRAME_WIDTH.*320|NV_FRAME_HEIGHT.*240|NV_FRAME_BYTES.*153' dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
  ≥ 3 (ensures the 320/240/153600 values are present; `-E` enables ERE
  alternation — without it the `\|` is a literal string and the grep
  silently returns 0).
- `grep 'NV_BUF1_OFFSET' dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
  shows `0x00025900` or `0x25900`.

### Dependencies
None.

### What NOT to do
- Do NOT put implementation in the header (no mmap, no file handles).
- Do NOT include OS-specific headers (`fcntl.h`, `sys/mman.h`, `unistd.h`,
  `stdio.h`). Header must be portable to Mac and Linux without modification.
- Do NOT gate constants with `#if defined(PORT_MISTER)` — the constants are
  always defined so that Phase 4 test harnesses / the RTL-side spec docs /
  unit tests can all reference them.
- Do NOT add any declaration that mentions SDL, Drawing.hpp, or RSDKv5
  internals. This is a pure C header.

### Failure mode & recovery
- If the header fails to compile under C++: `extern "C"` bracket is
  missing or mis-placed. Inspect that both the open `extern "C" {` and close
  `}` are inside the `#ifdef __cplusplus` guards.
- If the `-xc` check fails: bool/stdint were not included. Add
  `<stdbool.h>` / `<stdint.h>`.

---

## Step 2 — Create `NativeVideoWriter.c`

### Why it matters
This is the implementation: mmaps `/dev/mem`, maintains double buffer state,
writes control word. Guarded so Mac builds compile but no-op at runtime.

### Files to read first
- `/Users/sb/Developer/3sx-mister/src/port/sdl/native_video_writer.c` (153
  LOC, entire file).
- The freshly-created `NativeVideoWriter.h` from Step 1.
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt` — verify 3sx's gating
  pattern before adapting. (3sx uses `#if defined(PORT_MISTER)`; we add
  `__linux__`.)

### Files to create
**`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c`**

Structure (pseudocode — follow 3sx exactly for the Linux path):

```c
#include "NativeVideoWriter.h"

#if defined(__linux__) && defined(PORT_MISTER)

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int mem_fd = -1;
static volatile uint8_t *ddr_base = NULL;
static uint32_t frame_counter = 0;
static int active_buf = 0;

bool NativeVideoWriter_Init(void) {
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("NativeVideoWriter: open /dev/mem");
        return false;
    }

    ddr_base = (volatile uint8_t *)mmap(NULL, NV_DDR_REGION_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, NV_DDR_PHYS_BASE);
    if (ddr_base == MAP_FAILED) {
        perror("NativeVideoWriter: mmap");
        ddr_base = NULL;
        close(mem_fd);
        mem_fd = -1;
        return false;
    }

    memset((void *)(ddr_base + NV_BUF0_OFFSET), 0, NV_FRAME_BYTES);
    memset((void *)(ddr_base + NV_BUF1_OFFSET), 0, NV_FRAME_BYTES);
    volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
    *ctrl = 0;
    frame_counter = 0;
    active_buf = 0;

    volatile uint32_t *feedback = (volatile uint32_t *)(ddr_base + NV_FEEDBACK_OFFSET);
    *feedback = 0;
    volatile uint32_t *feedback_seq = (volatile uint32_t *)(ddr_base + NV_FEEDBACK_OFFSET + 4);
    *feedback_seq = 0;

    return true;
}

void NativeVideoWriter_Shutdown(void) {
    if (ddr_base) {
        volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
        *ctrl = 0;
        munmap((void *)ddr_base, NV_DDR_REGION_SIZE);
        ddr_base = NULL;
    }
    if (mem_fd >= 0) {
        close(mem_fd);
        mem_fd = -1;
    }
}

void NativeVideoWriter_WriteFrame(const void *pixels_rgb565, int width, int height, int pitch_bytes) {
    if (!ddr_base || width != NV_FRAME_WIDTH || height != NV_FRAME_HEIGHT) {
        return;
    }
    uint32_t buf_offset = (active_buf == 0) ? NV_BUF0_OFFSET : NV_BUF1_OFFSET;
    volatile uint8_t *dst = ddr_base + buf_offset;

    if (pitch_bytes == NV_FRAME_WIDTH * 2) {
        memcpy((void *)dst, pixels_rgb565, NV_FRAME_BYTES);
    } else {
        const uint8_t *src = (const uint8_t *)pixels_rgb565;
        for (int y = 0; y < NV_FRAME_HEIGHT; y++) {
            memcpy((void *)(dst + y * NV_FRAME_WIDTH * 2), src + y * pitch_bytes, NV_FRAME_WIDTH * 2);
        }
    }

    /*
     * Write ordering: on O_SYNC + MAP_SHARED device memory, ARM guarantees
     * prior pixel writes complete before this control write. Changing to
     * cached memory or softer mappings would require a DSB barrier here.
     * (Verbatim carry-over from 3sx.)
     */
    frame_counter++;
    volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
    *ctrl = (frame_counter << 2) | (active_buf & 1);

    active_buf ^= 1;
}

bool NativeVideoWriter_IsActive(void) { return ddr_base != NULL; }

uint32_t NativeVideoWriter_ReadFeedback(void) {
    if (!ddr_base) return 0;
    return *(volatile uint32_t *)(ddr_base + NV_FEEDBACK_OFFSET);
}

uint32_t NativeVideoWriter_ReadFeedbackSeq(void) {
    if (!ddr_base) return 0;
    return *(volatile uint32_t *)(ddr_base + NV_FEEDBACK_OFFSET + 4);
}

#else

/* Non-Linux or non-MiSTer build: writer is a compile-in but runtime no-op. */

bool     NativeVideoWriter_Init(void)                                                        { return false; }
void     NativeVideoWriter_Shutdown(void)                                                    {}
void     NativeVideoWriter_WriteFrame(const void *p, int w, int h, int pb)                   { (void)p; (void)w; (void)h; (void)pb; }
bool     NativeVideoWriter_IsActive(void)                                                    { return false; }
uint32_t NativeVideoWriter_ReadFeedback(void)                                                { return 0; }
uint32_t NativeVideoWriter_ReadFeedbackSeq(void)                                             { return 0; }

#endif
```

### Files to modify
None.

### Success criteria
- File exists at the exact path.
- `grep -c 'NV_FRAME_WIDTH\|NV_FRAME_HEIGHT\|NV_BUF' .../NativeVideoWriter.c`
  — all references use the macros from the header (no literal 320 / 240 /
  153600 / 0x25900 duplicated in the `.c`).
- Line count is within 10% of 3sx reference (i.e. 140–170 LOC).
- `clang -fsyntax-only -I<hdr-dir> dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c`
  succeeds on Mac (stub branch only, Mac is `__APPLE__` so guard is false).
- `clang -fsyntax-only -DPORT_MISTER=1 --target=arm-linux-gnueabihf …`
  succeeds in the Phase 0 container (Linux branch active, pulls POSIX
  headers).

### Dependencies
Step 1 (header must exist).

### What NOT to do
- Do NOT duplicate the macro values. All numeric constants come from the
  header.
- Do NOT add `static_assert` / `_Static_assert` on `NV_FRAME_BYTES` — C11 is
  not guaranteed by the RSDKv5 toolchain surface.
- Do NOT add DSB barriers or cache flushes. The comment block explicitly
  documents why they're not needed.
- Do NOT call `PrintLog` from this file. It is a C TU and does not have the
  RSDK namespace / logging surface. Use `perror` or `fprintf(stderr, ...)`.
- Do NOT add ARGB8888→RGB565 conversion. Mania is RGB565 native; the
  conversion function from 3sx is deliberately dropped.

### Failure mode & recovery
- If Mac build fails because POSIX headers are pulled: guard failed, verify
  `#if defined(__linux__) && defined(PORT_MISTER)` exactly.
- If armhf build fails at link with `undefined reference to mmap`: missing
  `-lc` or glibc sysroot mis-configured. Not a Phase 2 bug — escalate to
  Phase 0.
- If the writer initializes but frames aren't visible (forward reference
  to Step 7): dims mismatch between `.h` and `.c`, or wrong `NV_BUF1_OFFSET`.
  Re-verify against Phase 4 §6.1.

---

## Step 3 — Wire writer into `MiSTerRenderDevice.cpp`

### Why it matters
This is the engine-side integration. Without it, the writer sits orphaned and
no frames reach DDR3.

### Files to read first
- Current
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
  (Phase 1 skeleton, 180 LOC).
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp` lines
  79-96 (CopyFrameBuffer reference) and 79-100 (FlipScreen reference).
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` lines 132-146 (the
  backend-dispatch `#if RETRO_RENDERDEVICE_*` chain where the writer header
  `#include` will be injected), 381-414 (`SetScreenSize`), and 159-167
  (`screens[]` / `currentScreen` / `videoSettings` globals).
- **Phase 1 guardrail comment at
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
  lines 6-10** — the "Do NOT add #include directives here" comment is the
  reason the writer header is injected from `Drawing.cpp` instead of
  `MiSTerRenderDevice.cpp`.
- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` lines 47-108 (the
  `Init` / `InitShaders` / frame loop sequence).

### Files to modify
1. **`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp`** — single-line
   edit to inject the writer header above the textual
   `#include "MiSTer/MiSTerRenderDevice.cpp"`.
2. **`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`**
   — body-only edits (NO new `#include` lines; guardrail at lines 6-10).

Precise diff:

1. **`Drawing.cpp` ~line 144** — add exactly one `#include` line **above**
   the existing `#include "MiSTer/MiSTerRenderDevice.cpp"`:
   ```cpp
   #elif RETRO_RENDERDEVICE_MISTER
   #include "MiSTer/NativeVideoWriter.h"   // Phase 2: writer C API, must precede the .cpp include
   #include "MiSTer/MiSTerRenderDevice.cpp"
   ```

   **Why Drawing.cpp and not MiSTerRenderDevice.cpp:** the guardrail comment
   at `MiSTerRenderDevice.cpp:6-10` (Phase 1) explicitly says "Do NOT add
   #include directives here." Adding the writer header in
   `MiSTerRenderDevice.cpp` would violate that invariant. Placing it on
   the line directly above the textual `.cpp` include in `Drawing.cpp` has
   the same preprocessor effect (the header's declarations are visible to
   the render-device method bodies) while preserving the Phase 1 guardrail.
   `NativeVideoWriter.h` is `extern "C"`-wrapped and self-contained, so it
   is safe to include from `Drawing.cpp`'s C++ TU.

   **Cross-ref:** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:144-145`
   is the existing MiSTer arm; the new line lands between the `#elif` and
   the `.cpp` include.

2. **Inside `RenderDevice::Init()`** (currently lines 27-33) the
   `videoSettings.pixWidth = 320` assignment **must be the FIRST statement
   of `RenderDevice::Init()`, before the existing
   `if (!SetupRendering()) return false;` line**. The writer init goes
   AFTER `SetupRendering()` returns successfully.

   Before (current Phase 1 state, lines 27-33):
   ```cpp
   bool RenderDevice::Init()
   {
       PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Init()");
       if (!SetupRendering())
           return false;
       // ...rest of Phase 1 body
   }
   ```

   After (Phase 2):
   ```cpp
   bool RenderDevice::Init()
   {
       videoSettings.pixWidth = 320;      // Mania 4:3 narrow width (engine default is 424)
       // Clamp pixWidth to MiSTer native resolution. Decision #1.
       // Must be FIRST statement so SetupRendering → InitGraphicsAPI →
       // SetScreenSize observe the clamped value. LoadSettingsINI() may have
       // read a stale 424 from an upstream settings.ini; overwrite
       // unconditionally.
       PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Init: pixWidth=%d SCREEN_YSIZE=%d", videoSettings.pixWidth, SCREEN_YSIZE);

       if (!SetupRendering()) return false;

       if (!NativeVideoWriter_Init()) {
           PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Init: NativeVideoWriter_Init FAILED (likely Mac host or /dev/mem inaccessible) — continuing as no-op");
           // Do NOT return false: the rest of the engine should still come up so
           // the Mac iteration path still logs and the armhf binary run under a
           // non-root UID can still exit cleanly with a visible error rather
           // than a silent crash.
       }
       // ...rest of Phase 1 body unchanged
   }
   ```

   Final Init() order (crystal-clear):
   1. `videoSettings.pixWidth = 320;`        — first statement
   2. `if (!SetupRendering()) return false;` — existing; internally calls
      `InitGraphicsAPI` which calls `SetScreenSize(0, 320, 240)`
   3. `NativeVideoWriter_Init()`             — after the rendering surface is up

3. **Inside `RenderDevice::InitGraphicsAPI()`** (current lines 45-49): add
   a call to `SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE)` so
   `screens[0].size.x` / `.pitch` / clip bounds are populated. Without this,
   the rasterizer sees `size.x == 0` and `DrawRectangle`/etc. produce no
   output — the test visibility from Step 7 would fail silently.
   ```cpp
   bool RenderDevice::InitGraphicsAPI()
   {
       PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::InitGraphicsAPI() [stub]");
       // Phase 2: establish screen geometry so the software rasterizer knows
       // valid pitch / clip bounds. Mania is single-screen.
       SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE);
       return true;
   }
   ```

4. **Replace `RenderDevice::FlipScreen()`** (currently lines 72-75, empty
   stub) with:
   ```cpp
   void RenderDevice::FlipScreen()
   {
       // Mania is single-screen; screens[0].frameBuffer holds the freshly-
       // rasterized RGB565 frame. screens[0].pitch is in UINT16 pixels, so
       // multiply by sizeof(uint16) for the byte pitch the writer expects.
       if (screens[0].size.x != NV_FRAME_WIDTH || screens[0].size.y != NV_FRAME_HEIGHT) {
           // Defensive: the engine might reconfigure mid-run (SetScreenSize
           // calls from mods / cutscenes). If dims drift from the writer's
           // contract, skip this frame — the writer would reject it anyway.
           return;
       }
       NativeVideoWriter_WriteFrame(screens[0].frameBuffer,
                                     NV_FRAME_WIDTH,
                                     NV_FRAME_HEIGHT,
                                     screens[0].pitch * (int)sizeof(uint16));
   }
   ```

5. **Replace `RenderDevice::Release(bool32 isRefresh)`** (currently lines
   77-80) with:
   ```cpp
   void RenderDevice::Release(bool32 isRefresh)
   {
       PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Release(isRefresh=%d)", (int)isRefresh);
       if (!isRefresh) {
           // Full shutdown only on the final teardown; Refresh is used by
           // the engine for windowed<->fullscreen transitions etc., which
           // are no-ops for our FPGA-driven scanout.
           NativeVideoWriter_Shutdown();
       }
   }
   ```

6. **`CopyFrameBuffer()` stays empty** (currently lines 67-70). Confirm it
   still logs nothing per-frame. Add a short comment pointing at FlipScreen:
   ```cpp
   void RenderDevice::CopyFrameBuffer()
   {
       // Intentionally empty on MiSTer. The rasterizer's frameBuffer IS the
       // DDR3 source; there is no intermediate texture to upload. The actual
       // DDR3 write happens in FlipScreen() — that is the last hook per
       // frame (see RetroEngine.cpp:313,320) so state is settled by then.
   }
   ```

### Files to modify (secondary)
None beyond `Drawing.cpp` and `MiSTerRenderDevice.cpp` (both listed in
the primary "Files to modify" block above).

### Success criteria
- `git diff dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp`
  shows exactly one added line: `#include "MiSTer/NativeVideoWriter.h"`
  immediately above the existing `#include "MiSTer/MiSTerRenderDevice.cpp"`.
  No other edits to `Drawing.cpp`.
- `git diff dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
  shows:
  - **Zero `#include` additions** (Phase 1 guardrail preserved).
  - +4 lines in `Init()` body — `videoSettings.pixWidth = 320` as the first
    statement, then `NativeVideoWriter_Init` call, plus log lines.
  - +1 `SetScreenSize` line in `InitGraphicsAPI()`.
  - ~8 lines added to `FlipScreen()` (real write body).
  - ~3 lines modified in `Release()`.
  - Comment-only delta to `CopyFrameBuffer()`.
- `grep -n '^#include' dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
  returns zero lines (the Phase 1 guardrail file stays include-free).
- No other methods changed.
- Mac build (PORT_MISTER=ON): still runs, logs Init line "pixWidth=320
  SCREEN_YSIZE=240", NativeVideoWriter_Init returns false (Mac stub), the log
  shows "NativeVideoWriter_Init FAILED" once. No SIGSEGV; engine continues to
  the "missing Data.rsdk" exit just like Phase 1.

### Dependencies
Steps 1, 2 (header + source must compile).

### What NOT to do
- Do NOT move the pixWidth assignment into `UserCore.cpp` (upstream patch
  boundary — we avoid any upstream patch in Phase 2; Phase 1 already paid
  that cost).
- Do NOT add a `windowed=true` / viewport override in `Init`. The viewport
  fields are unused until Phase 6.
- Do NOT try to populate `displayInfo.displays[]` in `Init`. Drawing.cpp's
  display-iteration block is guarded by `displayCount > 0`; our
  `GetDisplays()` stub keeps it at 0.
- Do NOT `SetScreenSize(s, ...)` for `s > 0`. Mania is single-screen; touching
  screens[1..3] would be wasted work and could mask a future multi-screen
  mod bug.
- Do NOT introduce NEON / ARGB conversion. RGB565 is native.
- Do NOT add `#if defined(__linux__)` around the `NativeVideoWriter_*` calls
  in `MiSTerRenderDevice.cpp`. The writer's `.c` already handles the Mac
  stub internally; wrapping the call sites would be redundant AND hide
  compile errors if the header signature drifts.

### Failure mode & recovery
- **"undefined reference to NativeVideoWriter_Init" at link:** the `.c` is
  not being compiled. Step 4 (CMake) landed incorrectly or was skipped.
- **"error: no member named 'frameBuffer' in 'struct ScreenInfo'":** the
  writer header was (wrongly) added inside `MiSTerRenderDevice.cpp` at a
  point that disrupted include ordering, violating the Phase 1 guardrail.
  Revert that file's include list to Phase 1 state (zero includes) and move
  the `#include "MiSTer/NativeVideoWriter.h"` into `Drawing.cpp` above the
  `#include "MiSTer/MiSTerRenderDevice.cpp"` line (Step 3 §1).
- **"implicit declaration of function 'NativeVideoWriter_Init'"** in the
  `MiSTerRenderDevice.cpp` compile: Step 3 §1's `Drawing.cpp` edit was
  skipped — the writer header declarations never became visible. Verify
  the `#include "MiSTer/NativeVideoWriter.h"` line in Drawing.cpp.
- **Mac build logs "Init: pixWidth=424" instead of 320:** the assignment is
  after `SetupRendering` instead of before. Move it to the first line of
  `Init()`.
- **Runtime crash during `FlipScreen`:** `screens[0].size` is (0,0) because
  `SetScreenSize` was never called, OR `currentScreen` is dangling. Double-
  check the `SetScreenSize` call landed in `InitGraphicsAPI()` and that
  `InitGraphicsAPI()` runs from `SetupRendering`.
- **`NativeVideoWriter_Init` returns false on MiSTer (not Mac):** likely
  running as non-root (`/dev/mem` wants root) or the HPS bridge to DDR3 is
  not opened. Escalate to Phase 4: the wrapper's launch environment must
  allow `/dev/mem` (3sx already runs as root via the MiSTer main binary).

---

## Step 4 — Update `platforms/MiSTer.cmake` to compile the `.c`

### Why it matters
`NativeVideoWriter.c` is a real compile unit (not textually included). It must
be added to the `RetroEngine` target's source list.

### Files to read first
- Current
  `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake`
  (verified present; lines 129-131 already list `MiSTerRenderDevice.hpp`).

### Files to modify
**`dependencies/RSDKv5/platforms/MiSTer.cmake`**

Locate the existing `target_sources(RetroEngine PRIVATE ...)` block at
lines 129-131 and extend it:
```cmake
target_sources(RetroEngine PRIVATE
    RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp
    RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h
    RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c
)
```

Update the surrounding comment to reflect that the `.c` IS a compiled unit
while the `.cpp` is NOT:
```cmake
# MiSTerRenderDevice.cpp is textually #include'd by Drawing.cpp (see
# Drawing.cpp:132-146 after Phase 1 patch) — do NOT add it here (duplicate
# symbols).
# NativeVideoWriter.c IS a normal compile unit; add it here so the linker
# picks it up. Guarded internally with #if defined(__linux__) &&
# defined(PORT_MISTER); Mac builds compile it as a no-op stub.
```

### Files to modify (secondary)
None.

### Success criteria
- `grep -n 'NativeVideoWriter\.c' dependencies/RSDKv5/platforms/MiSTer.cmake`
  returns a hit inside the `target_sources` block.
- On Mac with PORT_MISTER=ON, a clean reconfigure + build succeeds without
  `duplicate symbol` or `undefined reference` errors.
- On armhf cross-compile (Phase 0 container) the build still completes. This
  is tested in Step 6.
- Non-MiSTer builds (e.g. `-DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2`) still
  configure and build — MiSTer.cmake is never included in those.

### Dependencies
Steps 1, 2, 3 (all source must be in place before CMake pulls it in).

### What NOT to do
- Do NOT add `target_compile_definitions(RetroEngine PRIVATE PORT_MISTER=1)`
  here — it's already set at line 139 of this CMake file. Re-adding would
  not cause a build error but would be misleading.
- Do NOT create a separate target or library for the writer (e.g. `add_library
  (NativeVideoWriter STATIC ...)`). Keep it a TU of `RetroEngine` for
  simplicity; there is no reuse requirement.
- Do NOT add `-std=c11` or `-std=gnu99` flags for this `.c`. It compiles
  fine under the engine's ambient toolchain setting.

### Failure mode & recovery
- "undefined reference to NativeVideoWriter_Init" at link: the file name
  in `target_sources` is wrong OR the path is relative to the wrong dir.
  CMake resolves this path relative to the directory of the CMakeLists.txt
  that `include()`s this platform file, which is
  `dependencies/RSDKv5/CMakeLists.txt`. So the path must be
  `RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c` (relative to
  `dependencies/RSDKv5/`). This matches how `MiSTerRenderDevice.hpp` is
  already listed.

---

## Step 5 — Mac build verification (PORT_MISTER=ON)

### Why it matters
First post-Phase-2 smoke test. Confirms:
- Everything compiles.
- Writer runs as a no-op on Mac (Mac is `__APPLE__` so `__linux__` guard is
  false).
- Engine still reaches the "missing Data.rsdk" exit without SIGSEGV.

### Files to read first
- `phase-1-plan.md` Step 6 (Mac acceptance procedure) — re-use the same
  log-path hygiene.

### Files to modify
None.

### Verification procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
rm -rf build-mister
cmake -S . -B build-mister -DPORT_MISTER=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build-mister -j
```

Expected artifacts:
- `build-mister/dependencies/RSDKv5/RSDKv5U` exists, is Mach-O.
- Build log contains no error or undefined-reference.

Runtime:
```bash
rm -f "$HOME/Library/Application Support/RSDKv5/log.txt"
./build-mister/dependencies/RSDKv5/RSDKv5U &
P=$!
sleep 10
kill $P 2>/dev/null || true
wait $P 2>/dev/null || true
grep "MiSTerRenderDevice::\|NativeVideoWriter" \
    "$HOME/Library/Application Support/RSDKv5/log.txt"
```

### Success criteria
- Build exits 0 with no errors (warnings are fine).
- Log shows `MiSTerRenderDevice::Init: pixWidth=320 SCREEN_YSIZE=240`.
- Log shows `MiSTerRenderDevice::Init: NativeVideoWriter_Init FAILED (likely
  Mac host or /dev/mem inaccessible) — continuing as no-op` exactly once.
- No `SIGSEGV` / crash before this line.
- Binary exits (naturally on missing `Data.rsdk`) within the 10 s sleep.

### Dependencies
Steps 1-4.

### What NOT to do
- Do NOT work around the Mac `Init FAILED` log line. It's the INTENDED
  behavior on Mac.
- Do NOT run this test against a stale `build-mister` dir. Always `rm -rf`.

### Failure mode & recovery
- `grep` returns 0: the log file is elsewhere, check
  `find "$HOME/Library/Application Support" -name log.txt -mmin -5`.
- Build fails with `undefined reference to NativeVideoWriter_*`: Step 4 is
  missing the `.c` in target_sources. Verify and rebuild.
- Build fails at `MiSTerRenderDevice.cpp` with `unknown type uint32_t`: the
  `.h` is missing `<stdint.h>` or the `.cpp` is being compiled outside the
  RSDK namespace. Re-check Step 1 header and Step 3's `#include` placement.
- Runtime SIGSEGV: `NativeVideoWriter_Init`'s Mac stub is not returning
  false; check `__linux__` guard.

---

## Step 6 — armhf cross-compile verification

### Why it matters
Confirms the Linux branch of the writer compiles against the armhf sysroot
and the engine/game links successfully.

### Files to read first
- `phase-0-plan.md` — the cross-compile container setup and `build-game.sh`
  driver.
- `docs/mister-runbook.md` — cross-compile env summary.

### Files to modify
None.

### Verification procedure
Inside the Phase 0 cross-compile container (per Phase 0 plan):
```bash
tools/mister/build-game.sh --flavor telemetry    # or the Phase 0-equivalent
```
OR, if that script is not yet authored in Phase 0, a manual cmake invocation:
```bash
cmake -S . -B build-mister-armhf \
    -DPORT_MISTER=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=/path/to/armhf-clang20.toolchain.cmake
cmake --build build-mister-armhf -j
```

### Success criteria
- `file build-mister-armhf/dependencies/RSDKv5/RSDKv5U` →
  `ELF 32-bit LSB executable, ARM, EABI5 …`
- Binary links with no `undefined reference` for any `NativeVideoWriter_*`
  symbol.
- `nm build-mister-armhf/dependencies/RSDKv5/RSDKv5U | grep NativeVideoWriter`
  shows all 6 function symbols (Init, Shutdown, WriteFrame, IsActive,
  ReadFeedback, ReadFeedbackSeq).
- ARM hardening flags appear in the compile log:
  `-mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard`.

### Dependencies
Step 5 (Mac smoke passed), plus Phase 0 having delivered a working container.

### What NOT to do
- Do NOT introduce any armhf-specific tweak in this phase. If the build
  fails, the fault is either in our code (fix here) or in Phase 0 (escalate);
  we do not paper over it with conditional logic.

### Failure mode & recovery
- If `NativeVideoWriter_Init` symbol is missing from the binary: `.c` was
  not compiled (Step 4 CMake issue) OR the `#if __linux__ && PORT_MISTER`
  guard is not firing (check `cmake --build -v` output for `-DPORT_MISTER=1`
  on the armhf compile line).
- If compile fails with "no mmap": likely a sysroot bug in Phase 0, not
  Phase 2.

---

## Step 7 — MiSTer deploy + `devmem2` probe

### Why it matters
This is the true Phase 2 exit criterion: proves the writer actually reaches
DDR3 at the correct address with non-zero RGB565 data.

### Files to read first
- `docs/mister-runbook.md` — SSH flow, binary deploy path.
- `reference-mister-credentials.md` memory — host `192.168.1.188`, password `1`.

### Prerequisites
- armhf binary from Step 6.
- MiSTer reachable over SSH.
- User's `Data.rsdk` at `/media/fat/games/Sonic Mania/Data.rsdk` (for the
  engine to initialize — without it, the engine exits before rendering any
  frames, and the writer never emits to DDR3. If the user does not have the
  game assets, Phase 2 cannot be verified end-to-end; use the Phase 4 §10.2
  synthetic test-frame writer as a substitute.).
- **No FPGA core** (or any non-Mania core) may be loaded. The 3S-ARM core
  also uses region `0x3A000000`; running the test while 3S-ARM is loaded
  would produce confusing readback. Safest: boot the MiSTer main menu (any
  standard Linux console) and do the probe before loading any core.
- The binary must be run as root (for `/dev/mem` access). MiSTer's default
  SSH user is root (confirmed); `whoami` should return `root` before the
  probe. Launching via the MiSTer wrapper menu (Phase 4) also runs as root.
  If `NativeVideoWriter_Init()` fails to open `/dev/mem`, look for `EACCES`
  in the engine log — this indicates a non-root execution context (unlikely
  on MiSTer but possible on other HPS distros or if the binary is launched
  via a demoted shell). The fallback diagnostic is
  `strace -e openat ./RSDKv5U` — inspect the `openat(... "/dev/mem" ...)`
  return code to confirm EACCES vs ENOENT vs another error.

### Verification procedure

**Deploy:**
```bash
scp build-mister-armhf/dependencies/RSDKv5/RSDKv5U root@192.168.1.188:/media/fat/games/Sonic\ Mania/RSDKv5U
# Data.rsdk alongside; user-supplied
```

**Run + probe (in one SSH session):**
```bash
ssh root@192.168.1.188
cd /media/fat/games/Sonic\ Mania

# Launch the binary in the background with SDL dummy driver (Phase 3 will
# wire real input/audio — Phase 2 just wants the frame loop running).
# Note: SDL_VIDEODRIVER=dummy preserves SDL2's audio/event subsystem init
# path (they share an SDL_Init call) while suppressing any SDL2 video
# init attempt. It is harmless for the MiSTer render device — which is
# NOT an SDL2 backend — but keeps the launch identical to how Phase 3
# will eventually exercise the binary under a real runtime.
SDL_VIDEODRIVER=dummy ./RSDKv5U &
P=$!
sleep 5    # let Init + first frames land

# Control word (offset 0x00): should be non-zero and the low 2 bits toggle
# between 0 and 1 as the writer flips buffers. Run this a few times:
devmem2 0x3A000000 w    # read control word
devmem2 0x3A000000 w
devmem2 0x3A000000 w

# Dump 32 bytes from BUF0 (0x100) and BUF1 (0x25900). Should show non-zero
# RGB565 data while the game is animating, and they should differ from each
# other (double-buffering).
devmem2 0x3A000100 w
devmem2 0x3A025900 w

# Cleanup:
kill $P
wait $P 2>/dev/null
```

### Expected output
- First control-word read: some value of the form `(frame_counter << 2) |
  active_buf`. The high bits (`value >> 2`) increase monotonically between
  successive reads. The low 2 bits toggle between `0` and `1` on each frame.
- Raw buffer reads: non-zero 32-bit words. Most title/menu screens are not
  uniform black, so at least some non-zero pixels should appear. If the
  engine is stuck on a black loading screen, dump after a 10-second delay
  to let it advance.

### Success criteria
- `devmem2 0x3A000000 w` returns a value whose top 30 bits change between
  successive reads (proves the writer's `frame_counter++` is firing).
- `devmem2 0x3A000100 w` and `devmem2 0x3A025900 w` return non-zero values.
- Running the three control-word reads back-to-back, at least two different
  values of the low 2 bits appear across the samples (proves the
  double-buffer flip is actually happening).
- Binary does not crash during the 5-s run (no core dump, no stack trace in
  the log).
- No visible picture is expected (no FPGA core); the monitor can show MiSTer
  menu chrome throughout. That's fine.

### Dependencies
Step 6 (binary ready) + MiSTer access + Data.rsdk on device.

### What NOT to do
- Do NOT run this with a core loaded that uses region `0x3A000000` (any 3sx
  core, or the eventual Sonic Mania core). The core is an active consumer/
  writer of the feedback region; readings would be noisy and potentially
  misleading.
- Do NOT use `rsync --delete` when deploying the binary. Per
  `feedback-no-rsync-delete.md`.
- Do NOT `/media/fat/_Other/*.rbf` — Phase 2 deploys no RBF. Phase 4 does.
- Do NOT attempt HDMI/VGA visibility. The FPGA reader is Phase 4.

### Failure mode & recovery
- `devmem2` not installed: `opkg install devmem2` on MiSTer, OR use
  `busybox devmem` if present, OR use a quick Python one-liner.
  (Memory: MiSTer's stock Linux has `devmem2` per the 3sx runbook.)
- Control word stays zero: NativeVideoWriter_Init failed silently.
  `grep NativeVideoWriter /tmp/RSDKv5-log.txt` (or wherever the log file
  lands — the exact user-file dir on armhf per the engine's
  `SKU.userFileDir` is `~/.local/share/RSDKv5/` or the game's working dir).
  If the log shows `EACCES` on the `/dev/mem` open, you are running as a
  non-root user — re-run as root (`whoami` must return `root`). If that
  check is clean, fall back to `strace -e openat ./RSDKv5U 2>&1 | grep mem`
  to inspect the exact `openat` return code and argument path.
- Buffer reads are all zero: the writer is mmapping correctly but `WriteFrame`
  is short-circuiting. Likely `screens[0].size.x != 320` — check the
  `SetScreenSize` call landed in `InitGraphicsAPI()`.
- Data is changing but dims are weird (off-by-one, garbage): mismatched
  pitch. Verify `screens[0].pitch * sizeof(uint16)` matches what the writer
  expects at byte pitch. If `pitch == 320`, byte pitch = 640 = 320*2; the
  writer's fast path hits.

---

## Risk register (Phase 2)

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R-1 | `devmem2` unavailable on MiSTer image | Low | Use `busybox devmem`, or a small `dd if=/dev/mem bs=4 count=1 skip=$((0x3A000000/4))` fallback, or ship a tiny probe binary as part of Phase 0's test deliverables. |
| R-2 | Running binary as non-root, `/dev/mem` refuses | Medium | MiSTer default shell is root; the wrapper (Phase 4) also runs as root. Document in plan; do not silently degrade to a broken visible path. |
| R-3 | `screens[0]` not set up when `FlipScreen` fires (early frames or mod paths) | Medium | `FlipScreen` already guards on `size.x != NV_FRAME_WIDTH`, so stale frames are dropped rather than crashing. Still: the `SetScreenSize` call in Step 3 is mandatory. |
| R-4 | `NativeVideoWriter_Init` fails silently on Mac and leaves caller thinking the writer is ready | Low | `Init()` logs the FAILED case explicitly. `IsActive()` returns the ground truth; consumers should call it before depending on frames landing. |
| R-5 | Buffer alignment: `memcpy` fast path assumes `pitch_bytes == 640` | Low | For `pixWidth=320`, `ScreenInfo::pitch=320` pixels = 640 bytes, always. Tested as exact equality in the fast branch; falls back to row-by-row otherwise. |
| R-6 | Address collision with 3sx core if both cores are in use on the same MiSTer | None | Only one core loaded at a time per MiSTer architecture (RBF switch power-cycles). Documented in phase-4-plan.md §6.1. |
| R-7 | Future cache-mode change breaks ordering | Low | The O_SYNC comment in the `.c` is a permanent warning. Phase 6 / perf work must re-evaluate before switching to cached mappings. |
| R-8 | Engine or mod code resizes screens[0] mid-run via `SetVideoSetting` | Low | `FlipScreen` dimension guard drops such frames; the writer refuses non-320×240. Acceptable until Phase 7 polish. |
| R-9 | Engine renders at default 424 before our Init overrides | Low | `Init` runs before the first `FlipScreen` (per `RetroEngine.cpp:51-108` and 313-320). The first frame is also preceded by `InitGraphicsAPI` → `SetScreenSize(0, 320, …)`. Race-free. |
| R-10 | User does not have `Data.rsdk`; Step 7 probe cannot observe frames | Medium | Use Phase 4 §10.2 synthetic test-frame writer as a substitute — fall back to `/implement` Step 5 of Phase 4 if in-engine rendering is unavailable. Plan documents this explicitly above. |
| R-11 | `SetScreenSize(1..3)` skipped — screens[1..3] remain zero-dimensioned | Low | Plan calls `SetScreenSize` only for screen 0 (Mania's `screenCount=1`). The SDL2 backend calls it for `s=0..3`. If any Legacy GFX_* path, dev-menu rasterizer, or mod touches `screens[1..3]` before the per-frame `screenCount` gate, a null-deref / zero-size read is possible. Low probability with Mania-only assets; flag if symptoms (blank dev menus, mod crashes) appear in Step 5. If triggered, extend the `InitGraphicsAPI` loop to `for (int s = 0; s < SCREEN_COUNT; s++) SetScreenSize(s, …)`. |

## Open questions

- **OQ-1:** Should `NativeVideoWriter_Init` be invoked from `SetupRendering`
  rather than `Init`? The distinction matters only if the engine calls
  `Release(isRefresh=true)` followed by a re-`Init()` without going through
  `SetupRendering`. Reading `RetroEngine.cpp` does NOT surface such a flow;
  `SetupRendering` is called from `Init`. **Default: keep in `Init` for
  symmetry with 3sx.** Revisit if a re-init path is exercised (Phase 6 or
  beyond).

- **OQ-2:** Should we expose a `NativeVideoWriter_ClearToColor(uint16 rgb)`
  helper in the header, for the Phase 4 synthetic test-frame harness? The
  header stays cleaner without it; the Phase 4 harness can write directly
  via its own mmap. **Default: no, keep the public API minimal.** Add later
  if Phase 4 wants the convenience.

- **OQ-3:** Engine layer might set `videoSettings.pixWidth` elsewhere (e.g.
  via `SetVideoSetting(VIDEOSETTING_WINDOW_WIDTH, ...)` in response to mod
  calls) after Init completes. Does the engine re-call `InitGraphicsAPI`
  when that happens? From `RetroEngine.cpp` I could not find such a flow in
  `RunRetroEngine`'s main loop. **Assume no mid-run pixWidth change occurs
  in Phase 2.** If it ever does, the `FlipScreen` dimension guard catches
  and drops the frame.

- **OQ-4:** The 3sx reference calls `NativeVideoWriter_Shutdown()` only at
  program exit, not on every `Release(isRefresh)`. Our `Release` guards
  shutdown on `!isRefresh` — is that correct? Per `SDL2RenderDevice.cpp`,
  `isRefresh=true` is a windowed<->fullscreen transition that re-inits the
  renderer without tearing down the app. For MiSTer there's no window; the
  refresh path is a no-op. Skipping Shutdown on refresh is correct.
  **Default: gate on `!isRefresh`.**

## Exit criteria (Phase 2 done)

- [ ] `NativeVideoWriter.h` exists at the exact path with all 9 constants.
- [ ] `NativeVideoWriter.c` exists, guarded by `#if defined(__linux__) &&
      defined(PORT_MISTER)`, byte-for-byte identical to 3sx in the Linux
      branch except for the parameter changes.
- [ ] `Drawing.cpp` has exactly one added line — `#include
      "MiSTer/NativeVideoWriter.h"` — immediately above
      `#include "MiSTer/MiSTerRenderDevice.cpp"`.
- [ ] `MiSTerRenderDevice.cpp` `Init()` has `videoSettings.pixWidth = 320`
      as the FIRST statement, before `SetupRendering`, followed by
      `NativeVideoWriter_Init()`.
- [ ] `MiSTerRenderDevice.cpp` has ZERO `#include` lines (Phase 1 guardrail
      at lines 6-10 preserved): `grep -c '^#include'` returns 0.
- [ ] `MiSTerRenderDevice.cpp` `InitGraphicsAPI()` calls
      `SetScreenSize(0, 320, 240)`.
- [ ] `MiSTerRenderDevice.cpp` `FlipScreen()` calls
      `NativeVideoWriter_WriteFrame(screens[0].frameBuffer, 320, 240,
      screens[0].pitch * 2)`.
- [ ] `MiSTerRenderDevice.cpp` `Release(!isRefresh)` calls
      `NativeVideoWriter_Shutdown()`.
- [ ] `platforms/MiSTer.cmake` lists `NativeVideoWriter.c` in
      `target_sources`.
- [ ] Mac build with `-DPORT_MISTER=ON` succeeds; runtime logs
      "NativeVideoWriter_Init FAILED … no-op" and no SIGSEGV.
- [ ] armhf cross-compile succeeds; `nm` shows all 6
      `NativeVideoWriter_*` symbols in the binary.
- [ ] MiSTer deploy + `devmem2 0x3A000000 w` shows a monotonic
      frame-counter in the top bits and toggling low 2 bits.
- [ ] `devmem2 0x3A000100 w` and `devmem2 0x3A025900 w` return non-zero
      RGB565 data.
- [ ] No FPGA core loaded during the probe.
- [ ] Documentation of any deviation from this plan committed alongside the
      patch.

---

## References

- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-research.md`
  §3.2 (writer), §3.3 (frame format), §3.7 (FPGA side), §4.1 (reuse table).
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md`
  Phase 2 (lines 97-155).
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-1-plan.md`
  current landed Phase 1 (context for stubs replaced here).
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-4-plan.md`
  §0 and §6.1 (Phase 4 RTL constants — source of truth for addresses).
- `/Users/sb/Developer/3sx-mister/src/port/sdl/native_video_writer.{h,c}`
  — reference implementation.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{hpp,cpp}`
  — the Phase 1 stubs being filled in here.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp`
  — `ScreenInfo::frameBuffer`, `VideoSettings` struct layouts.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:381-414`
  — `SetScreenSize`; `pitch` is in uint16 pixels.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp:79-96,446-548`
  — CopyFrameBuffer + InitGraphicsAPI reference behaviour.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp:35,51,98,108,313,320`
  — Init / FlipScreen ordering facts.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserCore.cpp:354,497`
  — `videoSettings.pixWidth` default.

---

## Review log (Role 2 — Reviewer pass)

Re-read every source citation against the draft. Findings below.

### P-1 (must fix)

- **P-1a — Include path spelling.** Draft initially said
  `#include "NativeVideoWriter.h"` in `MiSTerRenderDevice.cpp`. Since
  `MiSTerRenderDevice.cpp` is textually pulled in by `Drawing.cpp` (which
  sits in `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/`), the `#include`
  resolves relative to `Graphics/`, so the correct spelling is
  `#include "MiSTer/NativeVideoWriter.h"`. FIXED: Step 3 §1 now specifies the
  subdirectory form and cross-references `Drawing.cpp:144-145` for how the
  `.cpp` itself is included.

- **P-1b — SetScreenSize omission.** Draft initially had no SetScreenSize
  call. Without it, `screens[0].size.x` stays 0, the rasterizer never writes
  pixels, `FlipScreen`'s dim guard always drops the frame, and the Phase 2
  exit criterion (non-zero RGB565 bytes in DDR3) cannot be met. FIXED: Step
  3 §3 adds the `SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE)`
  line inside `InitGraphicsAPI`.

- **P-1c — Pitch units.** Draft initially wrote
  `NativeVideoWriter_WriteFrame(..., 320 * 2)`. Reading SDL2's CopyFrameBuffer
  (`SDL2RenderDevice.cpp:87-91`), the advance is `frameBuffer += pitch`, and
  `SetScreenSize` computes `pitch = (size.x + 15) & 0xFFFFFFF0` in UINT16
  pixels. For `size.x=320`, pitch=320 pixels = 640 bytes, which happens to
  equal `width*2`. But if a future mod overrides pixWidth to, say, 321 (which
  the dim guard would reject anyway), the pitch would be `336 pixels = 672
  bytes`. Correct spelling is `screens[0].pitch * sizeof(uint16)`, matching
  SDL2's own row-walk. FIXED: Step 3 §4 updated to the `* sizeof(uint16)`
  form.

### P-2 (should fix / nice-to-have)

- **P-2a — Step 7 probe assumes `Data.rsdk` present.** The Phase 2 exit gate
  is "devmem2 shows changing RGB565". If the engine never rasterizes a frame
  (e.g. it fails on missing Data.rsdk early), the writer never writes. The
  user may not have the asset yet at Phase-2 time. FIXED: R-10 and the Step
  7 Prerequisites section now explicitly flag this, with a fallback to the
  Phase 4 §10.2 synthetic test-frame writer.

- **P-2b — `NativeVideoWriter_Init` failure should not abort the engine.**
  Draft's early Step 3 body had `return false` on failure. That would make
  the binary fail even in a dev iteration where /dev/mem is inaccessible.
  FIXED: the `Init` block now logs and continues (see Step 3 §2). The
  engine's main loop continues; the writer's `IsActive` returns false, and
  subsequent `WriteFrame` calls become no-ops via the ddr_base NULL check.

- **P-2c — `extern "C"` header wrapping.** 3sx doesn't use it; its header
  works because inclusion is via `.c` TUs only. For us the header is
  included from `.cpp` (MiSTerRenderDevice.cpp). Without `extern "C"`, the
  declarations would get C++ name mangling, while the `.c` emits C symbols
  — link failure. FIXED: header now has `extern "C"` guard (§ File manifest
  Step 1).

- **P-2d — `Release` gating on `isRefresh`.** Draft initially unconditionally
  called `NativeVideoWriter_Shutdown` on any `Release`. SDL2's backend
  distinguishes a full teardown from a refresh transition; running
  Shutdown on every refresh would cycle the /dev/mem mapping needlessly.
  FIXED: Step 3 §5 gates on `!isRefresh`; OQ-4 documents the reasoning.

- **P-2e — 320×240 mid-run dimension change guard missing.** Some mod paths
  can call `SetVideoSetting(WINDOW_WIDTH, …)` after Init. Without a guard,
  a changed `screens[0].size` would silently break the DDR3 write. FIXED:
  `FlipScreen` now guards on `size.x != NV_FRAME_WIDTH || size.y !=
  NV_FRAME_HEIGHT` and drops the frame rather than writing mis-dimensioned
  data (Step 3 §4).

### Findings skipped (not applicable or wrong)

- Initially considered flagging that the `.c` might duplicate symbols since
  `MiSTerRenderDevice.cpp` already uses `static` state. WRONG: the writer's
  statics live in its own TU; no collision.
- Considered flagging missing NEON-accelerated memcpy. NOT APPLICABLE:
  Mania is RGB565 native; the whole memcpy is a single 153,600-byte copy per
  frame, and the Cortex-A9's `memcpy` from glibc is already NEON-optimized
  on armhf.
- Considered adding `static_assert(NV_FRAME_BYTES == 153600)` in the `.c`.
  NOT APPLICABLE: Phase 2 must not introduce C11-specific syntax. If we
  later move to C11, add it then.

## Fix log (Role 3 — Fixer pass)

All P-1 items applied. All P-2 items applied. Final pass re-reads the plan
and confirms internal consistency:

- Parameter table values match phase-4-plan.md §0 and §6.1 (verified by
  grep into phase-4-plan.md).
- `NV_BUF1_OFFSET = 0x00025900` equals `0x100 + 0x25800` (NV_BUF0_OFFSET +
  NV_FRAME_BYTES).
- `NV_FRAME_BYTES = 153,600 = 320 × 240 × 2`.
- `NV_DDR_REGION_SIZE = 0x60000` (393,216 B) > `0x25900 + 0x25800 = 0x4B100`
  (307,456 B), slack of 85,760 B confirmed.
- Mac no-op guard is `__linux__ && PORT_MISTER`; Mac has `__APPLE__` → guard
  is false → stub branch is compiled. Verified.
- Step 3 Init writes `videoSettings.pixWidth = 320` BEFORE calling
  `SetupRendering()`; SetupRendering calls InitGraphicsAPI calls
  SetScreenSize; SetScreenSize reads `videoSettings.pixWidth` → 320. Ordering
  correct.
- Step 3 FlipScreen's `screens[0].pitch * sizeof(uint16)` matches the SDL2
  reference pattern.
- `#include "MiSTer/NativeVideoWriter.h"` in `MiSTerRenderDevice.cpp`
  resolves from Drawing.cpp's location (because that's the TU that ultimately
  pulls the textual include). Verified against the existing
  `#include "MiSTer/MiSTerRenderDevice.cpp"` at Drawing.cpp:144-145.

No further findings. Plan ready for `/implement` cycles.

## Amendments (post-review fix pass, 2026-04-24)

A second review pass on this plan flagged additional items. Original review
entries above are preserved for audit trail; amendments below supersede the
corresponding P-1a resolution and add P-2/P-3 material:

- **P-1a (SUPERSEDED).** The earlier fix placed
  `#include "NativeVideoWriter.h"` inside `MiSTerRenderDevice.cpp`. That
  violates the Phase 1 guardrail at `MiSTerRenderDevice.cpp:6-10` ("Do NOT
  add #include directives here"). New resolution: the include lives in
  `Drawing.cpp` on the line immediately above `#include
  "MiSTer/MiSTerRenderDevice.cpp"` at ~line 144. Preprocessor-equivalent
  effect, no guardrail violation. See Step 3 §1 and the new `Drawing.cpp`
  subsection in § Modified files.
- **P-1b (CLARIFIED).** `videoSettings.pixWidth = 320` must be the FIRST
  statement of `RenderDevice::Init()`, before the existing
  `if (!SetupRendering()) return false;` line. Step 3 §2 now spells out
  before/after.
- **P-1c (ADDED to Step 7).** Root / EACCES documentation: Step 7's
  Prerequisites and Failure-mode sections now explicitly state the root
  requirement (`whoami` must return `root`), EACCES diagnosis, and
  `strace -e openat ./RSDKv5U` as the fallback diagnostic.
- **P-2a (ADDED).** Risk register entry R-11: `SetScreenSize(1..3)` is
  skipped. Low-probability null-deref for Legacy GFX_* / dev-menu / mod
  paths that touch `screens[1..3]`. Documented as a flag-if-observed row.
- **P-2b (CLARIFIED).** Step 3's Init() order is now explicit: (1) pixWidth
  assignment, (2) SetupRendering (calls InitGraphicsAPI → SetScreenSize),
  (3) NativeVideoWriter_Init.
- **P-2c (ADDED).** NV_FRAME_BYTES fragility note added to the `.h` spec:
  `#define` of `NV_FRAME_WIDTH` could silently diverge `NV_FRAME_BYTES`;
  flag to switch to `static const uint32_t` + `_Static_assert` in Phase 6.
- **P-2d (ADDED).** `pitch` → `pitch_bytes` rename rationale documented in
  the `.c` spec: RSDKv5's `ScreenInfo::pitch` is uint16 pixels; the
  `_bytes` suffix prevents callers from passing the field directly without
  the `* sizeof(uint16)` multiply.
- **P-2e (DECIDED: keep + comment).** `SDL_VIDEODRIVER=dummy` in Step 7 is
  retained because it preserves the SDL2 audio/event init path that
  Phase 3 will exercise. Comment added inline explaining the rationale.
- **P-2f (ADDED).** CopyFrameBuffer left-empty explainer paragraph added
  to § Modified files under the `MiSTerRenderDevice.cpp` subsection,
  documenting the SDL2 divergence and the focus-behaviour academic
  concern.
- **P-3.1 (FIXED).** `NV_BUF0_OFFSET` comment corrected to
  "ctrl (4 B at 0x00) + feedback (8 B at 0x40-0x47) + 244 B pad" in both
  the parameter table and the `.h` spec.
- **P-3.5 (FIXED).** Step 1 success-criteria grep changed from
  `grep -c 'A\|B\|C'` (BRE literal) to `grep -cE 'A|B|C'` (ERE
  alternation).
