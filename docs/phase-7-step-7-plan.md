# Phase 7 Step 7 — Cutscene + image-texture pixel-conversion (implementation plan)

**Document date:** 2026-04-25
**Owner:** sambae (me@sambae.dev)
**Source plan section:** `docs/phase-7-plan.md:368-412`
**Status:** Pre-implementation. Designed to drop into `/implement` as a single
cohesive cycle (one Step 1 below) followed by a Mac-host build verification
(Step 2). Live-hardware sign-off is the user's follow-up and is **out of scope**
for the implementation cycle.

---

## What this plan replaces

Four stub functions in
`/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`,
**lines 343-391** (the `phase-7-plan.md` doc's reference to lines 167-215 is
stale — the file has grown by Phase 6's pacer/overlay scaffolding):

| Stub | Purpose | LOC budget |
|---|---|---|
| `SetupImageTexture(int32 w, int32 h, uint8 *pixels)` (line 343) | RGBA8888 → RGB565, used by `SHADER_RGB_IMAGE` for title cards / `LoadImage` (`Sprite.cpp:1002,1027`). Source dims are always 1024×512 per `Sprite.cpp:1001,1026`. Includes a one-shot `dimMax * dimPercent` per-pixel multiply (see "What NOT to do" / fade-in regression note). | ~35 |
| `SetupVideoTexture_YUV420` (line 351) | BT.601 limited-range YUV (4:2:0) → RGB565, chroma 2×2 nearest upsample. Most common path — `Mania.ogv` ships TH_PF_420. | ~50 |
| `SetupVideoTexture_YUV422` (line 365) | Same, chroma 2×1 horizontal upsample only. | ~25 |
| `SetupVideoTexture_YUV444` (line 379) | Same, no chroma upsample. | ~25 |

Combined with shared helpers (BT.601 math, RGB565 pack, dest-rect compute):
**~150 LOC total** (Edit B grew by ~10 LOC for the dim multiply + sx/sy
even-align in YUV420/422), still close to the `phase-7-plan.md:368` budget.

---

## Architecture findings (verified before planning)

Read these before diving into the steps:

### 1. `screens[0].frameBuffer` is the write target

`Drawing.hpp:76-88` — `ScreenInfo` carries an inline `uint16 frameBuffer[SCREEN_XMAX * SCREEN_YSIZE]` (1280 × 240 RGB565 cells, statically sized for widescreen). At runtime `Drawing.cpp:389-398` (`SetScreenSize`) sets `size.x` to the visible width (320 in 4:3, 424 in widescreen) and `pitch` to that rounded up to a multiple of 16. **`pitch` is in `uint16` cells**, *not* bytes — the byte stride is `pitch * sizeof(uint16) = pitch * 2`. The MiSTer backend already relies on this in `MiSTerRenderDevice.cpp:302-305` (`FlipScreen`).

### 2. Cutscene flow — engine sets `screenCount = 0`, render device owns the framebuffer

`Video.cpp:150` sets `videoSettings.screenCount = 0` when `LoadVideo` fires, and `videoSettings.shaderID = SHADER_YUV_*` (`Video.cpp:167-172`). The engine's main-loop scene rasterizer is therefore skipped during `ENGINESTATE_VIDEOPLAYBACK` (`RetroEngine.cpp:568-571`), and `RetroEngine.cpp:333` (`CopyFrameBuffer()`) is also skipped (it's gated on `engine.inFocus == 1` *and* per-screen iteration). So **whatever bytes are in `screens[0].frameBuffer` when `FlipScreen()` runs are what gets pushed to the FPGA**. That's our hook: `SetupVideoTexture_YUV*` writes the converted frame into `screens[0].frameBuffer`, then the next `FlipScreen()` pushes it via `NativeVideoWriter_WriteFrame` (`MiSTerRenderDevice.cpp:302-305`).

The same logic applies to `SetupImageTexture` for `LoadImage` / `SHADER_RGB_IMAGE` — see `Sprite.cpp:1015,1040` setting `screenCount = 0`.

`RetroEngine.cpp:273` ("`screens[0].size.x != nv_frame_width_runtime`") guard in `FlipScreen` would tank our frames if we somehow caused the size to drift — we don't, we only touch `frameBuffer` contents.

### 3. The engine pre-adjusts the YUV pointers (with one subtlety)

`Video.cpp:236-258` already advances `yPlane` / `uPlane` / `vPlane` past `pic_x` / `pic_y` (the visible pic offset inside the encoded canvas), and chroma pointers are pre-divided by 2 for 4:2:0/4:2:2 cases. So our callbacks receive pointers to the **top-left visible pixel** of each plane (luma is rounded down to even via `pic_x & ~1`), and we just step by `strideY` / `strideU` / `strideV`.

**Important caveat about `width` / `height`:** the engine passes `yuv[0].width` and `yuv[0].height` (`Video.cpp:241,246,253`). Per libtheora `codec.h:144-153,158-161`, those are the **encoded plane dims** (multiples of 16), not the visible `pic_width` / `pic_height`. For Mania.ogv (320×240 source with `pic_x=pic_y=0` and pic dims == plane dims) the two are identical, and our `compute_dest_rect(width, height, dst_w, dst_h, ...)` produces the right answer. For a hypothetical theora clip with non-zero `pic_x/pic_y` or with encoded padding (e.g. 360→368 plane width), our loop would read into encoded-padding columns and the center-crop math would be off by `(plane_w - pic_w)/2`. We accept this for Phase 7 because Mania ships a single Mania.ogv at 320×240 with no padding; document the assumption in the source comment so a future maintainer adding a wider/letterboxed clip knows where to look.

