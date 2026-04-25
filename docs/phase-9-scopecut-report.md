# Phase 9 Scope Cut Report

**Date:** 2026-04-25
**Branch:** `mister`
**Trigger:** Cyclone V architectural constraint discovered at Quartus build time.
**Status:** Phase 9 ships as 4:3-only with NTSC-exact retune; 16:9 widescreen
deferred to Phase 10.

---

## Why we cut

Phase 9 originally locked in dual-aspect (4:3 + 16:9 widescreen) via a static
two-PLL + glitch-free clock-mux topology. We hit a hard Cyclone V constraint at
Quartus build time:

> **Error (15836):** `inclk[3]` port of Clock Select Block `hdmi_clk_sw` is
> driven by `<some logic chain>`, but must be driven by a PLL's output clock.

`sys_top.v`'s `hdmi_clk_sw` and `vga_clk_sw` are clock-select blocks that
require their `inclk` (where emu's `CLK_VIDEO` connects) to come **directly
from a clock pin or a PLL CLK output** — neither a combinational AND/OR mux
NOR a cascaded `altclkctrl` IP is accepted. We tried both. Both fail.

The only path to runtime aspect switching on Cyclone V is `altpll_reconfig`
(dynamic PLL coefficient reconfig via Avalon-MM): a 100+ LOC state machine
plus IP wizard config plus reset-domain handshake. Doing that correctly
overnight isn't realistic. Documented as Phase 10.

## What we kept

1. **NTSC-exact 4:3 modeline retune** (kept):
   - `pll_video`: M=81 / N=5 / C=30 → 27.000 MHz CLK_VIDEO / 6.750 MHz pixel
   - H/V totals 429×262 → 60.07 Hz, 15,734 Hz H-freq (NTSC-exact)
   - This is the CRT overscan fix the user asked for.
2. **CONF_STR rewrite minus Aspect Ratio** (kept): Sonic Mania header,
   joystick map A/B/Select/Start, Mods toggle, FPS Overlay (Off/Simple/
   Detailed), HDMI scaler controls (H Size, H Position, V Position, Vertical
   Crop, Crop Offset, Scale, Reset to Default, Restart). 3sx-specific
   options (Game Mode, Hold to Pause, Button Check, SA *, Overclock) gone.
3. **Wrapper env emission** for Mods + FPS Overlay (kept):
   `SONIC_MANIA_MODS`, `SONIC_MANIA_FPS_OVERLAY`. `SONIC_MANIA_ASPECT` removed.
4. **Engine env reads** for Mods + FPS Overlay (kept).
5. **Phase 9 status bit indices** (kept): Mods=status[10],
   FPS Overlay=status[12:11]. status[13] is RESERVED for future Phase 10
   Aspect Ratio (DO NOT REUSE).
6. **NV runtime dims infrastructure** (kept): `NativeVideoWriter_SetDims(W, H)`
   at engine startup. Always called as `(320, SCREEN_YSIZE)` for now.
   Plumbing makes Phase 10 easier when 16:9 path lands.
7. **`NV_DDR_REGION_SIZE` bump 0x60000 → 0x80000** (kept): headroom is fine
   and future-proofs the layout for Phase 10's 16:9 buffers (203,520 B each).

## What we reverted

| File | Action |
|---|---|
| `vendor/Menu_MiSTer/menu.sv` | Replaced dual-PLL+altclkctrl block with single `pll_video pll_vid` instantiation (matches pre-Phase-9 wiring + retuned 27.0 MHz PLL). Dropped `aspect_169`/`pll43_locked`/`pll169_locked`/`clk_pix_43`/`clk_pix_169`/`clkmux_pix`. Hardwired `ar_full = 1'b0` for 4:3 letterboxing. Dropped `O[13],Aspect Ratio,...` from CONF_STR; left status[13] as RESERVED-for-Phase-10 comment. Updated CE_PIXEL/clock-section comment blocks. |
| `vendor/Menu_MiSTer/rtl/native_video_timing.sv` | Removed `aspect_169` input; H/V totals + porches restored as 4:3-only `localparam`s (H_TOTAL=429, V_TOTAL=262). |
| `vendor/Menu_MiSTer/rtl/native_video_reader.sv` | Removed `aspect_169` input; BUF1_ADDR / LINE_BURST / LINE_STRIDE restored as 4:3-only `localparam`s. dcfifo header + CDC comments updated to single-mode. |
| `vendor/Menu_MiSTer/rtl/native_video_top.sv` | Removed `aspect_169` pass-through. Updated header + CDC comments. |
| `vendor/Menu_MiSTer/rtl/pll_video_169/` | DELETED (directory + 2 .v files) |
| `vendor/Menu_MiSTer/rtl/pll_video_169.qip` | DELETED |
| `vendor/Menu_MiSTer/sys/pll_q17.qip` | Removed the `pll_video_169.qip` line. |
| `vendor/Menu_MiSTer/sys/sys_top.sdc` | Removed the `set_clock_groups -exclusive` block for `pll_vid_43` / `pll_vid_169` (P-2.3 from fix report). |
| `vendor/Main_MiSTer/sonicmania_wrapper.cpp` | Removed `SONIC_MANIA_ASPECT` setenv; removed status[13] poll handler in `poll_status_changes`; removed `prev_aspect_ratio`; removed status[13] writes in seeding + Restart trigger + Reset-to-Default; updated "phase9: ..." log line to drop ASPECT field; removed `usleep(50000)` (no longer needed without aspect-toggle settle requirement). |
| `vendor/Main_MiSTer/video.cpp` | Reverted `core_CLK_VIDEO` ternary `aspect_169 ? (1010.0/29.0) : 27.0` back to single literal `27.0`. Updated comment block to describe NTSC-exact 4:3-only reality. |
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` | Removed `SONIC_MANIA_ASPECT` env read; hardcoded `videoSettings.pixWidth = 320`. Still calls `NativeVideoWriter_SetDims(320, SCREEN_YSIZE)`. KEPT `SONIC_MANIA_MODS`/`SONIC_MANIA_FPS_OVERLAY` reads. Updated FlipScreen + GetWindowSize comment blocks. |
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.{h,c}` | UNCHANGED (runtime-dim plumbing intentionally kept; defaults to 4:3). |

## Files NOT modified

These intentionally retain their Phase 9 state:

- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — the `<cstdlib>`
  include added at P-2.2 stays (it's portability-correct regardless of
  whether Aspect is wired).
- `vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` — the 27.000 MHz
  retune (M=81/N=5/C=30) is the modeline we want; staying as-is.
- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` — Mods env-var
  read is orthogonal to aspect.
- All Phase 9 plan/implement/review/fix docs in `docs/` — historical record.

## Phase 10 future work checklist (16:9 widescreen)

When dual-aspect is revisited:

1. Generate `pll_video_169` IP via Quartus IP Catalog with
   **`altpll_reconfig`** option enabled (NOT a static second PLL).
2. Drive the reconfig Avalon-MM port from a small state machine in
   `menu.sv` that reads the Aspect Ratio bit (status[13] reserved).
3. State machine writes new M/N/C coefficients (101/5/29 for 16:9 →
   34.8276 MHz, fallback 89/5/25 → 35.6 MHz), pulses `reset_pll`, waits
   for `pll_locked`.
4. During reconfig, blank `NATIVE_VID_ACTIVE` so the FPGA reader doesn't
   spin against an unstable clock.
5. Re-enable `aspect_169`-keyed BUF1_ADDR / LINE_BURST / LINE_STRIDE in
   `native_video_reader.sv` (the runtime-dim plumbing in
   `NativeVideoWriter.{h,c}` is already aspect-aware via SetDims).
6. Re-enable `aspect_169`-keyed H/V totals + porches in
   `native_video_timing.sv`.
7. Wrapper: re-add `SONIC_MANIA_ASPECT` setenv + status[13] poll handler +
   the `usleep(50000)` settle delay + the "phase9: ..." log-line ASPECT
   field. `g_wrapper_aspect_ratio` and `kAspectRatioFull` are still defined
   in the source; the helpers (`read_runtime_aspect_ratio_default`,
   `write_runtime_aspect_ratio_default`) are unused but compile cleanly,
   so the wrapper-side wiring is mostly already in place.
8. Engine: re-add `SONIC_MANIA_ASPECT` env read in `MiSTerRenderDevice::Init`,
   call `NativeVideoWriter_SetDims(424, SCREEN_YSIZE)` for `"169"`. The
   `nv_frame_*_runtime` globals already select buffer offsets and frame
   sizes correctly when SetDims is called with non-default dims.
9. CONF_STR: re-add `"O[13],Aspect Ratio,4:3,Widescreen;"` line.
10. SDC: figure out whether `set_clock_groups` is needed when only one
    PLL is active at a time (likely no, since `altpll_reconfig` mutates
    the same physical PLL rather than running two).
11. video.cpp: re-add the ternary on status[13] for `core_CLK_VIDEO`
    (4:3: 27.0, 16:9: 1010.0/29.0). The Phase 4/9 comment history is
    preserved in the current single-literal block.
12. Test the Restart-toggle path end-to-end: the wrapper writes status[13],
    the FPGA reconfigs the PLL, the engine re-execs and reads the new env
    var, the writer re-mmaps with the new buffer layout.

## Build artifacts

Both ARM ELFs verified by `file` post-build:

- Wrapper: `/Users/sb/Developer/sonic-mania-mister/build/mister-wrapper-hps/MiSTer_SonicMania`
  — ELF 32-bit LSB executable, ARM, EABI5 (1,026,772 B, stripped)
- Game:    `/Users/sb/Developer/sonic-mania-mister/build/mister-telemetry-install/bin/RSDKv5U`
  — ELF 32-bit LSB pie executable, ARM, EABI5 (6,632,848 B, telemetry flavor)
- Wrapper build log: `build/phase9-scopecut-wrapper-build.log`
- Game build log: `build/phase9-scopecut-game-build.log`

## Quartus build kicked off

- Host: colima `quartus2` VM, x86_64
- PID: 739415 (`quartus_sh --flow compile Sonic_Mania -c Sonic_Mania`)
- Log: `/home/sb.linux/build/sonic-mania-phase9-build.log` (on the VM)
- Exit code marker: `EXIT=<n>` line written to the log on completion
- Expected completion: 30–90 min depending on QEMU + fitter throughput
- Output target: `output_files/Sonic_Mania.rbf` (when EXIT=0)

The orchestrator will deploy after Quartus finishes. NOT done in this turn.

## What user will see when they wake up

- The mister branch has Phase 9 commits **plus** a new scope-cut commit
  reverting the dual-aspect RTL/wrapper/engine paths and documenting the
  Phase 10 follow-up. Phase 9 history (plan / implement / review / fix
  docs + commit 185f13e4) is intact.
- A fresh wrapper binary (`build/mister-wrapper-hps/MiSTer_SonicMania`)
  and a fresh game binary (`build/mister-telemetry-install/bin/RSDKv5U`),
  both ARM ELFs.
- A fresh Sonic_Mania.rbf in the colima VM's `output_files/` (assuming
  Quartus exits cleanly — verify with the EXIT line at the tail of the
  log).
- The OSD will show: Mods | FPS Overlay | (separator) | Vertical Crop |
  Crop Offset | Scale | H Size | H Position | V Position | Reset to
  Default | Restart. NO Aspect Ratio entry.
- Native video runs at 27.000 MHz, NTSC-exact 6.750 MHz pixel /
  15,734 Hz H-freq — should fix the CRT overscan that motivated this
  whole modeline retune.
- 16:9 widescreen path is dormant but can land in Phase 10 with the
  checklist above; the runtime-dim plumbing is already in place.
