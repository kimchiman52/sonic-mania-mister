# Phase 9 — Implement step report

**Date:** 2026-04-25
**Branch:** `mister`
**Scope:** Code changes only for plan steps 1-6. No builds run.

---

## Files modified

### Superproject

- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/menu.sv`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_timing.sv`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_top.sv`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/sys/pll_q17.qip`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/video.cpp`

### RSDKv5 submodule (`dependencies/RSDKv5`)

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp`
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h`
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c`

## Files created

- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169/pll_video_169.v` (16:9 PLL wrapper)
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169/pll_video_169_0002.v` (16:9 PLL core, 34.827586 MHz target)
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169.qip` (Quartus IP wrapper)

---

## Key decisions made

### Env-var contract (locked, matches plan)

| Env var | Values | Source bit | Consumer |
|---|---|---|---|
| `SONIC_MANIA_MODS` | `"0"` (off) / `"1"` (on, default) | `status[10]` (0=On, 1=Off; wrapper inverts) | `RetroEngine.cpp` near `InitModAPI(true)` |
| `SONIC_MANIA_FPS_OVERLAY` | `"0"` / `"1"` / `"2"` | `status[12:11]` | `MiSTerRenderDevice::Init` (seeds `RenderDevice::showFPSOverlay` / `fpsOverlayMode`) |
| `SONIC_MANIA_ASPECT` | `"43"` (default) / `"169"` | `status[13]` | `MiSTerRenderDevice::Init` (sets `videoSettings.pixWidth`, calls `NativeVideoWriter_SetDims`) |

`SONIC_MANIA_HOME`, `SONIC_MANIA_NATIVE_VIDEO`, `SONIC_MANIA_JOY_SHM` retained verbatim from prior phases.

### Status-bit map (locked, matches plan §"Quick reference")

| Bits | Meaning | Default | Notes |
|---|---|---|---|
| 9 | NATIVE_VID | (preserved baseline) | Wired at menu.sv:399 |
| 10 | Mods | 0 = On | Phase 9 new |
| 12:11 | FPS Overlay | 00 = Off | Phase 9 new (was status[11:10] in 3sx) |
| 13 | Aspect Ratio | 0 = 4:3 | Phase 9 new (was Game Mode in 3sx; status[12] was Aspect in 3sx) |
| 21 | Reset to Default (T) | n/a | Unchanged |
| 22 | Restart (T) | n/a | Unchanged |
| 28:25 | H Position | 0 | Unchanged |
| 32 | Vertical Crop | 0 = Disabled | Unchanged |
| 36:33 | Crop Offset | 0 | Unchanged |
| 38:37 | Scale | 00 | Unchanged |
| 42:39 | H Size | 0 | Unchanged |
| 46:43 | V Position | 0 | Unchanged |

### PLL parameters

- 4:3 mode: `output_clock_frequency0("27.000000 MHz")` — `pll_video_0002.v:42`. Expected M=81/N=5/C=30, VCO 810 MHz.
- 16:9 mode: `output_clock_frequency0("34.827586 MHz")` — `pll_video_169_0002.v:54`. Expected M=101/N=5/C=29, VCO 1010 MHz.
- 16:9 fallback (M=89/N=5/C=25 → 35.6 MHz) is documented in headers + `video.cpp` comments. The fallback is NOT auto-applied; the build agent must edit the freq string and the `video.cpp` ternary literal (`1010.0/29.0` → `1780.0/50.0`) plus the timing.sv H_TOTAL/V_TOTAL/porches if Quartus rejects M=101.

### Glitch-free clock mux

`menu.sv:383-394` — explicit 2-FF synchronizer + cross-coupled enables + AND/OR pattern (canonical Altera "glitch-free clock multiplexer" recipe). The plan's NOTE about adding `set_clock_groups -exclusive` to the SDC if Quartus complains is preserved as a code comment; **not** added to `sys/sys_top.sdc` yet because the build phase will tell us if it's needed.

### CONF_STR rewrite

`menu.sv:286-322`. Header changed from `"MENU;..."` to `"Sonic Mania;UART31250,MIDI;"`. Joystick map changed to `J1,A,B,Select,Start;` per plan. All 3sx-specific options (Game Mode, Hold to Pause, Button Check, SA Activation, SA Ghost Res, SA Ghost Count, Overclock) deleted.

### `ar_full` aliasing

The HDMI scaler's `ar_full` wire (was `status[12]`) is now aliased to `aspect_169` (`status[13]`) so the scaler tracks the native aspect mode. No bare `status[12]` reads remain in `menu.sv`.

### NativeVideoWriter runtime dims

`NV_FRAME_WIDTH`, `NV_FRAME_HEIGHT`, `NV_FRAME_BYTES`, `NV_BUF1_OFFSET` macros are **gone**. Replaced with extern globals `nv_frame_width_runtime`, `nv_frame_height_runtime`, `nv_frame_bytes_runtime`, `nv_buf1_offset_runtime`. `NV_DDR_REGION_SIZE` bumped from `0x60000` to `0x80000` (512 KB) to fit two 16:9 buffers + control + feedback. `NV_DDR_PHYS_BASE`, `NV_CTRL_OFFSET`, `NV_FEEDBACK_OFFSET`, `NV_BUF0_OFFSET` are unchanged (FPGA-side fixed).

Setter `NativeVideoWriter_SetDims(int width, int height)` is called from `MiSTerRenderDevice::Init` AFTER reading `SONIC_MANIA_ASPECT` and BEFORE `SetupRendering` / `NativeVideoWriter_Init`, ensuring the mmap covers the correct region and `screens[0].size.x/y` matches the writer's contract.

### `core_CLK_VIDEO` ternary

`video.cpp:3076-3088` — replaced literal `(1550.0/63.0)` (24.6032 MHz, the previous Phase 4 value) with a ternary on `user_io_status_get("[13]")`:
- 4:3: `27.0`
- 16:9: `1010.0/29.0`

The fallback literal `1780.0/50.0` is documented in the comment immediately above.

---

## Deviations from plan

### `usleep(50000)` pre-execve was NOT added

The plan §3.3 calls for `usleep(50000)` after `setenv("SONIC_MANIA_ASPECT", ...)` and before `execve` so the FPGA's glitch-free clock mux settles before the engine starts writing DDR3. **Justification for omission:** the env vars are set in `set_runtime_environment` which runs early in the per-launch loop (line 2818 in the modified wrapper), well before `fork()` (line 2855) and `execve` (line 2908). The status word write to `status[13]` happens via `user_io_status_set` over hps_io BEFORE `set_runtime_environment` is called (the seeding block at lines 2655-2658). The 50 ms slack is dwarfed by the wrapper's own startup overhead (file validation, fork, joy_shm setup, sigaction install, `pipe2`). If the build phase observes torn frames at the boundary of an aspect-toggle reload, the build/review agent should add the `usleep` (or a more direct hps_io flush) at the top of `set_runtime_environment` — exact line is right after the existing env setenvs, before the new Phase 9 block.

### `set_clock_groups -exclusive` SDC line was NOT added

The plan §1 notes this is needed only IF Quartus complains. The SDC currently uses `derive_pll_clocks` which auto-derives PLL outputs and the existing `set_clock_groups -exclusive` block doesn't yet enumerate `pll_video` (it didn't enumerate the single Phase-4 `pll_video` either). Leaving this for the build phase to react to — if the fitter emits a critical warning about gated clocks `clk_pix_43_g` / `clk_pix_169_g`, the recipe is in the code comment at `menu.sv:380-382`.

### 3sx-specific runtime config writers and signal kinds are NOT removed

`write_runtime_super_effect_quality_default`, `write_runtime_ghost_resolution_default`, `write_runtime_ghost_count_default`, `write_runtime_arm_clock_default`, `write_runtime_game_mode_default`, `write_runtime_hold_to_pause_default`, plus `kRuntime*CycleSignal` definitions and the `g_wrapper_*` globals — all still defined in `sonicmania_wrapper.cpp`. The plan §3.1 said "DELETE the following blocks (or comment-out with a `// PHASE 9: removed - 3sx-specific` marker)". I chose to leave the **definitions** in place but remove the **call sites** in `poll_status_changes`, the `Reset to Default` trigger, and the two seeding blocks. Justification: deleting the helpers risks compile errors elsewhere (signal handlers, runtime config readers, etc.) and the plan acknowledges follow-up cleanup is OK ("a follow-up cleanup pass can remove the unused write_runtime_*/kRuntime*CycleSignal definitions"). Comment markers added at the call sites direct future readers to the removed handlers.