### 4. SDL2 reference does not upsample — it hands the YUV planes to a `SDL_PIXELFORMAT_YV12` GPU texture (`SDL2RenderDevice.cpp:1095,1111,1127`). The GPU does both upsampling and YUV→RGB. **We do both in CPU.** EGL backend (`EGLRenderDevice.cpp:1009-1140`) does CPU YUV→RGBA8888 packing for upload but still relies on the shader for the actual color-space transform — not directly reusable for our RGB565 output.

### 5. Image dims for `SetupImageTexture`

`Sprite.cpp:1001,1026` requires images to be exactly `RETRO_VIDEO_TEXTURE_W × RETRO_VIDEO_TEXTURE_H` = **1024 × 512**. The shader-based backends sample a sub-rect of that giant texture; without shaders we **center-crop** the 320×240 (or 424×240) destination from the source's center. Anything that relied on shader scaling will look different — that's accepted scope per `phase-7-plan.md:388` ("center-crop or letterbox; do NOT bilinear-scale").

In practice Mania's `LoadImage` callsites are `LogoSetup.c:87,89` (CESA logo on Plus builds) and `UIVideo.c:72` (cutscene first-frame poster). For the attract path that the user's success criteria target, only `LoadVideo` is in play — `SetupImageTexture` is a freebie alongside.

### 6. Mac-host path is safe by construction

`NativeVideoWriter.c:151-163` (`#else` branch, fires when `!__linux__ || !PORT_MISTER`) makes `NativeVideoWriter_WriteFrame` a true no-op on Mac. Our new code writes into `screens[0].frameBuffer`, which is allocated as part of the `ScreenInfo` struct in BSS regardless of platform — there is no Mac-specific allocation step to worry about. Mac builds will compile and run; the engine will call our YUV/image code, the framebuffer will fill, and `FlipScreen` will just throw it away through the writer's no-op stub.

### 7. BT.601 limited-range constants

Standard form:
```
C = Y - 16
D = U - 128
E = V - 128
R = clamp((298*C +   0*D + 409*E + 128) >> 8, 0, 255)
G = clamp((298*C - 100*D - 208*E + 128) >> 8, 0, 255)
B = clamp((298*C + 516*D +   0*E + 128) >> 8, 0, 255)
```
This is the same coefficient set used by Wikipedia / FFmpeg's `bt601` matrix
for 8-bit limited-range. **Not BT.709** — Mania's encoded videos are 240p
content, BT.601 is correct.

---

## Step 1 — Implement the four pixel-conversion functions

### Title
Replace the four `[stub]` functions in `MiSTerRenderDevice.cpp` with real CPU
pixel-conversion that writes RGB565 directly into `screens[0].frameBuffer`,
center-cropping or letterboxing to fit the runtime display dims.

### Why it matters
Unblocks attract-mode cutscene playback (`Mania.ogv` after ~13 s idle on the
title screen), `SHADER_RGB_IMAGE` title cards, and any future mid-game cutscene
the engine might invoke. Mania currently boots fine through the title screen
(per `mister-port-plan.md` Phase 6 sign-off); the attract loop hits the
`[stub]` early-out and either freezes or shows the previous-frame stale
contents until the engine times out and returns to title.

### Exact files to read before implementing
1. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:1-50` — file-include rules: this file is textually `#include`d from `Drawing.cpp:153`. The include is at file/global scope (NOT inside a `namespace RSDK { ... }` block), but `Drawing.cpp:3` has `using namespace RSDK;` which makes `RSDK::` symbols visible without qualification. No `#include` directives are allowed inside `MiSTerRenderDevice.cpp` — any new headers needed must go into `Drawing.cpp` ahead of the include (see `Drawing.cpp:151` for the existing `<cstdlib>` precedent).
2. Same file, **lines 188-198** (`InitGraphicsAPI` → `SetScreenSize`) — establishes that `screens[0].size` and `screens[0].pitch` are valid by the time any draw / setup-texture call fires.
3. Same file, **lines 266-308** (`FlipScreen`) — confirms `screens[0].frameBuffer` is the exact buffer pushed to FPGA, and that `screens[0].pitch * sizeof(uint16)` is the byte stride contract `NativeVideoWriter_WriteFrame` expects.
4. Same file, **lines 343-391** — the four stubs being replaced.
5. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Video.cpp:230-258` — the dispatch site. Confirms callbacks receive plane pointers pre-offset to the visible pic origin, and chroma is pre-stepped (`pic_y >> 1`, `pic_x >> 1`) for 4:2:0/4:2:2.
6. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:76-88` — `ScreenInfo` field layout (frameBuffer, size, pitch).
7. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:389-405` — `SetScreenSize` body, confirms `pitch` is in uint16 cells and rounded up to multiple of 16.
8. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c:94-112,151-163` — the contract for what our framebuffer write feeds into (Linux+MiSTer real path) and the Mac-host no-op branch.
9. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp:57-67` — function declarations (no header changes required; signatures already match the engine).
10. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Sprite.cpp:987-1055` — `LoadImage` flow; confirms image dims are always 1024×512 RGBA8888 and `screenCount = 0` during `ENGINESTATE_SHOWIMAGE`.

