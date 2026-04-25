# Sonic Mania on MiSTer — Port Plan

**Document date:** 2026-04-24
**Status:** Pre-implementation. Decisions below are baked in; phases below are actionable.
**Companion doc:** [mister-port-research.md](mister-port-research.md) — architectural facts and citations. Read that first for *why* each piece of the plan exists.

---

## Decisions (baked in)

| # | Decision | Value |
|---|---|---|
| 1 | Internal / scanout resolution | **4:3 at 320×240.** Not widescreen. Height 240 is engine-locked; `videoSettings.pixWidth` set to 320. |
| 2 | FPGA core relationship to 3sx | **Separate core**, heavily derived from `3S-ARM`. Fork, rename, reparameterize modeline. |
| 3 | RSDKv5 platform identity | **Treat as `RETRO_LINUX`.** Our backend is selected via a separate `RETRO_RENDERDEVICE_MISTER` flag. Zero upstream patches to `RetroEngine.hpp`'s platform detection chain. |
| 4 | Game binary shape | **`GAME_STATIC=ON`.** Single executable, no runtime `libGame.so`. |
| 5 | Cutscenes (libtheora YUV→RGB) | ~~Stub `LoadVideo`/`ProcessVideo` for now.~~ **Resolved in Phase 7 Step 7** (`docs/phase-7-step-7-plan.md`): real CPU YUV→RGB565 + RGBA→RGB565 in `MiSTerRenderDevice.cpp`. Mac-host build shipped; live-hardware playback test pending. |
| 6 | Remote repo | **Local-only for now.** Directory name is `~/Developer/sonic-mania-mister`. No GitHub push until it works. |
| 7 | Core filename | **`Sonic Mania.rbf`** (with space) preferred; `SonicMania.rbf` acceptable fallback if the build system fights the space. |
| 8 | Build flavor strategy | **Mirror 3sx's `telemetry` / `clean` split.** Always build `telemetry` during dev (per feedback memory). |

### Known consequence of decision #1 (4:3)

Mania's native widescreen HUD and some cutscene framing assume `pixWidth >= ~400`. At 320, some UI elements (act cards, transitions) will be cropped or misplaced. This is cosmetic, not game-breaking. Worth noting, not a blocker; 4:3 matches the target hardware (CRT-oriented users) and is consistent with the arcade-aesthetic posture of the 3sx sibling project.

---

## Architecture split: two tracks

The work divides into two tracks that progress independently for most phases:

- **Track L (Linux-userland):** engine + game + MiSTer render backend + build pipeline. Gets to 80% done without any FPGA RTL changes.
- **Track F (FPGA / RTL):** pixel reader, VTG, PLL parameterized for 320×240 modeline, wrapper HPS binary. Gates *visible output* but not the Linux build. Requires Quartus time in colima VM.

Phases 0–3 and 6 are Track L. Phase 4 is Track F. Phase 5 merges them.

---

## Phase 0 — Cross-compile plumbing (Track L)

**Goal:** armhf `RSDKv5U` binary built cleanly, runnable on MiSTer HPS.

| Task | Source | Notes |
|---|---|---|
| Docker image: clang-20 + armhf sysroot | direct copy from 3sx | Known-good toolchain |
| armhf sysroot deps: libogg, libtheora, sdl2, libstdc++ | adapt | libtheora/libogg are **new** vs 3sx; see risk below |
| `tools/mister/build-game.sh` (game build driver) | adapt from 3sx | Flags: `-DPLATFORM=MiSTer -DGAME_STATIC=ON -DRETRO_SUBSYSTEM=SDL2 -DUSE_SDL_AUDIO=ON -DRETRO_DISABLE_PLUS=ON` |
| `tools/mister/build-hps.sh` (wrapper binary) | defer to Phase 4 | Wrapper belongs with FPGA work |
| Deploy script over SSH | direct copy | `reference-mister-credentials`: 192.168.1.188, MISTER_PASSWORD=1 |