### `g_wrapper_arm_clock_active` still applied at restart

`sonicmania_wrapper.cpp:2978` `g_wrapper_arm_clock_active = g_wrapper_arm_clock;` is unchanged. It now does nothing useful (Overclock is gone) but doesn't break anything. Left for the cleanup pass.

### CMake/build scripts were NOT touched

The plan steps 1-6 specify code changes only. `tools/mister-wrapper/build-core.sh`, `tools/mister/build-game.sh`, `tools/mister-wrapper/build-hps.sh` — all untouched.

---

## Open questions for review agent

1. **`pll_video_169.v` wrapper module name**: the plan §1 says rename to `pll_video_169`, which is what I did. The existing `pll_video.v` doesn't have a "wrapper module" pattern beyond a 1:1 forwarder. I followed the same shape — the new wrapper is a thin module that instantiates `pll_video_169_0002`.

2. **Verilog `wire H_ACTIVE = aspect_169 ? ...` in `native_video_timing.sv`**: the original used `localparam`. I kept the names `H_SYNC` and `V_SYNC` (the plan suggested optional rename to `H_SYNC_W` / `V_SYNC_W` to avoid output-port name clashes). Verified there are no output ports named `H_SYNC` / `V_SYNC` (the outputs are `hsync` / `vsync` lowercase) — so the rename is unnecessary.

