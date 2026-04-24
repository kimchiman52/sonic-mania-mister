# Sonic Mania on MiSTer — Port Feasibility & Architecture Research

**Document date:** 2026-04-24
**Status:** Pre-implementation research. No code written yet. All findings below are fact-based with file:line or URL citations. Items lacking direct verification are marked **UNVERIFIED**.

This document consolidates two parallel research efforts:

1. The **RSDKv5 / Sonic Mania decompilation** codebase at `github.com/RSDKModding/*` — what it is, how rendering works, and what a MiSTer backend must implement.
2. The **3sx-mister hybrid FPGA approach** at `/Users/sb/Developer/3sx-mister` — the architecture we built for the Street Fighter III: 3rd Strike port, and which pieces are directly reusable for Mania.

The goal is a single reference that future work on this project can build from without re-discovering the landscape.

---

## 1. Target hardware recap

MiSTer FPGA's HPS (Hard Processor System) inside the Cyclone V SoC (`5CSEBA6U23I7`):

- **CPU:** ARM Cortex-A9 dual-core @ 800 MHz nominal (overclockable to 1.0–1.2 GHz in config). **NOT A7** — earlier drafts of this research misidentified the core.
- **ISA:** ARMv7-A, hard-float EABI (`armhf` / `arm-linux-gnueabihf`). NEON + VFPv3.
- **RAM:** 1 GB DDR3 shared between HPS and FPGA fabric.
- **GPU:** **None.** No Mali, no VideoCore, no GLES driver. The Cyclone V HPS has no graphics accelerator of any kind.
- **OS:** Linux 5.15 (MiSTer fork of Linaro / mainline armhf), glibc, SDL2 available.
- **Video output:** Driven by the FPGA fabric, not by Linux. The fabric generates analog VGA/YPbPr/S-Video and digital HDMI timings directly. Linux sees a framebuffer device (`/dev/fb0`) that the fabric *optionally* reads, but the fabric can also read any DDR3 address we write to — which is the basis of the hybrid approach.
- **Audio:** ALSA. SDL2 audio works.
- **Input:** USB (keyboards, gamepads), with MiSTer's wrapper menu exposing joystick state via a shared-memory region.

The key consequence for a Sonic Mania port: **we cannot rely on OpenGL, GLES, or Vulkan.** Any existing RSDKv5 backend that requires a GPU is unusable. Our only paths are (a) software rasterization into a CPU buffer and (b) handing that buffer to the FPGA for scanout.

---

## 2. RSDKv5 / Sonic Mania architecture

### 2.1 Repo layout

Primary build root is the **game** repo, which pulls the **engine** as a git submodule:

```
~/Developer/sonic-mania-mister/                (game repo)
├── CMakeLists.txt                             # drives the whole build
├── SonicMania/                                # pure C game logic (~9 MB, ~200 objects)
│   ├── Game.c
│   └── Objects/                               # per-object .c files
├── dependencies/
│   └── RSDKv5/                                # engine submodule, pinned to v1.1.1 (bd59396)
│       ├── CMakeLists.txt
│       ├── platforms/                         # per-platform CMake files
│       │   ├── Linux.cmake
│       │   ├── Windows.cmake
│       │   ├── Android.cmake
│       │   ├── NintendoSwitch.cmake
│       │   └── ...
│       ├── RSDKv5/
│       │   ├── main.cpp
│       │   └── RSDK/
│       │       ├── Core/                      # RetroEngine.cpp, Math.cpp, ModAPI.cpp, ...
│       │       ├── Graphics/                  # <-- BACKEND SEAM IS HERE
│       │       │   ├── Drawing.{cpp,hpp}      # 4456 + 427 LOC — software rasterizer + public API
│       │       │   ├── Palette.{cpp,hpp}      # CPU palette
│       │       │   ├── Sprite.{cpp,hpp}       # sprite sheet loader
│       │       │   ├── Scene3D.{cpp,hpp}      # CPU 3D projection
│       │       │   ├── Video.{cpp,hpp}        # libtheora demux/decode
│       │       │   ├── DX9/     DX11/         # per-backend RenderDevice implementations
│       │       │   ├── GLFW/    EGL/          #
│       │       │   ├── SDL2/    Vulkan/       #
│       │       │   └── Legacy/                # RSDKv3/v4 compat
│       │       ├── Audio/    Input/
│       │       ├── Scene/    Storage/
│       │       ├── Dev/      User/Core/
│       └── dependencies/all/
│           ├── stb_vorbis/                    # submodule
│           ├── tinyxml2/                      # submodule
│           ├── iniparser/                     # vendored
│           └── miniz/                         # vendored
```