**Exit criteria:**
- `file build/mister/RSDKv5U` → `ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked, ...`
- SCP to MiSTer, run via SSH. Logs hello, exits cleanly on missing `Data.rsdk`.

**Risk — libogg/libtheora on armhf clang-20:** Known from upstream issue #167 that libogg linkage has been a pain point on ARM Linux. We're pre-committed to stub cutscenes (decision #5), so `LoadVideo`/`ProcessVideo` in `Video.cpp:196-286` can be `#ifdef`'d out entirely — but libogg may still be pulled in by the vorbis audio path (stb_vorbis). Verify at configure time.

---

## Phase 1 — Skeleton MiSTer backend

**Goal:** backend compiles, links, logs init/shutdown. No pixels yet.

### New files

```
dependencies/RSDKv5/platforms/MiSTer.cmake
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/
    MiSTerRenderDevice.hpp                    # ~60 LOC
    MiSTerRenderDevice.cpp                    # ~50 LOC (stubs only in this phase)
```

### Upstream patches (all minimal, guarded)

```
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:245-257    # +4 lines: #elif RETRO_RENDERDEVICE_MISTER
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:133-146    # +4 lines: matching include chain
```

### MiSTer.cmake should

- Mirror `Linux.cmake`'s pkg-config pattern but use our cross-sysroot paths
- Carry forward the `_STATIC_LIBRARY_DIRS` fix we added in `Darwin.cmake` (avoid linker path gaps)
- Add our `Graphics/MiSTer/*.cpp` sources
- Set `-DRETRO_RENDERDEVICE_MISTER=1`
- Set conservative ARMv7 hard-float / NEON flags (mirror 3sx's `ENABLE_MISTER_ARM_HARDENING`)

### Render device stub interface

Implement all methods per research doc §2.6. For this phase, every method just logs its name and returns success. No real work yet.

**Exit criteria:** armhf binary deployed to MiSTer, runs, MiSTerRenderDevice logs `Init()`, `SetupRendering()`, `InitGraphicsAPI()`, etc. Engine reaches "reading Data.rsdk" point and exits.

---

## Phase 2 — Native video writer (Linux side)

**Goal:** RGB565 frames land in DDR3. Verifiable from MiSTer shell without FPGA pixel reader.

### New files

```
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/
    NativeVideoWriter.h     # direct copy from 3sx, dims reparameterized
    NativeVideoWriter.c
```

### Parameter changes from 3sx

| Constant | 3sx value | Mania value |
|---|---|---|
| `NV_FRAME_WIDTH` | 384 | **320** |
| `NV_FRAME_HEIGHT` | 224 | **240** |
| `NV_FRAME_BYTES` | 172,032 | **153,600** (320×240×2) |
| `NV_BUF1_OFFSET` | 0x0002A200 | recompute: 0x100 + 153,600 = `0x00025900` |
| `NV_DDR_REGION_SIZE` | 0x00060000 | keep 0x00060000 (ample margin for two 154 KB buffers + control/feedback words) |
| `NV_DDR_PHYS_BASE` | 0x3A000000 | same (MiSTer memory-map contract) |

All other structure identical: control word `[1:0]=active_buf, [31:2]=frame_counter`; feedback word at offset 0x40 same layout; `/dev/mem` + `O_SYNC` + `MAP_SHARED`.

### Engine-side config

- Set `videoSettings.pixWidth = 320` at engine init (the engine default is 424). Needs a hook in `MiSTerRenderDevice::Init` or at `SetupRendering`.
- `SCREEN_YSIZE = 240` is compile-time locked in `RetroEngine.hpp:154-155` — no change needed.
- The engine renders at 320×240 RGB565 directly into `ScreenInfo.frameBuffer`. No conversion.

### `MiSTerRenderDevice::CopyFrameBuffer` implementation

Roughly 30 LOC:

```c
// pseudocode
void CopyFrameBuffer() {
    NativeVideoWriter_WriteFrame(
        screens[0].frameBuffer,    // already RGB565
        videoSettings.pixWidth,    // 320
        SCREEN_YSIZE,              // 240
        videoSettings.pixWidth * 2 // contiguous, no padding
    );
}
```

### `MiSTerRenderDevice::FlipScreen` implementation

In the 3sx design, the flip happens inside `WriteFrame` (via the control-word update). For Mania we can keep `FlipScreen` as a thin wrapper that triggers the write, or put the write directly in `FlipScreen` and let `CopyFrameBuffer` be a no-op. Decision deferred to implementation time — both are ~20 LOC.

### Fallback: fbdev presenter?

3sx keeps `fbdev_presenter.c` as a safety net, but:
- Per `feedback-fbdev-not-used.md`: fbdev is *not* used on MiSTer in practice. Don't build the fbdev path.
- Per `feedback-rmlui-render-target.md`: MiSTer overlay draw target is the native-video-writer canvas directly.

**Skip fbdev entirely.** Native writer is the only Linux-side output path.

**Exit criteria:** on MiSTer, using `devmem2` or similar, dump `0x3A000100` while the binary runs — observe RGB565 data changing between frames. No visible output yet (no FPGA pixel reader).

---

## Phase 3 — Audio + input

**Goal:** sound plays, gamepad input reaches the game. Still no pixels.

| Task | Source | Notes |
|---|---|---|
| `USE_SDL_AUDIO=ON` passthrough in MiSTer.cmake | mirror Linux.cmake:87-95 | Routes engine audio through SDL2 → ALSA |
| SDL2 gamepad/keyboard | upstream default | Engine's `Input.cpp` via SDL2 backend path |
| Deployment + smoke logs | new | Log SDL gamepad events to confirm input pipeline |

**Deferred to Phase 7:** MiSTer wrapper-SHM input (`/dev/shm/thirdsarm-joy` pattern) for OSD-driven menus.

**Exit criteria:** SSH into MiSTer, launch binary with stubbed video, hear title music, see SDL gamepad events in log output.

---

## Phase 4 — FPGA core (Track F)

**Goal:** a `Sonic Mania.rbf` MiSTer core that reads from the DDR3 buffer and scans out 320×240 video.

This is the biggest single chunk and needs Quartus time in the colima VM. Decoupled from Track L — Phases 0–3 can be fully done before we start this, or progress in parallel.

### Approach: fork `3S-ARM`

Per decision #2: start from the `3S-ARM` core as baseline. Fork into a new Quartus project `Sonic_Mania` (underscore to match Quartus conventions; final RBF filename is `Sonic Mania.rbf`). The pixel-reader / VTG / PLL structure is identical; only modeline math and region size change.

### Parameter changes

| Module | 3sx setting | Mania setting |
|---|---|---|
| Pixel reader burst size | 384 × 2 = 768 B/line | **320 × 2 = 640 B/line** |
| Pixel reader frame bytes | 172,032 | **153,600** |
| Buffer 1 offset | 0x0002A200 | **0x00025900** |
| Video Timing Generator H total/active | CPS3 modeline | **320×240 @ 60 Hz** — exact H/V totals TBD (classic 4:3 CRT-friendly values) |
| PLL pixel clock | 8.0645 MHz (CPS3 native) | **~6.0–6.3 MHz** for 320×240@60 Hz (modeline math TBD) |
| `vga_scaler=0` requirement | yes | same |

### Wrapper HPS binary

Adapt `vendor/Main_MiSTer/thirdsarm_wrapper.cpp`:
- Rename to something like `sonicmania_wrapper.cpp` or `smania_wrapper.cpp`
- Change launch-contract paths (expects `Sonic Mania.rbf`, writes to `/dev/shm/...` under a new name)
- Core configuration routines (DDR3 region allocation, `vga_scaler=0` enforcement) stay the same

Wrapper binary name: `MiSTer_SonicMania` or similar. Follows 3sx's pattern.

### `.ini` contract (user-facing)

Required `MiSTer.ini` section:

```ini
[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0
```

Document in a new `docs/mister-wrapper.md` mirroring 3sx's version.

### Quartus build posture

- Per `feedback-quartus-nohup.md`: use nohup always
- Per `feedback-quartus-fast-build.md`: `--fast` flag always during dev (2+ hours regular vs faster)
- Per `feedback-quartus-process-mgmt.md`: verify launch before retrying; never kill mid-build

### Core repo layout

FPGA source lives in the colima VM (per 3sx convention, `reference-quartus-build-env.md`). Wrapper source (`sonicmania_wrapper.cpp`) lives in this repo under `vendor/Main_MiSTer/` following 3sx's layout — even though we'll just treat it as a local mirror for now.

**Exit criteria:** `Sonic Mania.rbf` loaded on MiSTer, binary running, 320×240 video visible on HDMI/CRT, stable sync, correct 4:3 aspect. CRT users: S-Video in color (not grayscale), confirming `vga_scaler=0` path.

---

## Phase 5 — End-to-end smoke test

**Goal:** play Green Hill Zone Act 1.

| Step | What |
|---|---|
| Asset path | User provides `Data.rsdk` → `/media/fat/games/Sonic Mania/Data.rsdk` (TBD) |
| Launch path | MiSTer menu → _Other → Sonic Mania → wrapper → RBF loads → HPS binary spawns → engine reads Data.rsdk → title screen |
| Gameplay | Title → Save Select → Mania Mode → Green Hill → Act 1 |

**Exit criteria:** observable gameplay on monitor; audio synced; input responsive; survives 10 minutes without crash. FPS may be sub-60 at this point; don't block on perf here.

---

## Phase 6 — Performance + frame pacing

**Goal:** sustained 60 fps on representative stages.

| Task | Source | Notes |
|---|---|---|
| Vsync feedback loop (DDR3 feedback word read) | direct copy from 3sx `sdl_app.c:9534-9580` | `NativeVideoWriter_ReadFeedback{,Seq}` already present from Phase 2 |
| FPS overlay | adapt from 3sx `show-fps` | Per `feedback-headless-perf-unreliable.md`: only show-fps overlay gives honest numbers |
| ARMv7 hardening flags | direct copy from 3sx | `-mfpu=neon -mfloat-abi=hard -march=armv7-a` etc. |
| Profile rasterizer hot paths | new | `Drawing.cpp` sprite/tile loops are the prime suspects |

**Risk — UNVERIFIED:** whether A9 @ 800 MHz can sustain Mania's software rasterizer at 60 fps at 320×240. Pixel count is 18% *less* than 3sx's 384×224 and Mania's per-frame game logic is lighter than 3rd Strike's. Expectation: comfortable headroom. If not:
- (a) overclock guidance (1.0+ GHz is documented for 3sx)
- (b) 30 fps fallback mode
- (c) NEON hotspot optimization

None of these are showstoppers.

**Exit criteria:** 60 fps sustained on Green Hill (low complexity), Studiopolis (high sprite count), Titanic Monarch (3D bonus bits). Vsync phase error oscillates near zero.

---

## Phase 7 — Polish

| Task | Priority | Notes |
|---|---|---|
| Cutscene support: CPU YUV→RGB565 | low | Revisit decision #5. Only if libtheora armhf build is clean. ~80 LOC. Attract-mode only. |
| Wrapper SHM input | low | `/dev/shm/...` pattern from 3sx `vendor/Main_MiSTer/mister_joy_shm.h` |
| `docs/mister-wrapper.md` | medium | INI contract, launch flow |
| Release packaging | medium | Per `feedback-release-readme-path.md`: canonical README at `tools/mister/release-readme.txt` |
| `tools/mister/build-game.sh --flavor telemetry` | medium | Default flavor per `feedback-always-telemetry.md` |
| Save-game path | medium | Mania writes saves relative to exec; route to `~/.local/share/...` or equivalent MiSTer path |
| Debug/telemetry overlay | optional | Strip for `clean` flavor |

---

## Phase 8 — Deferred

Not in scope for first working build:

- Mod loader ecosystem (leave `RETRO_MOD_LOADER=ON` as upstream default; don't build distribution story)
- Widescreen 424×240 as runtime-selectable alternate modeline
- Netplay / rollback (Mania has no hooks; don't chase)
- Upstream contributions (license is non-commercial; keep patches in our fork)

---

## Cross-cutting

### What carries from 3sx verbatim

- `native_video_writer.{h,c}` core (dims reparameterized only)
- Docker + clang-20 toolchain
- Deploy scripts, SSH workflow
- Vsync feedback protocol
- Wrapper HPS binary template
- Frame-pacing logic
- Flavor split (`telemetry` / `clean`)
- ARMv7 hardening flags

### What's genuinely new

- `MiSTerRenderDevice.{cpp,hpp}` (~360 LOC)
- FPGA pixel reader / VTG / PLL parameters for 320×240 modeline
- Two-repo engine+game build glue (3sx is monolithic; Mania splits)
- `Darwin.cmake` for dev builds (already done)

### What we avoid

- fbdev presenter (per `feedback-fbdev-not-used.md`)
- Netplay integration
- Upstream platform-ID patches (decision #3)
- Cutscene support on first pass (decision #5)

---

## Proposed order of work

**Sequential within Track L:**
Phase 0 → Phase 1 → Phase 2 → Phase 3

**Parallel start-up for Track F:**
Phase 4 can begin as soon as Phase 0 confirms the Linux-side shape is healthy. Quartus builds are slow (2+ hours per iteration); start early.

**Convergence:**
Phase 5 merges both tracks.

**Harden:**
Phase 6 (perf) → Phase 7 (polish).

### Rough effort estimate

| Phase | Effort (sessions) | Gated by |
|---|---|---|
| 0 — Cross-compile plumbing | 1–2 | libogg/libtheora armhf build |
| 1 — Skeleton backend | 1 | — |
| 2 — Native video writer | 1 | Phase 1 |
| 3 — Audio + input | 1 | Phase 2 for build flow; otherwise independent |
| 4 — FPGA core | 2–4 | Quartus build cycles |
| 5 — Smoke test | 1 | Both tracks |
| 6 — Perf | 1–2 | Phase 5 |
| 7 — Polish | 1–2 | Phase 5 |

Track L first pass realistically: 3–5 focused sessions. Track F is wall-clock-bound by Quartus. Phase 5+ depends on integration quality.

---

## Success criteria for v0.1.0

When we can:

1. Run `tools/mister/build-game.sh --flavor telemetry` on a dev box and produce a clean armhf binary
2. Run a Quartus build and produce `Sonic Mania.rbf`
3. SCP both to MiSTer, run from the menu with a user-supplied `Data.rsdk`
4. Boot Mania, play Green Hill Act 1 to completion
5. See color S-Video on CRT (if user has one)
6. Sustain 60 fps on that act

That's v0.1.0. Everything else is polish.

---

## References

- **Research doc:** [mister-port-research.md](mister-port-research.md)
- **3sx-mister tree:** `/Users/sb/Developer/3sx-mister/`
- **3sx docs to mirror or adapt:**
  - `docs/mister-runbook.md` — canonical build/deploy flow
  - `docs/mister-wrapper.md` — INI contract, launch flow
  - `docs/spec-fpga-native-video.md` — modeline math, PLL parameters, Verilog module specs
  - `docs/design-fpga-native-video.md` — design rationale
- **Upstream Mania/RSDKv5:**
  - Engine: [github.com/RSDKModding/RSDKv5-Decompilation](https://github.com/RSDKModding/RSDKv5-Decompilation)
  - Game: [github.com/RSDKModding/Sonic-Mania-Decompilation](https://github.com/RSDKModding/Sonic-Mania-Decompilation)
  - Issue #167 (ARM Linux build pains): [github.com/RSDKModding/RSDKv5-Decompilation/issues/167](https://github.com/RSDKModding/RSDKv5-Decompilation/issues/167)