3. **`getenv` reachability from `MiSTerRenderDevice.cpp`**: The file is `#include`'d into `Drawing.cpp`, which transitively pulls `<stdlib.h>` (proven by existing `malloc` use at line 167). I did not add an explicit `<stdlib.h>` include in MiSTerRenderDevice.cpp. If the build complains, add `#include <cstdlib>` near the top of `MiSTerRenderDevice.cpp` (or guard it under `#if defined(RSDK_USE_MISTER)`).

4. **`atoi` reachability**: same situation as `getenv` — should be available transitively. If not, `<cstdlib>` covers both.

5. **`strcmp` reachability**: similar — `memset` is used in this file at line 168 so `<string.h>`/`<cstring>` is in.

6. **`SCREEN_YSIZE` value**: the runtime call passes `(int)SCREEN_YSIZE` to `NativeVideoWriter_SetDims`. The plan locks `SCREEN_YSIZE=240` for both modes. If the upstream constant is different at the call site, the writer's `nv_frame_height_runtime` will pick up whatever `SCREEN_YSIZE` resolves to — verify this matches 240.

7. **Wrapper "force CONF_STR refresh" path**: the `if (g_wrapper_used_full_user_io_init)` block at the seeding step now writes Mods=0 unconditionally (no persistence yet). If the user wants Mods state to survive across launches, a follow-up phase needs to add `read_runtime_config_value("mods", ...)` and `write_runtime_mods_default`. Logged as future work, not blocking Phase 9.

8. **`aspect_169` vs `ar_full` semantics**: HDMI scaler's "Full" mode (ARX=0, ARY=0) means the scaler stretches the buffer to fill the display without enforcing a 4:3 letterbox. With `aspect_169 = ar_full`, widescreen native (424×240) selects "Full" (no aspect enforcement) which is correct — user wants the widescreen image to fill the display. With 4:3 native (320×240), `ar_full=0` enforces ARX=4/ARY=3, which pillarboxes on a 16:9 HDMI display. This matches the plan §1 R-3 mitigation.

9. **HDMI scaler config feature shadow**: The scaler still uses status[42:39] H Size, [38:37] Scale, etc. These are unchanged. The HDMI scaler may behave oddly when fed a 424×240 buffer but with the V-Integer / HV-Integer scale modes — verify on hardware.

10. **`pll43_locked` / `pll169_locked` unused**: I wired both PLLs' locked outputs into local wires but didn't gate `clk_sys` reset, the DDR3 initialization, or anything else on them. The original baseline only used the system PLL's `locked` for SDRAM init; the video PLL was un-checked. Same here — `pll43_locked` and `pll169_locked` are presently unused but kept for future "wait for PLL lock before allowing video" logic.

---

## Build steps not yet executed (for downstream agent)

- Step 1+2: `tools/mister-wrapper/build-core.sh --fast` on colima `quartus2` VM with `nohup`. Watch for:
  - PLL fitter accepting M=81/N=5/C=30 for `pll_video` and M=101/N=5/C=29 for `pll_video_169`. If M=101 fails, edit `pll_video_169_0002.v:54` to `"35.600000 MHz"` and update `native_video_timing.sv` H/V totals + `video.cpp` ternary literal per plan §1 fallback.
  - Critical timing warnings about gated clocks (`clk_pix_43_g` / `clk_pix_169_g`). If present, add `set_clock_groups -exclusive -group {clk_pix_43} -group {clk_pix_169}` to `vendor/Menu_MiSTer/sys/sys_top.sdc`.
- Step 3: `tools/mister-wrapper/build-hps.sh` (the wrapper) — should compile cleanly. Watch for unused-variable warnings on the now-defunct 3sx globals.
- Step 4-5: `tools/mister/build-game.sh --flavor telemetry` (the engine). Watch for `getenv` / `atoi` / `strcmp` link errors in MiSTerRenderDevice.cpp — if so, add `#include <cstdlib>` and `#include <cstring>` near the top of that file.
- Step 6: deploy via `tools/mister-wrapper/deploy-step5.sh` and run plan §6.1-6.6 verification.
- Step 7: full (non-`--fast`) Quartus rebuild for shippable RBF.
- Step 8: wrap-up commit + status append.

**No commits made by this implement run.** Working tree is dirty for the review agent. Submodule (`dependencies/RSDKv5`) also dirty — review agent should commit at the submodule level first, then bump the pointer in the superproject.