Upstream repos:
- Engine: [github.com/RSDKModding/RSDKv5-Decompilation](https://github.com/RSDKModding/RSDKv5-Decompilation) — master `04f63b6` (2026-03-04), license is custom non-commercial.
- Game: [github.com/RSDKModding/Sonic-Mania-Decompilation](https://github.com/RSDKModding/Sonic-Mania-Decompilation) — master `ca19403c` (2026-03-12). Requires the user's own `Data.rsdk` (same posture as 3sx requiring CPS3 ROMs).

### 2.2 The critical architectural fact: RSDKv5 is a CPU software rasterizer

This is the single most important finding for feasibility. The earlier worry about "we need a GL3 backend, but MiSTer has no GPU" is **wrong in premise** — RSDKv5's backends are *presenters*, not *renderers*.

Evidence:
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:76-88` declares `ScreenInfo` with a `uint16 frameBuffer[...]` member. RGB565 16-bit, 5:6:5 layout.
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:586-612` implements `FillScreen`, which iterates over `currentScreen->frameBuffer` writing `uint16` pixels directly. This pattern continues throughout `Drawing.cpp` for every primitive: `DrawRectangle`, `DrawLine`, `DrawCircle`, `DrawSprite*`, `DrawTile`, `DrawFace`, `DrawBlendedFace`, `DrawDeformedSprite`.
- The **backend's** contract is to accept that finished `uint16` buffer and present it (upscale, filter, blit to window/GPU/scanout). It does not rasterize primitives itself.

This means: a MiSTer "backend" does not need to implement a GL3 equivalent. It needs to (1) take the finished RGB565 buffer, (2) optionally upscale, (3) hand it to the FPGA for display.

### 2.3 Public draw API (game layer talks to engine)

Declared in `Drawing.hpp:286-410`. Every one of these is implemented on the CPU in `Drawing.cpp`:

| Function | Purpose |
|---|---|
| `UpdateGameWindow` | present current frame |
| `FillScreen(color, aR, aG, aB)` | clear with optional alpha |
| `DrawLine`, `DrawRectangle`, `DrawCircle`, `DrawCircleOutline` | 2D primitives |
| `DrawFace(verts, n, r, g, b, a, ink)` | flat-color polygon |
| `DrawBlendedFace(verts, colors, n, a, ink)` | per-vertex color polygon (gouraud) |
| `DrawSprite`, `DrawSpriteFlipped`, `DrawSpriteRotozoom` | sprite draws |
| `DrawDeformedSprite(sheetID, ink, alpha)` | HSCROLL tile effects (water, heat-haze) |
| `DrawTile`, `DrawAniTile`, `DrawDynamicAniTile` | tile layer rendering |
| `DrawString(anim, pos, str, ...)` | font-sprite text |
| `DrawDevString(str, x, y, align, color)` | 8×8 debug font |
| `SwapDrawListEntries`, `AddCamera`, `ClearCameras`, `SetClipBounds` | scene/list management |
| `Get/SetVideoSetting`, `GetDisplayInfo`, `GetWindowSize` | host queries |

**Ink effects** (`Drawing.hpp:29-38`): `INK_NONE, INK_BLEND, INK_ALPHA, INK_ADD, INK_SUB, INK_TINT, INK_MASKED, INK_UNMASKED`. All resolved in software via a precomputed `blendLookupTable[0x20*0x100]` populated in `Drawing.cpp:257-279`.

### 2.4 The backend seam

`Drawing.hpp:245-257` uses **static `#ifdef` dispatch**, not polymorphism or function pointers:

```cpp
#if RETRO_RENDERDEVICE_DX9
#include "DX9/DX9RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_DX11
#include "DX11/DX11RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_SDL2
#include "SDL2/SDL2RenderDevice.hpp"
#elif RETRO_RENDERDEVICE_GLFW
#include "GLFW/GLFWRenderDevice.hpp"
#elif RETRO_RENDERDEVICE_EGL
#include "EGL/EGLRenderDevice.hpp"
#elif RETRO_RENDERDEVICE_VK
#include "Vulkan/VulkanRenderDevice.hpp"
#endif
```

Only one backend is compiled per binary. Adding a MiSTer backend means:
1. Creating `RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}`.
2. Adding `#elif RETRO_RENDERDEVICE_MISTER` branch to the header above and to the matching `.cpp` include chain at `Drawing.cpp:133-146`.
3. Creating `dependencies/RSDKv5/platforms/MiSTer.cmake` that sets the defines and picks our sources.
4. Implementing the `RenderDevice` class interface (a known set of methods — see §2.6).

### 2.5 Existing backend sizes (reference)

| Backend | `.cpp` LOC | `.hpp` LOC |
|---|---|---|
| DX9 | 1762 | 125 |
| DX11 | 2216 | 157 |
| SDL2 | 1128 | 81 |
| GLFW | 1333 | 88 |
| EGL (Android) | 1181 | 87 |
| Vulkan | 2472 | 218 |

The SDL2 backend is the smallest and closest shape to what we need — but it still requests `SDL_RENDERER_ACCELERATED` at `SDL2RenderDevice.cpp:596`, which will **fail on MiSTer HPS** (no SDL render driver available). A MiSTer backend either bypasses SDL_Renderer entirely or changes that flag to `SDL_RENDERER_SOFTWARE`.

### 2.6 Minimum MiSTer backend surface

From the SDL2 reference backend, the methods we must implement (verified against `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp`):

| Function | SDL2 LOC | MiSTer-version LOC | Notes |
|---|---|---|---|
| `Init` | ~58 | ~50 | Open `/dev/mem`, mmap DDR3 region, init input thread |
| `SetupRendering` | ~24 | ~20 | |
| `InitGraphicsAPI` | ~105 | ~30 | No texture/shader creation needed |
| `CopyFrameBuffer` | ~17 | ~30 | Optional RGB565 upscale to scanout dims |
| `FlipScreen` | ~200 | ~20 | Single-screen; skip vertex buffer logic |
| `RefreshWindow` | ~52 | ~10 | No window resize on embedded target |
| `Release` | ~34 | ~15 | munmap + close |
| `GetWindowSize` | ~19 | ~5 | Return fixed dims |
| `GetDisplays` | ~55 | ~10 | Stub: return single "display" |
| `InitFPSCap/CheckFPSCap/UpdateFPSCap` | ~14 | reuse | Portable `clock_gettime` |
| `LoadShader` | 1 | 1 (stub) | Already a no-op in SDL2 |
| `InitShaders` | ~40 | 5 (stub) | Log + return true |
| `ProcessEvents`/`ProcessEvent` | ~345 | reuse from SDL2 | Keep SDL2 for input |
| `SetupImageTexture` | ~30 | ~20 | LoadImage path (title cards) |
| `SetupVideoTexture_YUV{420,422,444}` | ~45 total | ~80 | **Rewrite: CPU YUV→RGB565** |
| `InitVertexBuffer` | ~38 | drop (0) | Only needed for multi-screen splitscreen; Mania is single-screen |

**Estimated total: 250–350 LOC** for a MiSTer backend, vs 1128 for SDL2 and 2638 for the Dreamcast KallistiOS rewrite (which is a full GPU bypass, not a software presenter).

### 2.7 Shader inventory — what they do and which matter

Shader files live in `dependencies/RSDKv5/Shaders/{OGL,DX9,DX11,Vulkan}/`. Per backend, 7–9 files. Enum at `Drawing.hpp:56-65`.

| Shader | Purpose | Gameplay-critical? |
|---|---|---|
| `SHADER_NONE` | identity pass | N |
| `SHADER_CLEAN` | bilinear / sharp-bilinear integer upscale | cosmetic |
| `SHADER_CRT_YEETRON` | CRT curvature + scanlines + phosphor | cosmetic |
| `SHADER_CRT_YEE64` | alternative CRT look | cosmetic |
| `SHADER_RGB_IMAGE` | RGBA8888 passthrough (LoadImage, title cards, decoded video frames) | **presentation-required** (CPU replacement trivial) |
| `SHADER_YUV_420` / `422` / `444` | YUV planar → RGB for libtheora playback | **video-required** (CPU replacement needed; see §2.9) |

**Gameplay-critical shaders: zero.** Palette effects and color-math are all CPU-side in `Palette.cpp`. Our MiSTer backend stubs all shader load/use to no-ops; the only functional replacement needed is the YUV conversion, and only if we support cutscene playback.

### 2.8 Palette is CPU-side

`Palette.cpp:9-20` defines three `uint16[]` RGB565 tables: `fullPalette[PALETTE_BANK_COUNT][PALETTE_BANK_SIZE]`, `stagePalette[]`, `globalPalette[]`. `LoadPalette` (`Palette.cpp:30-54`) converts loaded RGB888 to RGB565 at load. `BlendColors` / `SetPaletteFade` (`Palette.cpp:56-104`) do CPU blending.

Sprite pixels are 8-bit indexed in `gfxSurface[].pixels`. The `palette[index] → uint16 RGB565` indirection happens inside the software `DrawSprite*` rasterizers in `Drawing.cpp`, writing RGB565 directly into `ScreenInfo.frameBuffer`. There is **no shader-based palette path**.

Consequence: palette rotation, fade-outs, water-line palette effects, level-transition fades — all work on our software backend with zero added code.

### 2.9 Scene3D is CPU-side and has no textured 3D

`Scene3D.hpp:14-31` enumerates the only supported 3D draw modes:

- `S3D_WIREFRAME`
- `S3D_SOLIDCOLOR`
- `S3D_WIREFRAME_SHADED`
- `S3D_SOLIDCOLOR_SHADED`
- `S3D_SOLIDCOLOR_SHADED_BLENDED`
- plus `_SCREEN` variants of each

**No `TEXTURED` mode exists.** `Scene3D.cpp:826` (`Draw3DScene`) projects vertices on CPU using fixed-point `MatrixMultiply` / `MatrixRotateXYZ`, then dispatches to `DrawLine` (wireframe) or `DrawFace` / `DrawBlendedFace` (solid-color polygon). Lighting (diffuse + specular) is computed on CPU at `Scene3D.cpp:944-1004` and baked into a per-face RGB color. Painter's algorithm back-to-front sort via `scn->faceBuffer` — no depth buffer.

Consequence: Blue Sphere bonus stages, Mean Bean Machine, Mirage Saloon pinball-ish bits — all Just Work on a 2D software backend, because they rasterize through `DrawFace` / `DrawLine` / `DrawBlendedFace`, which already write to the RGB565 frameBuffer.

### 2.10 Video playback (libtheora) is the one shader-touched path

`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Video.cpp:1-286`. Uses `libtheora` + `libogg`. The decode loop `ProcessVideo()` at `Video.cpp:196-286` calls `th_decode_ycbcr_out` to obtain raw YUV planes, then hands them to `RenderDevice::SetupVideoTexture_YUV{420,422,444}` (`Video.cpp:240-258`). The SDL2 backend implements these by creating an `SDL_PIXELFORMAT_YV12` texture and letting the GPU do YCbCr→RGB (`SDL2RenderDevice.cpp:1081-1128`).

During playback, `Video.cpp:167-172` sets `videoSettings.shaderID = SHADER_YUV_*`.

For our MiSTer backend: write a CPU YUV→RGB565 conversion. Mania's cutscenes are short intro / attract-mode videos; performance budget is forgiving. Approximate cost for 424×240 YUV→RGB565: **~100 kB / frame at 60 FPS = 6 MB/s memory write, well within ARM/DDR3 bandwidth.**

Alternatively: stub `LoadVideo`/`ProcessVideo` entirely (cutscenes skip). This is precedent — per `github.com/RSDKModding/RSDKv5-Decompilation` issue #167, user `ccajas1` reports doing exactly that to dodge libogg/libtheora linker issues on Raspberry Pi.

### 2.11 Resolution model

- Default: `videoSettings.pixWidth = DEFAULT_PIXWIDTH = 424` (`Drawing.hpp:18`).
- Height is hard-locked: `SCREEN_YSIZE = 240` (`RetroEngine.hpp:154-155`).
- Max width: `SCREEN_XMAX = 1280` (`RetroEngine.hpp:150-151`).
- Mania runs **pixWidth × 240**, rendered natively by the engine into `ScreenInfo.frameBuffer`. The backend upscales.
- In SDL2, this is done via `SDL_RenderSetLogicalSize(renderer, videoSettings.pixWidth, SCREEN_YSIZE)` at `SDL2RenderDevice.cpp:512`.

Widescreen Mania = 424×240. 4:3 crop = 320×240 or 352×240 (per the Miyoo Mini Plus port pages; not source-verified).

**Height is 240, not 224.** 3sx on MiSTer runs 384×**224** (CPS3 native). This matters for the FPGA pixel reader — see §4.

### 2.12 Toolchain requirements

From `dependencies/RSDKv5/CMakeLists.txt:71-75`:

> "…which relies on C++17. Otherwise the engine is mostly C++11."

- **C++17** when `RETRO_MOD_LOADER=ON` (default). Required for `<filesystem>`.
- **C++11** if we disable the mod loader.
- **Exceptions used** in `RSDK/Core/ModAPI.cpp` (try-blocks at lines 377, 554, 878, 1111, 1169, 1197, 1241). `-fno-exceptions` would break mod loading.
- **RTTI:** no `dynamic_cast<>` found by grep; `-fno-rtti` *may* be viable. **UNVERIFIED — needs full grep.**
- **STL:** heavy. `std::string`, `std::vector`, `std::map`, `<filesystem>`. Full libstdc++ required.
- **Inline asm:** **UNVERIFIED.** Engine builds on ARM32/ARM64/x86/x64 so unlikely to have hard deps.

Mod loader can be disabled via `-DRETRO_MOD_LOADER=OFF` if we want to drop the C++17 requirement, but we probably want it — player scene-loading overrides rely on it.

### 2.13 Existing non-x86 ports (precedent)

- **Nintendo Switch (aarch64):** first-class target in-tree. `platforms/NintendoSwitch.cmake` exists. RetroEngine.hpp has `RETRO_SWITCH` define at lines 34, 87, 139-140, 367, 479, 510. No dedicated `Graphics/Switch/` — uses one of the existing backends. **UNVERIFIED which.**
- **Raspberry Pi (armhf):** engine issue #167 ([github.com/RSDKModding/RSDKv5-Decompilation/issues/167](https://github.com/RSDKModding/RSDKv5-Decompilation/issues/167)). Open since 2022-12-27. Users report successful SDL2-backend builds on Pi 3 / 4 / Zero 2W under Bullseye/Bookworm. Known snag: libogg linker errors requiring local rebuild of libogg/libtheora, OR stubbing video playback. **No mention of GL3-vs-GLES gap** — SDL2 backend uses whatever SDL2 renderer driver the Pi provides (typically GLES via KMS/dispmanx).
- **Miyoo Mini Plus (Cortex-A7 armhf, 1.2 GHz, Mali-400 GLES2):** binary-only PortMaster port by snowolf_. Source not public. Device has a real GPU, so this is **not a useful software-rendering precedent** — the port certainly uses SDL2 over GLES via Mali.
- **Dreamcast (KallistiOS, PowerVR):** fork `github.com/michael-fadely/RSDKv5-Decompilation` branch `sf94/dreamcast-kallistios-pvr`, commit `476d112`. Rewrites the backend as `Graphics/KallistiOS/KallistiOSRenderDevice.{cpp,hpp}` (2638 + 195 LOC), heavily patches `Drawing.cpp` with `#if RETRO_PLATFORM == RETRO_KALLISTIOS && defined(KOS_HARDWARE_RENDERER)` guards at lines 666-872, 1232-1289, 1472, 1577, 1949, 2177-2583, 3057-3184. **This is not a software reference** — it bypasses Drawing.cpp's CPU rasterizer and pushes native PVR quads.
- **PSP Vita:** `github.com/SonicMastr/Sonic-Mania-Vita` exists. Backend choice **UNVERIFIED** (likely GXM custom or vitaGL).
- **PortMaster recipe:** [github.com/PortsMaster/PortMaster-New/blob/main/ports/sonic.mania/sonicmania/BUILDING.md](https://github.com/PortsMaster/PortMaster-New/blob/main/ports/sonic.mania/sonicmania/BUILDING.md) builds unmodified upstream with `-DRETRO_SUBSYSTEM=SDL2` plus apt-installed `libglew-dev libglfw3-dev libtheora-dev libdrm-dev libgbm-dev`. Targets devices with GPUs (Mali/VC4/Adreno). **No MiSTer patches anywhere.**
- **No software / fbdev / KMS / DRM backend has ever been written upstream.** `grep -rn "fbdev\|kmsdrm\|software"` in `dependencies/RSDKv5/RSDKv5/` returns zero matches (outside `RETRO_SWITCH` noise). We are first.

---

## 3. The 3sx-mister hybrid FPGA approach

This is the architecture we built in `/Users/sb/Developer/3sx-mister` for Street Fighter III: 3rd Strike. The sections below cite exact file:line references from that project.

### 3.1 High-level architecture

```
┌──────────────────────────────┐
│  Game code (CPS3 decomp, C)  │   384×224 ARGB8888
│  renders into cps3_canvas    │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  NEON ARGB8888→RGB565        │   convert_argb8888_to_rgb565()
│  conversion (sdl_app.c:186)  │   into aligned scratch buffer
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  NativeVideoWriter_WriteFrame│   /dev/mem mmap @ 0x3A000000
│  native_video_writer.c:76    │   double-buffered, O_SYNC uncached
└──────────────┬───────────────┘
               │ DDR3
               ▼
┌──────────────────────────────┐
│  FPGA fabric (Verilog)       │   384×224 native timing
│  pixel reader → line FIFO    │   direct VGA DAC / YC encoder / HDMI
│  → video timing generator    │
└──────────────────────────────┘
```

The Linux framebuffer (`/dev/fb0`) is **not in the hot path.** It exists as fallback for platforms that aren't MiSTer, and as a safety net in case the native path fails to init.

### 3.2 Native video writer

The core of the hybrid approach is a small userland module that mmaps a fixed DDR3 region and writes RGB565 frames into a double buffer. The FPGA pixel reader polls the control word and scans out whichever buffer is marked active.

**Files:**
- `src/port/sdl/native_video_writer.h` (41 lines) — public API
- `src/port/sdl/native_video_writer.c` (153 lines) — implementation, guarded by `#if defined(PORT_MISTER)`

**Public API:**

| Function | Signature |
|---|---|
| `NativeVideoWriter_Init` | `bool NativeVideoWriter_Init(void)` |
| `NativeVideoWriter_Shutdown` | `void NativeVideoWriter_Shutdown(void)` |
| `NativeVideoWriter_WriteFrame` | `void NativeVideoWriter_WriteFrame(const void* pixels_rgb565, int width, int height, int pitch)` |
| `NativeVideoWriter_IsActive` | `bool NativeVideoWriter_IsActive(void)` |
| `NativeVideoWriter_ReadFeedback` | `uint32_t NativeVideoWriter_ReadFeedback(void)` |
| `NativeVideoWriter_ReadFeedbackSeq` | `uint32_t NativeVideoWriter_ReadFeedbackSeq(void)` |

**DDR3 memory map** (`native_video_writer.c:11-19`):

| Symbol | Value | Meaning |
|---|---|---|
| `NV_DDR_PHYS_BASE` | `0x3A000000` | Physical DDR3 base |
| `NV_DDR_REGION_SIZE` | `0x00060000` (384 KB) | Covers both buffers + control/feedback |
| `NV_CTRL_OFFSET` | `0x00000000` | Control word: `[1:0]=active_buf`, `[31:2]=frame_counter` |
| `NV_FEEDBACK_OFFSET` | `0x00000040` | FPGA→ARM feedback: `[31:8]=ARM timestamp μs`, `[7:0]=FPGA frame counter` |
| `NV_BUF0_OFFSET` | `0x00000100` (256) | Buffer 0 start |
| `NV_BUF1_OFFSET` | `0x0002A200` (172,546) | Buffer 1 start |
| `NV_FRAME_WIDTH` / `NV_FRAME_HEIGHT` | `384` / `224` | CPS3 native — **Mania is 424×240, so this is different** |
| `NV_FRAME_BYTES` | `172,032` (384×224×2) | RGB565 frame size |

**Mmap path (`native_video_writer.c:27-40`):**

```c
int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);    // uncached
ddr_base = (volatile uint8_t*)mmap(NULL, NV_DDR_REGION_SIZE,
    PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, NV_DDR_PHYS_BASE);
```

`O_SYNC` forces write-through; no flush barriers needed in userland. `MAP_SHARED` so the FPGA also sees the writes.

**Write frame (`native_video_writer.c:76-107`):**
1. Select inactive buffer (the one the FPGA is *not* currently scanning).
2. `memcpy` RGB565 pixels into it (row-by-row if `pitch != width*2`, else contiguous).
3. Update control word: `(frame_counter << 2) | (active_buf & 1)`.
4. Toggle `active_buf` for next frame.

No ioctl, no kernel module. Pure userspace `/dev/mem` + mmap with a fixed physical address contract negotiated with the FPGA core.

### 3.3 Frame-format conversion

The CPS3 renderer produces ARGB8888; FPGA scanout consumes RGB565. The conversion is NEON-accelerated:

**File:** `src/port/sdl/sdl_app.c`

**Scratch buffer (line 184):**
```c
static uint16_t __attribute__((aligned(16))) native_video_rgb565_scratch[384 * 224];
```

**Converter (line 186):** `static void convert_argb8888_to_rgb565(const uint32_t* src, uint16_t* dst, int pixel_count)`
- NEON path processes 8 pixels per iteration: `vld4_u8` to deinterleave R/G/B/A, shift+mask to pack 5/6/5, `vst2_u16` to store. Lines 187-220.
- Scalar fallback for tail pixels and non-NEON targets.

**For Mania:** the engine already outputs RGB565 natively (§2.2). **No conversion is needed** — we can skip this entire step. That's a ~200-LOC simplification vs 3sx.

### 3.4 Platform gating — `PORT_MISTER`

One CMake option fans out into every platform-specific branch.

**CMakeLists.txt:13:**
```cmake
option(PORT_MISTER "Enable MiSTer-oriented build profile" OFF)
```

**MiSTer-on defaults (`CMakeLists.txt:22-28` and `src/port/config/config.c:30-44`):**
- `ENABLE_NETPLAY` → OFF (Mania has no rollback anyway; no change needed)
- `ENABLE_ISO_IMPORT` → OFF (Mania doesn't use this)
- `ENABLE_FFMPEG_ADX` → OFF (Mania uses libtheora; separate concern)
- `ENABLE_SDL_DIALOGS` → OFF
- `ENABLE_MISTER_ARM_HARDENING` → ON (conservative armhf + NEON compile flags)
- SDL video driver → `dummy` (no window)
- SDL renderer → `software`
- window size → 320×240 (placeholder since we render native)
- `software-frame-mode` → `on` (ARM-owned frame buffer, prerequisite for native path)

**Gated integration points in `sdl_app.c`:**

| Line(s) | Condition | Behavior |
|---|---|---|
| 38-48 | `#if defined(PORT_MISTER)` | POSIX/NEON headers (`unistd.h`, `fcntl.h`, `sys/mman.h`, `time.h`) |
| 144-149 | `#if defined(PORT_MISTER)` | Vsync feedback state vars |
| 9838-9860 | `#if defined(PORT_MISTER)` | `FBDevPresenter_Init()` + `NativeVideoWriter_Init()` at startup |
| 10000 | MiSTer | `NativeVideoWriter_Shutdown()` at exit |
| 10520-10544 | frame loop | RGB565 conversion + `NativeVideoWriter_WriteFrame()` |
| 10673-10716 | frame loop | Read vsync feedback, update pacer |

### 3.5 Input layer

Input remains on SDL2 (gamepad/keyboard via `SDL_GameController*` and `SDL_Event`). MiSTer adds one extra source: a shared-memory region written by the MiSTer wrapper for menu-driven input.

**SHM:**
- Path: `/dev/shm/thirdsarm-joy`
- Magic: `0x33534152` ("3SAR")
- Layout: `vendor/Main_MiSTer/mister_joy_shm.h` — `joy_mask[2]`, analog stick axes, 2-player support.

**Input consumer:** `src/port/sdl/sdl_pad.c` — `SDLPAD_INPUT_MISTER_SHM` enum case added alongside `SDLPAD_INPUT_GAMEPAD` and `SDLPAD_INPUT_KEYBOARD`.

For Mania this is mostly irrelevant at first — we'll use SDL2 gamepad/keyboard only. The wrapper SHM matters only if we integrate with MiSTer's menu / OSD in a later phase.

### 3.6 Frame pacing

**Non-MiSTer:** timer-based. `sdl_app.c:132-156` — `Uint64 target_frame_time_ns = (Uint64)(1e9 / 59.59949)`, `SDL_DelayNS` until deadline, advance deadline. Jitter ±1–4 ms.

**MiSTer:** closed-loop via the DDR3 feedback word.

- FPGA writes `{timestamp_us[23:0], frame_counter[7:0]}` to `DDR3[0x40]` at each vblank, with a separate sequence number at `DDR3[0x44]` to detect torn reads.
- ARM reads seq, feedback, seq again (`sdl_app.c:9534-9580`). If seq matches, apply the update.
- Phase error between ARM's expected vblank time and FPGA's reported vblank time feeds back into the pacer, eliminating timer jitter.
- State: `last_fpga_frame_cnt`, `last_feedback_seq`, `last_feedback_update_ns`, `pacer_phase_error_ns` — visible in the perf overlay.

### 3.7 FPGA side

**UNVERIFIED as currently shipped — spec exists, RTL not in this tree.** The spec at `docs/spec-fpga-native-video.md` (1716 lines) describes:

1. **DDR3 Pixel Reader** (~150 LOC Verilog) — Avalon-MM master, bursts 768-byte scanlines (384×2), polls control word for frame flips.
2. **Line FIFO** (~80 LOC) — dual-clock dcfifo bridging DDR3 clock to pixel clock.
3. **Video Timing Generator** (~80 LOC) — fixed modeline 384×224 @ 59.5995 Hz, outputs H/V sync, blank, DE.
4. **Fractional-N PLL** — M=15, N=1, C=93 → 8.0645 MHz (0.087% error); or precise fractional M=16, K=0x1D707ED5, N=1, C=100.

**For Mania, the FPGA side must change:** 424×240 (or 320×240) instead of 384×224, 60 Hz timing instead of CPS3's native rate. This means a new or parameterized version of the pixel reader + VTG + PLL. Same architectural shape, different modeline math.

### 3.8 VGA scaler bypass

MiSTer users must set `vga_scaler=0` in their core's `.ini` section. Without this, the FPGA routes HDMI scaler output to the VGA DAC, bypassing our native path and giving grayscale S-Video on CRT.

Documentation: `docs/mister-wrapper.md:44-53`, `docs/reference-native-analog-video.md:582-584`. FPGA logic (sys_top.v):
```
vgas_en = vga_fb | vga_scaler
assign VGA_R = vga_fb_yc_en ? yc_fb_o : vgas_en ? vgas_o : vga_o
```

Required `.ini` section for our Mania core:
```ini
[Mania]             ; or whatever the core name ends up
main=MiSTer_Mania
vga_scaler=0
```

### 3.9 Build system

- **Target triple:** `arm-linux-gnueabihf` (ARMv7-A, hard-float).
- **Compiler:** `clang-20` (GCC 10.x fails on upstream unnamed-parameter defs in 3sx).
- **CMake:** ≥3.24.
- **Cross-compile env** (`docs/mister-runbook.md:145-175`):
  ```bash
  export CC=clang-20 CXX=clang++-20
  export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
  export CFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr"
  cmake -S . -B build/mister -DCMAKE_BUILD_TYPE=Release -DPORT_MISTER=ON
  ```
- **Flavors:** `telemetry` (dev, keeps perf capture) vs `clean` (player). Driven by `ENABLE_PERF_TELEMETRY`.
- **Docker wrapper:** `tools/mister/build-game.sh --flavor telemetry` is the canonical command.

---

## 4. Applying the hybrid approach to Sonic Mania

This section maps each 3sx component to what it would become for Mania.

### 4.1 What's directly reusable

| 3sx component | Reuse status for Mania |
|---|---|
| `native_video_writer.{h,c}` core API | Direct copy. Change `NV_FRAME_WIDTH`/`HEIGHT` to 424/240 (widescreen) or 320/240 (4:3). Change `NV_FRAME_BYTES` accordingly. Constants only, no logic change. |
| DDR3 control/feedback protocol | Identical. Same double-buffer flip, same control word layout, same feedback word layout. |
| `/dev/mem` + `O_SYNC` mmap | Identical. |
| Vsync feedback loop | Identical. Read feedback, compute phase error, adjust pacer. |
| SDL2 input path | Identical. Mania already supports SDL2 input natively. |
| SDL2 audio path | Identical. Mania's SDL2 audio support is upstream (`RETRO_AUDIODEVICE_SDL2`). |
| `PORT_MISTER` CMake gate pattern | Identical pattern, applied to RSDKv5's `platforms/MiSTer.cmake`. |
| Cross-compile env | Identical (clang-20, armhf). |
| Docker build wrapper | Adaptable; same dependencies minus 3sx-specific bits. |

### 4.2 What's different from 3sx

| Area | 3sx | Mania | Impact |
|---|---|---|---|
| Engine source format | One monolithic C decomp of CPS3 arcade code | Split engine (C++) + game (C) under one build | Build driver is game repo's `CMakeLists.txt`, which pulls engine via `add_subdirectory`. Clean. |
| Pixel format | ARGB8888 (needs NEON conversion to RGB565) | RGB565 native — no conversion needed | Simplification. Drop `convert_argb8888_to_rgb565`. |
| Native resolution | 384×224 | 424×240 (widescreen) / 320×240 (4:3) | Change FPGA VTG + PLL. Same pattern, different modeline. |
| Frame rate | CPS3 native (~59.6 Hz) | 60 Hz nominal | PLL math changes. |
| Rendering abstraction | Scattered `AcrSDK` calls inside the CPS3 code | Single `RenderDevice` class under `#ifdef` dispatch in one header | Cleaner to retarget — add one backend class, no need to hunt through the codebase. |
| Netplay | Gekko rollback integrated | N/A — Mania has no rollback hooks | Less code to deal with. |
| Video/cutscenes | N/A in CPS3 | libtheora YUV → shader in upstream | New work: CPU YUV→RGB565 conversion (~80 LOC) OR stub cutscenes entirely |
| Shader support | N/A | 7 shader files per backend; all optional | Stub them all. |
| Dependencies | SDL2, minimal | SDL2 + libtheora + libogg + (optional) libglew, libglfw, miniz, tinyxml2, iniparser, stb_vorbis | More deps. libogg/libtheora have known armhf build pain per issue #167. |
| `RetroEngine.hpp` platform define | N/A — 3sx has no equivalent | Must add `RETRO_MISTER` alongside `RETRO_LINUX`/`RETRO_SWITCH`/etc. | Small header change. |
| Mod loader | N/A | Upstream default ON, requires C++17 + `<filesystem>` | Optional. Leave ON unless C++17 is a problem. |
| Language | C | C++ (engine) + C (game) | libstdc++ required. Small binary-size impact. |
| Assets | CPS3 ROMs | `Data.rsdk` blob from retail Mania | Same user-supplied-asset posture. |

### 4.3 Concrete file manifest for the MiSTer backend

New files (to be created under `dependencies/RSDKv5/`):

```
dependencies/RSDKv5/platforms/MiSTer.cmake                    # NEW — platform file
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/               # NEW — backend dir
    MiSTerRenderDevice.hpp                                     # ~60 LOC
    MiSTerRenderDevice.cpp                                     # ~300 LOC
    NativeVideoWriter.{h,c}                                    # copy+adapt from 3sx
```

Modifications to existing upstream files (minimal, guarded by `#ifdef RETRO_RENDERDEVICE_MISTER`):

```
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp          # add #elif branch at lines 245-257
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp          # add #elif branch at lines 133-146
dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp          # add RETRO_MISTER define + platform ID
dependencies/RSDKv5/CMakeLists.txt                            # add PORT_MISTER option passthrough (optional)
CMakeLists.txt (game, at repo root)                           # add PORT_MISTER cache var passthrough
```

All upstream modifications should be minimal and merge-clean. The goal is that we can `git pull` upstream updates without pain.

### 4.4 Rendering data flow (Mania on MiSTer)

```
┌─────────────────────────────────────┐
│  SonicMania/Objects/*.c             │   game logic
│  call Drawing.hpp public API        │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Drawing.cpp software rasterizer    │   writes RGB565 pixels directly
│  palette lookup, ink effects, all   │   into ScreenInfo.frameBuffer
│  on CPU in one big loop nest        │   (uint16[pixWidth * 240])
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  MiSTerRenderDevice::CopyFrameBuffer│   no color conversion needed
│  CopyFrameBuffer → NativeVideoWriter│   may upscale if scanout dims differ
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  /dev/mem @ 0x3A000000              │   double-buffered, O_SYNC
└──────────────┬──────────────────────┘
               │ DDR3
               ▼
┌─────────────────────────────────────┐
│  FPGA pixel reader + VTG + PLL      │   424×240 @ 60 Hz (or 320×240)
│  → VGA DAC / YC encoder / HDMI      │   via core's video modules
└─────────────────────────────────────┘
```

The "hot" write path is just: rasterize into RGB565 (engine does this), memcpy to DDR3, toggle control word. Maybe an upscale blit step if we want to output at higher scanout dimensions.

### 4.5 Open design decisions

These need answers before writing code. They're not blockers; each has a reasonable default.

1. **Scanout dimensions.** 424×240 widescreen (Mania's default) vs 320×240 4:3 (arcade-style crop). Do we ship one, both (selectable), or upscale to a CRT-friendly integer-multiple mode?
2. **Native FPGA modeline.** What PLL + VTG settings? 60 Hz is the engine target; matching the FPGA side to Mania's frame rate cleanly is straightforward but needs modeline math.
3. **Cutscene support.** Implement CPU YUV→RGB565 (~80 LOC, supports attract mode), or stub `LoadVideo`/`ProcessVideo` (faster path, no cutscenes)? libogg/libtheora may be painful on our toolchain per issue #167.
4. **Mod loader.** Leave ON (C++17, `<filesystem>`) or disable for simpler build? Leaving ON is upstream default and lets users slot mod scripts into place.
5. **OSD / wrapper integration.** Do we add the `mister_joy_shm.h` wrapper-SHM input path from day one, or defer?
6. **Vsync feedback loop.** Port it from day one or defer? Without it, we fall back to timer-based pacing (`SDL_DelayNS`), which is acceptable for single-player.
7. **Audio.** `USE_SDL_AUDIO=ON` builds MiniAudio out and uses SDL2 audio. This is the path that maps onto MiSTer's ALSA SDL2 driver.
8. **Debug console / telemetry.** Port 3sx's perf overlay or start clean?

### 4.6 Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| libogg/libtheora build on armhf (clang-20) | Medium | Known issue from #167. Stub video if it bites. |
| C++17 `<filesystem>` availability in cross-sysroot | Low | Debian bullseye armhf ships a full libstdc++. If problems: disable mod loader. |
| Engine's internal assumptions about host GL availability (dead code paths still compiled) | Low | `#ifdef` gates have been holding across Switch/DX/GL backends; adding MiSTer follows the same pattern. |
| SDL2 on MiSTer requesting acceleration | Low | Our backend bypasses SDL_Renderer. Input/audio only via SDL2. |
| FPGA core work | High effort, not a risk per se | The 3sx native-video Verilog spec is a known quantity. Modeline math changes but shape is the same. |
| Perf — CPU rasterizer at 424×240 @ 60 Hz on A9 800 MHz | Unknown | 384×224 at 60 Hz worked in 3sx with a lot of game-logic CPU load. Mania's engine logic is lighter, pixel count ~18% higher. Should fit. **UNVERIFIED — needs measurement.** |
| 4:3 vs widescreen aspect on CRT | Design decision | Can support both via modeline switch. |

---

## 5. Port surface estimate

Summary of LOC estimates, pulled from §2 and §3.

| Component | New LOC | Adapted from 3sx | Notes |
|---|---|---|---|
| `MiSTerRenderDevice.{cpp,hpp}` | ~300 / ~60 | ~300 | Copy SDL2 backend structure, strip shaders, swap present path |
| `NativeVideoWriter.{c,h}` | 0 | 153 / 41 (verbatim + const changes) | From 3sx |
| `platforms/MiSTer.cmake` | ~80 | copy from Linux.cmake | Select our sources, set defines |
| `RetroEngine.hpp` `RETRO_MISTER` block | ~20 | N/A | Add platform ID, guards |
| Upstream patches to `Drawing.hpp` / `Drawing.cpp` / CMakeLists.txt | ~30 | N/A | `#elif` branches, option passthrough |
| CPU YUV→RGB565 for `SetupVideoTexture_YUV*` | ~80 | N/A | Optional — required only if supporting cutscenes |
| Build wrapper script | ~100 | adaptable from 3sx | Docker + cross-compile driver |
| FPGA core (RTL) | spec exists, RTL UNVERIFIED | reference 3sx spec | New Verilog — pixel reader + VTG + PLL at Mania's modeline |

**Total new C++/C code for the Linux-userland port: ~500–600 LOC.** Dwarfs any existing out-of-tree port (Dreamcast was 2638; Vulkan was 2472).

**FPGA RTL for the core:** separate effort, several hundred lines of Verilog, not estimated here but shape is known from the 3sx spec.

---

## 6. Next concrete steps (recommended sequence)

1. **Baseline native build on macOS.** Verify the tree builds unmodified with `-DRETRO_SUBSYSTEM=SDL2`. Needs Homebrew: `libtheora libogg glew glfw sdl2`. Gets us a reference binary to compare behavior against during port work. Roughly 30 min.

2. **Skeleton MiSTer backend.** Add `platforms/MiSTer.cmake`, `Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}` with all methods stubbed to no-ops or log-print. Wire `RETRO_RENDERDEVICE_MISTER` into `Drawing.hpp:245-257`. Add `PORT_MISTER` option passthrough in game `CMakeLists.txt`. Target: compiles on Mac with `-DPORT_MISTER=ON` even though nothing runs.

3. **ARM cross-compile dry run.** Borrow 3sx's clang-20 cross env. Confirm the RSDKv5 + Mania tree builds for `arm-linux-gnueabihf`. Expect libogg/libtheora linker pain (issue #167) — stub video if needed.

4. **Implement `NativeVideoWriter` in the MiSTer backend.** Copy the 3sx sources verbatim, change constants to 424×240 (or parameterize). Wire into `MiSTerRenderDevice::Init` / `FlipScreen` / `CopyFrameBuffer` / `Release`.

5. **First end-to-end smoke test.** Deploy an `armhf` binary to MiSTer HPS, launch with `Data.rsdk` present, `vga_scaler=0` in `.ini`. Without FPGA RTL, expect a black screen but the Linux side should not crash. Validate via logs.

6. **FPGA core work.** Parameterize the 3sx pixel reader / VTG / PLL modules for Mania's modeline. Integrate into a new `Mania` (or reuse `3S-ARM`) core target. Separate branch.

7. **Vsync feedback loop.** Port from 3sx once FPGA core is writing the feedback word. Defer if FPGA-side isn't writing feedback yet.

8. **Cutscene support.** Either implement CPU YUV→RGB565, or live without cutscenes. This is cosmetic / attract-mode only.

9. **Input polish.** SDL2 gamepad/keyboard first. Wrapper SHM input later if we integrate with OSD.

10. **Perf pass.** Profile with 3sx's telemetry overlay pattern once basic play works. Validate A9 @ 800 MHz can sustain 60 Hz at Mania's internal resolution.

---

## 7. References and cross-links

### RSDKv5 / Sonic Mania

- Engine repo: [github.com/RSDKModding/RSDKv5-Decompilation](https://github.com/RSDKModding/RSDKv5-Decompilation) — master `04f63b6` (2026-03-04)
- Game repo: [github.com/RSDKModding/Sonic-Mania-Decompilation](https://github.com/RSDKModding/Sonic-Mania-Decompilation) — master `ca19403c` (2026-03-12)
- Engine submodule in our tree pinned to `bd59396` (v1.1.1)
- Engine issue #167 (RPi / ARM Linux build): [github.com/RSDKModding/RSDKv5-Decompilation/issues/167](https://github.com/RSDKModding/RSDKv5-Decompilation/issues/167)
- Engine issue #9 (GLES vs core OpenGL): [github.com/RSDKModding/RSDKv5-Decompilation/issues/9](https://github.com/RSDKModding/RSDKv5-Decompilation/issues/9)
- Dreamcast/KallistiOS fork (for reference only, not applicable): [github.com/michael-fadely/RSDKv5-Decompilation/tree/sf94/dreamcast-kallistios-pvr](https://github.com/michael-fadely/RSDKv5-Decompilation/tree/sf94/dreamcast-kallistios-pvr)
- PS Vita fork: [github.com/SonicMastr/Sonic-Mania-Vita](https://github.com/SonicMastr/Sonic-Mania-Vita)
- PortMaster build recipe: [github.com/PortsMaster/PortMaster-New/blob/main/ports/sonic.mania/sonicmania/BUILDING.md](https://github.com/PortsMaster/PortMaster-New/blob/main/ports/sonic.mania/sonicmania/BUILDING.md)

### 3sx-mister (hybrid architecture source of truth)

All paths relative to `/Users/sb/Developer/3sx-mister/`:

- `src/port/sdl/native_video_writer.{h,c}` — DDR3 writer
- `src/port/sdl/sdl_app.c` — platform integration, frame loop, vsync feedback
- `src/port/sdl/sdl_pad.c` — input layer with MiSTer SHM support
- `src/port/config/config.{h,c}` — config defaults, MiSTer overrides at `config.c:30-44`
- `CMakeLists.txt` — `PORT_MISTER` option and gated deps
- `vendor/Main_MiSTer/mister_joy_shm.h` — wrapper SHM struct
- `vendor/Main_MiSTer/thirdsarm_wrapper.cpp` — HPS wrapper entry point
- `docs/design-fpga-native-video.md` (370 lines) — design rationale
- `docs/spec-fpga-native-video.md` (1716 lines) — FPGA module specs, PLL math, ARM-side contract
- `docs/reference-native-analog-video.md` — CRT/S-Video troubleshooting, `vga_scaler=0` requirement
- `docs/mister-wrapper.md` (466 lines) — `.ini` contract, wrapper launch flow
- `docs/mister-runbook.md` (589 lines) — Docker cross-compile, Quartus build, deploy steps

### MiSTer

- MiSTer FPGA main repo: [github.com/MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer)
- Cyclone V memory map and HPS bridges: Intel/Altera Cyclone V HPS Technical Reference Manual
- `/dev/mem` + `O_SYNC` mmap pattern is standard Linux userspace FPGA I/O — no kernel module required at the physical base we use

### Pokémon Diamond/Pearl (checked and rejected)

- Repo: [github.com/pret/pokediamond](https://github.com/pret/pokediamond) — 76% ARM assembly, requires Nintendo CodeWarrior under Wine, builds `.nds` ROM only. No PC port fork exists. Rejected from this research as non-applicable to the hybrid model.

### AM2R (checked and rejected)

- Community fork: [github.com/AM2R-Community-Developers/AM2R-Community-Updates](https://github.com/AM2R-Community-Developers/AM2R-Community-Updates) — GameMaker Studio 1.4 GML, ~50k LOC, no native code. Runs on ARM Linux handhelds via gmloader + YoYo's closed-source `libyoyo.so` + GLES2. Requires GPU; not applicable to Cyclone V. Rejected.

---

## 8. Verification status of claims in this document

**Verified directly from source (this tree or 3sx-mister tree):**
- RSDKv5's CPU software rasterizer architecture (§2.2, §2.3)
- `Drawing.hpp` / `Drawing.cpp` public API and rasterizer behavior
- Backend `#ifdef` dispatch seam at `Drawing.hpp:245-257`
- `Palette.cpp` CPU palette behavior (§2.8)
- `Scene3D.hpp` / `Scene3D.cpp` CPU 3D with no textured mode (§2.9)
- `Video.cpp` YUV-to-shader path (§2.10)
- `RetroEngine.hpp` resolution constants (§2.11)
- SDL2 backend function list and LOC counts (§2.6)
- 3sx `native_video_writer.{h,c}` implementation and constants (§3.2)
- 3sx `PORT_MISTER` CMake gating (§3.4)
- 3sx ARGB8888→RGB565 NEON conversion (§3.3)
- 3sx vsync feedback protocol (§3.6)

**Sourced from upstream issues / third-party reports:**
- Raspberry Pi build success via SDL2 backend (engine issue #167)
- libogg/libtheora linker pain on Pi (issue #167, user ccajas1)
- Miyoo Mini Plus port existence (ducky-obrien blog; binary only, source not public)
- Dreamcast fork backend size (directly read from fork)

**UNVERIFIED / needs measurement:**
- Whether C++17 `<filesystem>` is available in our armhf cross-sysroot (likely yes, but needs `apt list libstdc++-*` check)
- Whether the engine uses RTTI (`dynamic_cast` grep came back empty but was non-exhaustive)
- Whether the engine uses inline asm (not grepped)
- Which backend the Switch port uses (no dedicated `Graphics/Switch/` in tree)
- A9 800 MHz performance at 424×240 @ 60 Hz for Mania's rasterizer workload
- Scene3D z-sort specifics (painter's algorithm inferred from naming; code not read in full)

Anything marked UNVERIFIED in this document should be resolved before committing to an implementation plan.