### Exact files to create / modify
**Modify only:** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`

No new files. No header edits. No CMake edits.

#### Edit A — add three `static inline` helpers

Insert immediately before the existing `SetupImageTexture` at **line 343**, after the closing `}` of `GetWindowSize` (line 341). `static inline` at file/global scope gives internal linkage (avoids ODR risk across translation units) while letting the compiler fold the bodies into the four call sites. The textual include is at global scope in `Drawing.cpp:153`; `using namespace RSDK;` higher up just makes `RSDK::` symbols visible without qualification.

```cpp
// --- Phase 7 Step 7: cutscene / image conversion helpers -------------------
// Pure-C++, no NEON, no allocation. Inlined into the four entry points below.
//
// `pack_rgb565`:  8-bit R/G/B -> RGB565 little-endian uint16.
// `yuv601_to_rgb565`:  BT.601 limited-range YUV -> RGB565. Y already has its
//   -16 offset baked into the caller's pre-pass to keep the inner loop a
//   single multiply per channel; see the caller for context. Constants from
//   the standard 8-bit limited-range matrix (R=298C+409E, G=298C-100D-208E,
//   B=298C+516D, all >>8 with +128 round-bias).
// `compute_dest_rect`:  given source (sw,sh) and destination (dw,dh),
//   return the centered intersection (dx, dy, copy_w, copy_h). When the
//   source is larger we center-crop; smaller we letterbox. Caller handles
//   the border fill.
static inline uint16 pack_rgb565(int r, int g, int b)
{
    // r,g,b are already clamped to [0,255] by the caller.
    return (uint16)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static inline uint16 yuv601_to_rgb565(int y, int u, int v)
{
    int c = y - 16;
    int d = u - 128;
    int e = v - 128;
    int r = (298 * c           + 409 * e + 128) >> 8;
    int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
    int b = (298 * c + 516 * d           + 128) >> 8;
    if (r < 0) r = 0; else if (r > 255) r = 255;
    if (g < 0) g = 0; else if (g > 255) g = 255;
    if (b < 0) b = 0; else if (b > 255) b = 255;
    return pack_rgb565(r, g, b);
}

// Compute centered destination rect for a source of (sw,sh) drawn into a
// destination of (dw,dh). On output:
//   *dx, *dy    -- top-left destination cell offset (>=0)
//   *sx, *sy    -- top-left source cell offset (>=0; nonzero when sw>dw or sh>dh)
//   *copy_w, *copy_h -- visible intersection in cells (<= min(sw,dw), etc.)
// The caller must clear the destination first if border fill is desired.
static inline void compute_dest_rect(int sw, int sh, int dw, int dh,
                                     int *dx, int *dy, int *sx, int *sy,
                                     int *copy_w, int *copy_h)
{
    if (sw >= dw) { *sx = (sw - dw) / 2; *dx = 0;            *copy_w = dw; }
    else          { *sx = 0;             *dx = (dw - sw) / 2; *copy_w = sw; }
    if (sh >= dh) { *sy = (sh - dh) / 2; *dy = 0;            *copy_h = dh; }
    else          { *sy = 0;             *dy = (dh - sh) / 2; *copy_h = sh; }
}
```

**Why `static inline` at file/global scope:** see the comment block at file
top (`MiSTerRenderDevice.cpp:1-16`). The file is textually `#include`d from
`Drawing.cpp:153` at global scope. `static` gives internal linkage (no
multiple-def risk if a future TU also includes it); `inline` lets the
compiler fold the bodies into the four call sites, keeping the inner loops
tight on Cortex-A9. (`using namespace RSDK;` at `Drawing.cpp:3` makes
`screens`, `videoSettings`, etc. visible without qualification — the include
is *not* inside a `namespace RSDK { ... }` block.)

#### Edit B — `SetupImageTexture` (replace lines 343-349)

```cpp
void RenderDevice::SetupImageTexture(int32 width, int32 height, uint8 *imagePixels)
{
    // RGBA8888 -> RGB565 into screens[0].frameBuffer. Used by SHADER_RGB_IMAGE
    // (LoadImage / title cards). Source is always 1024x512 per Sprite.cpp:1001,
    // 1026 (the engine logs an error and skips the call otherwise) but we
    // honor whatever (width, height) the engine hands us. Center-crop or
    // letterbox to the runtime display dims; no bilinear scaling.
    if (!imagePixels) return;

    const int dst_w   = screens[0].size.x;
    const int dst_h   = screens[0].size.y;
    const int dst_pit = screens[0].pitch;  // uint16 cells per row

    int dx, dy, sx, sy, cw, ch;
    compute_dest_rect(width, height, dst_w, dst_h, &dx, &dy, &sx, &sy, &cw, &ch);

    // Clear the entire framebuffer first so any letterbox border is black.
    // Memset is fine for RGB565 black (0x0000).
    memset(screens[0].frameBuffer, 0, (size_t)dst_pit * (size_t)dst_h * sizeof(uint16));

    const uint8 *src_row = imagePixels + ((size_t)sy * width + sx) * 4u;
    uint16      *dst_row = screens[0].frameBuffer + (size_t)dy * dst_pit + dx;

    // dim correction (BT.601 dim ramp from engine: 0.0 .. 1.0). videoSettings
    // is the namespace-level RSDK var; field defs are in Drawing.hpp:106-130.
    // NOTE: Sprite.cpp:1002 calls SetupImageTexture BEFORE setting dimMax=0.0
    // (line 1013), so at first-frame entry dim is the previous (typically 1.0)
    // value. Other backends apply dim per-frame in the shader using the live
    // dimMax/dimPercent — without a shader, achieving fade-in here would require
    // re-conversion every FlipScreen + a cached source. That is out-of-scope
    // for this step (see "What NOT to do" / fade-in regression). We still
    // multiply by current dim at call time so any future engine flow that
    // sets dim before the call (or any non-zero state) is honored.
    const float dim = videoSettings.dimMax * videoSettings.dimPercent;
    // Pre-quantize once into [0,256] so the inner loop uses a single int mul.
    int dim_q = (int)(dim * 256.0f);
    if (dim_q < 0) dim_q = 0;
    if (dim_q > 256) dim_q = 256;

    for (int y = 0; y < ch; ++y) {
        const uint8 *s = src_row;
        uint16      *d = dst_row;
        for (int x = 0; x < cw; ++x) {
            // Source byte order: ImagePNG::UnpackPixels_RGBA (Sprite.cpp:367-389)
            // builds a uint32 as `(R<<16) | (G<<8) | (B<<0) | (A<<24)` using the
            // _REDOFF/_GREENOFF/_BLUEOFF macros (Sprite.cpp:269-277, non-Android
            // arm: R=16,G=8,B=0). On little-endian (ARMv7-A, x86_64, arm64) the
            // uint32 is stored as bytes [B, G, R, A]. SDL2 reads the buffer as
            // a uint32 stream into SDL_PIXELFORMAT_ARGB8888 (SDL2RenderDevice.cpp:
            // 1058,1069-1072) where the value-form 0xAARRGGBB is interpreted
            // correctly. We read bytewise here, so byte 0 is B, byte 1 is G,
            // byte 2 is R, byte 3 is A. (See Phase 7 Step 7 plan review note.)
            int b = s[0], g = s[1], r = s[2];
            // Apply dim with a single 0..256 quantized multiply per channel.
            r = (r * dim_q) >> 8;
            g = (g * dim_q) >> 8;
            b = (b * dim_q) >> 8;
            *d++ = pack_rgb565(r, g, b);
            s += 4;
        }
        src_row += (size_t)width * 4u;
        dst_row += dst_pit;
    }
}
```

#### Edit C — `SetupVideoTexture_YUV420` (replace lines 351-363)

```cpp
void RenderDevice::SetupVideoTexture_YUV420(int32 width, int32 height,
                                            uint8 *yPlane, uint8 *uPlane, uint8 *vPlane,
                                            int32 strideY, int32 strideU, int32 strideV)
{
    if (!yPlane || !uPlane || !vPlane) return;

    const int dst_w   = screens[0].size.x;
    const int dst_h   = screens[0].size.y;
    const int dst_pit = screens[0].pitch;

    int dx, dy, sx, sy, cw, ch;
    // NOTE: Engine passes ENCODED plane dims (yuv[0].width/height per
    // Video.cpp:253-254), not visible-pic dims. For Mania.ogv these are equal
    // (320x240, pic_x=pic_y=0). If a future clip has encoded padding or a
    // non-zero pic origin this center-crop would mis-align by up to
    // (plane_w - pic_w)/2. See architecture finding 3.
    compute_dest_rect(width, height, dst_w, dst_h, &dx, &dy, &sx, &sy, &cw, &ch);
    // Round source offsets down to even before computing chroma offsets so
    // 4:2:0/4:2:2 chroma sampling stays aligned when (sw - dw) is odd.
    sx &= ~1;
    sy &= ~1;

    // Letterbox border: only memset on the very first frame of a clip OR when
    // dims would create a non-zero border; cheap-enough to do unconditionally
    // on every frame given 320*240*2 = 153 600 B / frame and Cortex-A9
    // memset bandwidth. Keeps the implementation branchless.
    memset(screens[0].frameBuffer, 0, (size_t)dst_pit * (size_t)dst_h * sizeof(uint16));

    // Chroma sub-sampled 2x2 for 4:2:0. The engine pre-stepped the chroma
    // pointers by (pic_y >> 1, pic_x >> 1) in Video.cpp:255-257, so (sx,sy)
    // here is in luma cells -- step chroma by (sx>>1, sy>>1).
    const uint8 *yrow = yPlane + (size_t)sy * strideY + sx;
    const uint8 *urow = uPlane + (size_t)(sy >> 1) * strideU + (sx >> 1);
    const uint8 *vrow = vPlane + (size_t)(sy >> 1) * strideV + (sx >> 1);
    uint16      *drow = screens[0].frameBuffer + (size_t)dy * dst_pit + dx;

    for (int y = 0; y < ch; ++y) {
        const uint8 *yp = yrow;
        const uint8 *up = urow;
        const uint8 *vp = vrow;
        uint16      *dp = drow;
        for (int x = 0; x + 1 < cw; x += 2) {
            int u = up[0];
            int v = vp[0];
            dp[0] = yuv601_to_rgb565(yp[0], u, v);
            dp[1] = yuv601_to_rgb565(yp[1], u, v);
            yp += 2; dp += 2; up += 1; vp += 1;
        }
        if (cw & 1) {
            // Tail pixel when copy width is odd -- reuse the last chroma sample.
            *dp = yuv601_to_rgb565(*yp, *up, *vp);
        }
        yrow += strideY;
        // Chroma row only advances every other luma row.
        if ((y & 1) == 1) { urow += strideU; vrow += strideV; }
        drow += dst_pit;
    }
}
```

#### Edit D — `SetupVideoTexture_YUV422` (replace lines 365-377)

```cpp
void RenderDevice::SetupVideoTexture_YUV422(int32 width, int32 height,
                                            uint8 *yPlane, uint8 *uPlane, uint8 *vPlane,
                                            int32 strideY, int32 strideU, int32 strideV)
{
    if (!yPlane || !uPlane || !vPlane) return;

    const int dst_w   = screens[0].size.x;
    const int dst_h   = screens[0].size.y;
    const int dst_pit = screens[0].pitch;

    int dx, dy, sx, sy, cw, ch;
    // See YUV420 above re: width/height being encoded plane dims.
    compute_dest_rect(width, height, dst_w, dst_h, &dx, &dy, &sx, &sy, &cw, &ch);
    // Even-align sx so the chroma column lookup (sx >> 1) matches the luma sample.
    sx &= ~1;
    memset(screens[0].frameBuffer, 0, (size_t)dst_pit * (size_t)dst_h * sizeof(uint16));

    // 4:2:2 -- chroma full vertical, halved horizontal. Chroma pointer
    // pre-stepped by (pic_y, pic_x>>1) in Video.cpp:247-249, so (sx,sy) here
    // is luma cells; step chroma by (sx>>1, sy).
    const uint8 *yrow = yPlane + (size_t)sy * strideY + sx;
    const uint8 *urow = uPlane + (size_t)sy * strideU + (sx >> 1);
    const uint8 *vrow = vPlane + (size_t)sy * strideV + (sx >> 1);
    uint16      *drow = screens[0].frameBuffer + (size_t)dy * dst_pit + dx;

    for (int y = 0; y < ch; ++y) {
        const uint8 *yp = yrow;
        const uint8 *up = urow;
        const uint8 *vp = vrow;
        uint16      *dp = drow;
        for (int x = 0; x + 1 < cw; x += 2) {
            int u = up[0];
            int v = vp[0];
            dp[0] = yuv601_to_rgb565(yp[0], u, v);
            dp[1] = yuv601_to_rgb565(yp[1], u, v);
            yp += 2; dp += 2; up += 1; vp += 1;
        }
        if (cw & 1) {
            *dp = yuv601_to_rgb565(*yp, *up, *vp);
        }
        yrow += strideY;
        urow += strideU;
        vrow += strideV;
        drow += dst_pit;
    }
}
```

#### Edit E — `SetupVideoTexture_YUV444` (replace lines 379-391)

```cpp
void RenderDevice::SetupVideoTexture_YUV444(int32 width, int32 height,
                                            uint8 *yPlane, uint8 *uPlane, uint8 *vPlane,
                                            int32 strideY, int32 strideU, int32 strideV)
{
    if (!yPlane || !uPlane || !vPlane) return;

    const int dst_w   = screens[0].size.x;
    const int dst_h   = screens[0].size.y;
    const int dst_pit = screens[0].pitch;

    int dx, dy, sx, sy, cw, ch;
    // See YUV420 above re: width/height being encoded plane dims.
    compute_dest_rect(width, height, dst_w, dst_h, &dx, &dy, &sx, &sy, &cw, &ch);
    memset(screens[0].frameBuffer, 0, (size_t)dst_pit * (size_t)dst_h * sizeof(uint16));

    // 4:4:4 -- one chroma sample per luma sample. Engine pre-stepped chroma
    // by the full (pic_y, pic_x) in Video.cpp:241-243.
    const uint8 *yrow = yPlane + (size_t)sy * strideY + sx;
    const uint8 *urow = uPlane + (size_t)sy * strideU + sx;
    const uint8 *vrow = vPlane + (size_t)sy * strideV + sx;
    uint16      *drow = screens[0].frameBuffer + (size_t)dy * dst_pit + dx;

    for (int y = 0; y < ch; ++y) {
        const uint8 *yp = yrow;
        const uint8 *up = urow;
        const uint8 *vp = vrow;
        uint16      *dp = drow;
        for (int x = 0; x < cw; ++x) {
            *dp++ = yuv601_to_rgb565(*yp++, *up++, *vp++);
        }
        yrow += strideY;
        urow += strideU;
        vrow += strideV;
        drow += dst_pit;
    }
}
```

### Concrete success criteria
1. **Compilation (Mac host, the only test we run during the implement cycle):**
   - `cd /Users/sb/Developer/sonic-mania-mister/build-p7-tel && cmake --build . -j 2>&1 | tee /tmp/p7-step7-build.log` exits 0.
   - The build.log contains zero new warnings beyond what's already present in the cached state. Compare against the prior clean-build log if needed.
   - `nm build-p7-tel/dependencies/Game/libGame.* 2>/dev/null` is **not** the right artifact; the conversion code lives in RetroEngine. Instead spot-check that the symbols resolved by inspecting `objdump -d` is **out of scope** — a clean build is the gate.
2. **No `[stub]` log lines for the four functions:** count `[stub]` occurrences in `MiSTerRenderDevice.cpp` and confirm the count drops by 4 (from 7 to 3 per the pre-edit baseline; the remaining 3 are unrelated stubs in `RefreshWindow`, `InitVertexBuffer`, etc.).
   ```bash
   grep -c '\[stub\]' dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp
   # Pre-edit: 7
   # Post-edit: 3
   ```
   Also confirm the four function definitions still exist (we replaced their bodies, not removed them):
   ```bash
   grep -cE '^void RenderDevice::(SetupImageTexture|SetupVideoTexture_YUV(420|422|444))' \
       dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp
   # Expect: 4
   ```
   (The reviewer's prior grep `grep -c "...SetupVideoTexture..."` was wrong — it would still match the function-definition lines after the stubs are removed and yield 4, not 0.)
3. **No header changes:** `git diff dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp` is empty. Same for any CMake file.
4. **Diff size:** `git diff --stat dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` shows a churn around 150 lines added, ~50 removed (the stubs).
5. **Live-hardware sign-off (deferred — user runs this themselves):**
   - Attract-mode Mania.ogv plays end-to-end with synced audio.
   - `log.txt` shows zero `MiSTerRenderDevice::SetupVideoTexture_*[stub]` lines during cutscene playback.
   - FPS overlay holds ≥ 55 fps on 800 MHz stock; absolute floor 30 fps.

### Dependencies on prior steps
- Phase 7 Step 4 (save-path stability — already merged at HEAD per `git log` showing `0257a006 mister: Phase 7 save-path revert (./saves/ → ./)`).
- Phase 6 (the FPS overlay we'll use to verify on-device performance — already shipped, evident in `MiSTerRenderDevice.cpp:226-264`).
- No upstream RSDKv5 changes required.

### What NOT to do
- **No NEON intrinsics.** Plain C/C++ math. Cortex-A9 with the standard ARM hardening flags (`MiSTer.cmake:213-228`) auto-vectorizes simple inner loops adequately for our 320×240 budget; explicit NEON is out of scope.
- **No bilinear scaling.** Center-crop + letterbox only. Source dims are typically 320×240 (Mania.ogv) or 1024×512 (LoadImage), both handled by the `compute_dest_rect` path.
- **No per-frame heap allocation.** Everything is on the stack or writes directly to `screens[0].frameBuffer`. No `static` scratch buffer either — we don't need one.
- **Don't touch `Video.cpp`.** The engine path is untouched; we only change what the four backend callbacks do.
- **Don't touch `MiSTerRenderDevice.hpp`.** Signatures already match.
- **Don't touch `Drawing.cpp` / `Drawing.hpp`.** They sit upstream of our backend.
- **Limited fade-in/out for `LoadImage`.** Other backends apply `videoSettings.dimMax * videoSettings.dimPercent` per-frame in their fragment shader (`EGLRenderDevice.cpp:681`, `DX9RenderDevice.cpp:207`, `DX11RenderDevice.cpp:215`). MiSTer has no shader and `SetupImageTexture` is called only ONCE per `LoadImage` (`Sprite.cpp:1002,1027`), with `videoSettings.dimMax` set to 0.0 immediately *after* the call (`Sprite.cpp:1013,1038`). Edit B applies the live `dimMax * dimPercent` once at call time so any non-default dim state is honored, but with the current engine flow this multiplies by 1.0 (the previous-state value). **Net effect: title cards appear instantly with no fade-in/out, then disappear.** Properly faded title cards would require either re-conversion every `FlipScreen` (with a static cache of the un-dimmed RGB565 frame, ~150 KB BSS for 320×240) or an FlipScreen-side per-pixel multiply against a stored cache. Both add complexity beyond the 140-LOC budget for this step. The Mac-host build still verifies cleanly; live-hardware will show no fade — accepted scope cut, document in the commit message.
- **No `videoSettings.dimMax` correction during cutscene playback.** During `ENGINESTATE_VIDEOPLAYBACK` `videoSettings.dimMax` is forced to 1.0 by the entry path. The YUV variants don't apply dim — pristine BT.601-converted RGB565 only.
- **Don't add `DrawDevString` / FPS-overlay calls inside the four conversion functions.** The overlay still happens in `FlipScreen` (`MiSTerRenderDevice.cpp:295-300`), which runs *after* our conversion writes, so the overlay text will draw on top of the cutscene frame for free.
- **Don't remove the `(void)` parameter casts** by replacing them with implicit use — replace them with the actual loop bodies. The `(void)` was a stub-time silence-the-warning trick; in the new bodies every parameter is referenced.
- **Don't widen the build-flag surface.** No new `target_compile_definitions`, no new options.

### What to do if it fails
- **Compile error:** Most likely cause is namespace/lookup confusion because the file is textually included. If `screens` or `uint16` isn't found, double-check the file is being recompiled — the verification block already forces this via `touch dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp`. If the touch step was skipped, run it now.
- **Signed/unsigned warning** on the `<<` shifts in `pack_rgb565`: cast operands to `int` first, then to `uint16` at the return. The current draft already does this implicitly; if `-Wconversion` or `-Wnarrowing` flags it, add explicit `(uint16)` casts on each subexpression.
- **Color appears swapped (red ↔ blue) on device:** Edit B reads `b = s[0]; g = s[1]; r = s[2]` per the verified byte order (`ImagePNG::UnpackPixels_RGBA` writes `(R<<16)|(G<<8)|(B<<0)|(A<<24)` to a uint32, which is `[B,G,R,A]` in memory on little-endian — see plan review note). If something on-device shows R/B swapped, the most likely cause is the engine got swapped `_REDOFF`/`_BLUEOFF` macros (e.g. building with `RETRO_PLATFORM=RETRO_ANDROID` accidentally — `Sprite.cpp:269-272`). Verify `RETRO_PLATFORM` first; only re-swap as a last resort.
- **Greenish tint on YUV:** The classic BT.601 vs BT.709 confusion. Re-read the helper — Y offset must be 16 (limited range), U/V offset 128. If the encoded video is full-range (some web exports), a Y offset of 0 may be correct; the doc explicitly says limited-range, but if the user reports greenish playback this is the first thing to flip.
- **Frame rate craters below 30 fps on real hardware:** The memset-per-frame is the largest cost. Cut it: clear the framebuffer once at first call (track via a file-static `bool s_video_clear_pending = true;`), then only re-clear when source dims change between frames. This is a single-step optimization; don't pre-emptively gold-plate it.
- **Letterbox borders are not black on first frame:** Delete the memset and use the `s_video_clear_pending` trick from the previous bullet — the issue is that `screens[0].frameBuffer` is BSS (zero-initialized) at startup, so the first call sees borders=0 already, but subsequent calls inherit the previous video frame. Memset every frame is the safe default; the optimization above is only if the safe default tanks fps.
- **Engine hangs after `LoadVideo`:** Probably unrelated to this step (libtheora decode error, audio-clock starvation). Check `log.txt` for `theora` errors. Out of scope — kick back to the user.
- **The 2-hour ceiling hits before YUV is done:** Per `phase-7-plan.md:373`, the explicit cut-line is "drop `SetupImageTexture` and ship YUV only". The `SetupImageTexture` body is the smallest and most isolated; deleting Edit B and leaving the existing `[stub]` body is a clean revert.

---

## Step 2 — Mac-host build verification

### Title
Re-configure-and-build the existing `build-p7-tel` directory and confirm the
unstubbed code compiles cleanly with `PORT_MISTER=ON` on darwin.

### Why it matters
Catches namespace / template / signed-conversion issues before the user
deploys to the cross-compile container. Mac is the cheap iteration loop per
the project's documented dev flow (`phase-1-plan.md` early sections).

### Exact files to read before implementing
None new. This step is a build/verify only.

### Exact files to create / modify
None. Build artifacts only.

### Concrete success criteria

Run from `/Users/sb/Developer/sonic-mania-mister/`:

```bash
# Reuse build-p7-tel (already configured for PORT_MISTER=ON, telemetry-on).
# Inspect the cache to confirm before building:
grep -E "PORT_MISTER|RETRO_SUBSYSTEM|ENABLE_PERF_TELEMETRY" \
    build-p7-tel/CMakeCache.txt

# Expect:
#   ENABLE_PERF_TELEMETRY:BOOL=ON
#   PORT_MISTER:BOOL=ON
#   RETRO_SUBSYSTEM:STRING=MiSTer

# Build. Drawing.cpp textually `#include`s MiSTerRenderDevice.cpp, and CMake's
# implicit dep scan does follow `#include` directives regardless of the
# included file's extension, but we don't trust this with our build chain --
# the `touch` is REQUIRED, not optional, to ensure Drawing.cpp.o is rebuilt
# when only MiSTerRenderDevice.cpp changed.
touch dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp
cmake --build build-p7-tel -j 2>&1 | tee /tmp/p7-step7-mac.log

# Pass = exit 0, "Build complete" / no "error:" lines, and the linked
# RetroEngine binary is updated. Sanity-check the binary path first since
# CMake target dirs occasionally drift between configs:
find build-p7-tel -name 'RetroEngine*' -type f
ls -la build-p7-tel/dependencies/RSDKv5/RetroEngine
test -f build-p7-tel/dependencies/RSDKv5/RetroEngine && echo "OK: binary exists"

# Spot-check no new warnings related to the four functions:
grep -E "MiSTerRenderDevice.cpp:.*(warning|error)" /tmp/p7-step7-mac.log || \
    echo "OK: no MiSTerRenderDevice.cpp warnings/errors"
```

If the directory is missing or its cache is stale (rare — `0257a006` should have left it in a known-good state), re-create with:

```bash
cmake -S . -B build-p7-tel \
    -DPORT_MISTER=ON \
    -DENABLE_PERF_TELEMETRY=ON \
    -DCMAKE_BUILD_TYPE=Release
```

### Dependencies on prior steps
Step 1 must be complete and the file saved. No git commit required for the build to fire.

### What NOT to do
- Don't run a Mac-only "smoke test" launch of the engine. Mac builds use the
  MiSTer backend (`PORT_MISTER=ON` forces `RETRO_SUBSYSTEM=MiSTer`), which
  early-outs `NativeVideoWriter_Init` on macOS (`NativeVideoWriter.c:151`); a
  Mac launch produces no usable on-screen output and won't catch anything a
  successful link wouldn't already catch.
- Don't run the cross-compile container build (`tools/mister/build-game.sh`)
  as part of this step. Live-hardware testing is the user's follow-up.
- Don't commit until the user signs off. The `/implement` skill should propose
  the diff and let the user invoke `git commit` after their review.

### What to do if it fails
- **Header-not-found / missing-symbol:** the textual-include stack got disturbed. Run `cmake --build build-p7-tel --target clean && cmake --build build-p7-tel -j` to force a full rebuild. If the failure persists, check that `Drawing.cpp:144-153` still has the `RETRO_RENDERDEVICE_MISTER` arm intact and points at the right file.
- **`size_t` ambiguity:** if the platform headers don't pull `<cstddef>` transitively, the stride math in `(size_t)sy * strideY` can be flagged. Cast through `intptr_t` instead; the engine's existing types (`int32` and `uint8 *`) are sufficient on 32-bit ARM and 64-bit darwin alike.
- **`memset` not declared:** `<cstring>` should already be in scope through the engine's `RetroEngine.hpp` include chain; if not, it's still available as a builtin under `-fbuiltin`. Don't add `#include` directives — that would violate the textual-include rule.
- **Cache mismatch (`PORT_MISTER:BOOL=OFF` in the cache):** wrong build dir was reused. Pick `build-mister` if available; otherwise create a fresh `build-p7-step7` per the `cmake -S . -B ...` command above.

---

## Verification commands (single block, copy-paste ready)

```bash
cd /Users/sb/Developer/sonic-mania-mister

# Sanity: confirm we're on the mister branch with the expected baseline.
git status -sb | head -3

# Sanity: confirm the chosen build dir is configured for PORT_MISTER.
grep -E "^(PORT_MISTER|RETRO_SUBSYSTEM|ENABLE_PERF_TELEMETRY):" \
    build-p7-tel/CMakeCache.txt

# Force-recompile the textually-included unit and link. The `touch` is
# REQUIRED -- Drawing.cpp.o needs to rebuild when only MiSTerRenderDevice.cpp
# changed, and we don't fully trust CMake's implicit dep scan for `#include`
# of a `.cpp` file.
touch dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp
cmake --build build-p7-tel -j 2>&1 | tee /tmp/p7-step7-mac.log

# Pass gates. Sanity-check the binary path first since CMake target dirs
# occasionally drift between configs.
echo "--- exit gate ---"
find build-p7-tel -name 'RetroEngine*' -type f
echo "binary present: $(test -f build-p7-tel/dependencies/RSDKv5/RetroEngine && echo yes || echo no)"
echo "stub-line count after edit: $(grep -c '\\[stub\\]' \
    dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp)"
echo "diff stat:"
git diff --stat dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp
```

Expected post-implementation:
- exit 0 from cmake.
- `binary present: yes`.
- `stub-line count after edit:` is **fewer than the pre-edit count by 4**
  (the four `[stub]` `PrintLog` calls in `SetupImageTexture`,
  `SetupVideoTexture_YUV{420,422,444}`); other `[stub]` lines elsewhere in
  the file (e.g., `RefreshWindow`, `InitVertexBuffer`) remain.
- `diff --stat` shows ~150 added / ~50 removed in
  `MiSTerRenderDevice.cpp` and **only** that file.

---

## Post-merge follow-ups (not part of `/implement` cycle)

1. **Live-hardware test (user-driven):** Deploy a telemetry-flavor build to a real DE10-Nano with `Data.rsdk` present; idle on the title screen for ~13 s; observe `Mania.ogv` playback. Per `phase-7-plan.md:393-397`, gating bar is `≥ 55 fps` with `≥ 30 fps` floor.
2. **`log.txt` audit:** confirm no `[stub]` lines from the four functions appear during cutscene playback.
3. **If color/scale anomalies surface:** apply the documented fallbacks in Step 1 "What to do if it fails" (BT.709 try, single-clear optimization, RETRO_PLATFORM verify for image R/B). Each is a single-symbol fix.
4. **Optional commit message stub** for the user to consider when they ship:
   ```
   mister: Phase 7 Step 7 — unstub cutscene + image pixel conversion

   - SetupImageTexture: RGBA8888 -> RGB565, center-crop/letterbox,
     one-shot dim multiply (no fade-in/out without a re-blit hook,
     accepted scope cut)
   - SetupVideoTexture_YUV420/422/444: BT.601 limited-range, CPU upsample
   - Pure C++, no NEON, no per-frame heap; writes directly to
     screens[0].frameBuffer; FlipScreen pushes to FPGA unchanged.
   - Mac-host PORT_MISTER=ON build verified.
   ```

---

## Review notes / changelog

Plan revised on 2026-04-25 in response to the Phase 7 Step 7 review pass.
All P-1 findings applied; P-2s applied unless noted.

| # | Sev | Finding | Action |
|---|---|---|---|
| 1 | P-1 | Edit B reads source bytes assuming RGBA-in-memory; actual layout is `[B,G,R,A]` per `Sprite.cpp:269-277,367-388` (uint32 `(R<<16)\|(G<<8)\|(B<<0)\|(A<<24)` on little-endian) | **Applied.** Edit B now reads `b=s[0]; g=s[1]; r=s[2]`. Comment block updated with full explanation; "what to do if it fails" now points at `RETRO_PLATFORM` macros, not at swapping back. |
| 2 | P-1 | Plan claimed `width`/`height` are visible-pic dims; actually encoded plane dims per libtheora `th_img_plane` | **Applied** as documentation/comment fix. Architecture finding 3 now clarifies the distinction; YUV420/422/444 Edits include a `NOTE:` comment so a future maintainer adding a non-Mania-shaped clip will know where to look. Math unchanged because Mania.ogv has plane==pic dims. |
| 3 | P-2 | Plan said the textual include is "inside `namespace RSDK { ... }`"; actually at file/global scope after `using namespace RSDK;` | **Applied.** "Exact files to read" item 1 and "Why `static inline`" both updated to reflect the real namespace context. |
| 4 | P-2 | No CPU dim multiply in `SetupImageTexture` would lose the title-card fade-in versus other backends | **Partially applied.** Edit B now applies a quantized per-pixel `dimMax * dimPercent` multiply at call time (no fade-in still — see "Limited fade-in/out" in "What NOT to do"). True per-frame fade-in would need a static cache + FlipScreen hook (~150 KB BSS + LOC growth) which is beyond this step's budget. Documented as accepted scope. |
| 5 | P-2 | `compute_dest_rect` may produce odd `sx`/`sy`; `(sx >> 1)` for 4:2:0 chroma rounds wrong | **Applied.** Edits C and D now `sx &= ~1` (and `sy &= ~1` for 4:2:0) before computing chroma offsets. Latent bug, no observable effect on Mania.ogv (sx=sy=0). |
| 6 | P-2 | Verification grep `grep -c "...SetupVideoTexture..."` would match function-definition lines and yield 4, not 0 | **Applied.** Success criterion #2 now uses `grep -c '\[stub\]'` (expected drop from 7 to 3) plus a separate `grep -cE` to confirm the four definition lines remain. |
| 7 | P-2 | `test -f build-p7-tel/dependencies/RSDKv5/RetroEngine` may use the wrong path | **Applied.** Both the Step 2 verify block and the single-block verification now `find build-p7-tel -name 'RetroEngine*' -type f` first, then test the conventional path. |
| 8 | P-2 | `touch Drawing.cpp` was framed as optional/defensive; CMake's implicit-dep scan for `#include "*.cpp"` is not fully trusted | **Applied.** Both verification blocks now state the `touch` is REQUIRED, with a comment explaining why. |

No findings declined.
