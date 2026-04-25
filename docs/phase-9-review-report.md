# Phase 9 Review

## Summary
Implementation closely matches the locked plan: PLL coefficients, status-bit map, env-var contract, DDR3 memory map, and runtime-dim refactor are all correct on careful read of the actual source. Cross-checked PLL math, dual-modeline timing, glitch-free clock mux pattern, NativeVideoWriter dim flow, and the `core_CLK_VIDEO` ternary against the plan and existing reference files. **Zero P-1 findings. Six P-2 findings**, all robustness / debug-visibility / future-cleanup items the build phase can absorb without blocking the first compile.

## P-1 (Must fix — correctness/safety bugs that will break the build, the deploy, or on-device behavior)

(None.)

The two areas that looked like potential P-1s on first inspection but cleared on detailed read:

- **Dual-aspect DDR3 region size.** The task instructions warned `424×224 ARGB ×2 > 0x80000`. That math is wrong for our case: the DDR3 buffers are RGB565 (2 bytes/pixel), not ARGB, and height is 240, not 224. Verified math: 4:3 frame=153,600 B (0x25800), 16:9 frame=203,520 B (0x31B00), 16:9 BUF1+frame_bytes = 0x31C00+0x31B00 = 0x63700 = 407,296 B which fits inside the bumped 0x80000 (524,288 B) with ~117 KB headroom. `NativeVideoWriter.c:18-19` carries the same arithmetic in a comment and matches.
- **Wrapper mmap size unaffected by region bump.** `vendor/Main_MiSTer/sonicmania_wrapper.cpp:2171` only mmaps 4096 B (one page covering CTRL@0x00 and FEEDBACK@0x40), not the full pixel region. The 0x60000 → 0x80000 bump is exclusively engine-side; wrapper does not also need updating. Confirmed by grepping `0x60000|0x80000|NV_DDR_REGION` across `vendor/Main_MiSTer/`: only the comment in `vendor/Menu_MiSTer/rtl/native_video_reader.sv:25` mentions the bump.

## P-2 (Should fix — design/robustness, not blocking but high-value before commit)

### P-2.1 Wrapper plan-required log line missing
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp:1850-1860`
**Issue:** Plan §3 step 2 explicitly requires the wrapper to emit
```
phase9: SONIC_MANIA_MODS=%s SONIC_MANIA_FPS_OVERLAY=%s SONIC_MANIA_ASPECT=%s (mods_off=%u fps=%u aspect_169=%u)
```
into `wrapper_log` for on-device verification (see plan §3 "Success criteria" — log assertion is the primary 4:3 vs 16:9 boot signal). The implement report (lines 426-429) claims this log is in. **It is not.** The new `{ const uint32_t mods_off = ...; setenv(...); setenv(...); setenv(...); }` block at lines 1850-1860 sets the env vars and stops. No `write_log_line` call. The implement report's quoted code does not match the file.
**Why this is P-2 (not P-1):** The env vars themselves are correctly emitted; the engine's three new `Phase 9: SONIC_MANIA_*` PrintLog lines in `MiSTerRenderDevice.cpp:75/109` and `RetroEngine.cpp:84` will still confirm the contract end-to-end. But step 6.2/6.3 verification specifically greps the wrapper log for `SONIC_MANIA_ASPECT=43|169` to confirm the FPGA-side status bit reached the wrapper before launch.
**Fix:** `set_runtime_environment` does not take a `FILE *wrapper_log` parameter today. Two paths:
1. Add a `FILE *wrapper_log` parameter (caller at line 2765 already has it in scope) and append:
```cpp
write_log_line(wrapper_log,
    "phase9: SONIC_MANIA_MODS=%s SONIC_MANIA_FPS_OVERLAY=%s SONIC_MANIA_ASPECT=%s (mods_off=%u fps=%u aspect_169=%u)",
    getenv("SONIC_MANIA_MODS"), getenv("SONIC_MANIA_FPS_OVERLAY"),
    getenv("SONIC_MANIA_ASPECT"), mods_off, fps_overlay, aspect_169);
```
2. Or move the log emission to right after the call site at line 2765 (no signature change), reading the env vars back via `getenv`.

### P-2.2 `<cstdlib>` reachability for `getenv`/`atoi` in MiSTerRenderDevice.cpp is fragile transitive
**File:** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:69, 92, 93`
**Issue:** The file uses bare `getenv("SONIC_MANIA_ASPECT")`, `getenv("SONIC_MANIA_FPS_OVERLAY")`, and `atoi(fpso)`. The file's own header comment (lines 6-10) forbids adding `#include` directives because it is textually included from `Drawing.cpp:146`. The reachability chain to `<stdlib.h>` is:
- `Drawing.cpp:1` → `RetroEngine.hpp`
- `RetroEngine.hpp:7-10` → `<stdio.h> <string.h> <cmath> <ctime>` — none of these *standard*-mandates `<cstdlib>`.
- gcc's libstdc++ does pull `<cstdlib>` transitively from `<cmath>` in practice; clang's libc++ on Mac may not. The implement-agent report's open question #3 flagged this risk.
- The previously-used `malloc` at line 167 is in `<cstdlib>` too, and that compiles OK today on both platforms — empirical evidence that the transitive include works on the current toolchains. But it is a latent fragility.
**Why this is P-2:** Build today will succeed; a future libc++ upgrade or a flag change to `-std=c++20` strict mode could break it.
**Fix:** Add `#include <cstdlib>` (and `#include <cstring>` for `strcmp` at line 70) to `Drawing.cpp` near the top — NOT to `MiSTerRenderDevice.cpp`, which would violate the textually-included constraint.

### P-2.3 SDC missing `set_clock_groups -exclusive` for the two video PLL outputs
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/sys/sys_top.sdc:13-22`
**Issue:** The existing `set_clock_groups -exclusive` block enumerates groups for the system PLL, HDMI PLL, audio PLL, SPI, HDMI I²C, h2f bus, and the three 50 MHz inputs — but **does not enumerate `pll_video` or `pll_video_169`**. With the new dual-PLL + AND/OR clock mux pattern in `menu.sv:386-397`, Quartus's `derive_pll_clocks` will create two generated clocks (one per PLL) that share fanout into `clk_pix`. Without the `-exclusive` constraint, the timing analyzer will treat them as related and emit cross-domain timing checks between `clk_pix_43_g` and `clk_pix_169_g` that cannot meet (they are physically unrelated at different rates).
**Why this is P-2 (not P-1):** Plan §1 explicitly defers this to the build phase: "DO NOT add `set_clock_groups -exclusive` to the SDC unless Quartus emits a critical warning that requires it." The implement agent followed the plan. The build will likely succeed with a critical warning; the RBF will work but timing closure will be misreported. The fix is documented in the comment at `menu.sv:383-385`.
**Fix:** When the build agent sees the expected critical warning, append to `sys/sys_top.sdc:22`:
```
set_clock_groups -exclusive \
   -group [get_clocks { pll_vid_43|pll_video_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_vid_169|pll_video_169_inst|altera_pll_i|*[0].*|divclk}]
```
Verify the exact instance names match the fitter log; the pattern follows the existing groups at lines 14-19.

### P-2.4 `usleep(50000)` pre-execve omitted; depends on FPGA mux settling within wrapper startup overhead
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp:1859` (after `setenv("SONIC_MANIA_ASPECT", ...)`)
**Issue:** Plan §3 step 3 prescribed an explicit `usleep(50000)` after `setenv("SONIC_MANIA_ASPECT", ...)` and before `execve` so the FPGA's 2-FF synchronizer chain plus the MiSTer `hps_io` status push has time to settle on the new aspect bit before the engine begins writing DDR3. The implement agent omitted it on the argument that `set_runtime_environment` (line 1822) runs at line 2765 in the per-launch loop, well before `fork()` (2802) and `execve` (2855), and the wrapper-side overhead (file validation, `pipe2`, `sigaction`, joy_shm setup, ~tens of ms) covers the FPGA settle time naturally.
**Why this is P-2:** The reasoning is plausible; on a re-launch (Restart toggle), the wrapper ssh path skips most of the cold-boot work and the time between `setenv` and `execve` may be milliseconds. If the engine starts writing the *new* 16:9-sized buffer to BUF1 while the FPGA reader is still in 4:3 mode at the old BUF1_ADDR offset, you get one frame of garbage / torn pixel data on the toggle boundary.
**Fix:** Add the explicit `usleep(50000)` at the top of `set_runtime_environment` after the new env-var block, OR right before `fork()` in the loop. Plan §6 failure-mode also says: "If torn frames at aspect-toggle boundary, raise to 200 ms or extend the synchronizer to 3-FF."

### P-2.5 Stale comment in video.cpp references the pre-Phase-9 24.6032 MHz literal
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/video.cpp:3069-3074`
**Issue:** The block-comment immediately above the new ternary still says
```
/* When native video is active (Sonic Mania), CLK_VIDEO is 24.6032 MHz
   from the dedicated video PLL (50 MHz * 62/3 / 42). The YC encoder
   runs at this frequency, ...
```
which describes the Phase-4 PLL coefficients, not the Phase-9 ones. The new comment block (lines 3076-3083) is correct. Future readers will be confused by the contradiction.
**Why this is P-2:** Cosmetic / documentation drift only. No runtime effect.
**Fix:** Replace the `24.6032 MHz from the dedicated video PLL (50 MHz * 62/3 / 42)` line with `27.000 MHz (4:3) or 1010/29 MHz (16:9) selected by the Phase-9 dual-PLL mux on status[13]`. Or just delete the now-redundant comment block — the Phase-9 block below it stands on its own.

### P-2.6 `kAspectRatioFull` enum + "full" persistence string semantically misleading post-Phase-9
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp:132-137, 1209-1221`
**Issue:** The persistence layer reads/writes `aspect-ratio = "full"` for the widescreen mode (`kAspectRatioFull = 1`). In Phase 4 / 3sx semantics, "Full" referred to the HDMI scaler's ARX=0/ARY=0 fill-display mode — orthogonal to native pixel buffer width. In Phase 9, status[13]=1 means **both** the FPGA pixel buffer is widescreen 424×240 **and** the HDMI scaler is in full-aspect mode (the `wire ar_full = aspect_169;` aliasing at `menu.sv:217`). A future maintainer reading "aspect-ratio = full" in `Sonic Mania.cfg` will plausibly think it's an HDMI scaler tweak when it's actually the dual-modeline native-aspect select.
**Why this is P-2:** Confusing but not wrong. Both 0 and 1 map correctly through the env-var pipeline (0 → "43", 1 → "169").
**Fix:** Optional; rename the enum + persistence string to `kAspectRatioWidescreen` / `"widescreen"` in a follow-up cleanup pass. Bump a config-migration step if persistence is preserved across the rename.

### P-2.7 dcfifo depth (256) margin tighter for 16:9
**File:** `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv:399, 405-432`
**Issue:** Comment at line 399 still says "Depth 256: holds ~3.2 scanlines (80 beats/line * 3.2 = 256) for 320x240 Mania". For 16:9 mode, 256 / 106 beats/line = 2.41 scanlines of buffering instead of 3.2. The state machine preloads two lines during vblank (`ST_LINE_DONE` branches at line 371 `cur_line < 9'd1`), so the FIFO sees ~2.4 lines of slack on every line read. Plenty in nominal conditions; a tight DDR3-contention burst (e.g. SDRAM clear during boot, audio DMA bursts) could conceivably starve the FIFO and cause a one-line dropout.
**Why this is P-2:** Margin reduction, not breakage. Existing baseline survives (3sx ran 384×224 = 96 beats/line, 2.67 lines depth, with the same `lpm_numwords(256)` and was field-tested).
**Fix:** Update the comment to reflect 16:9 line count. Optionally bump `lpm_numwords` to 512 if hardware test shows underruns at startup. Leave the parameter alone for now and verify on hardware.

## Confirmed correct (sampling — not exhaustive)

- **PLL math (4:3):** `pll_video_0002.v:46` `output_clock_frequency0("27.000000 MHz")`. With M=81/N=5/C=30 → VCO = 50 MHz × 81/5 = 810 MHz (in Cyclone V 600-1300 MHz range), output = 810/30 = 27.000 MHz exact. CE_PIXEL ÷4 → 6.75 MHz pixel. H_TOTAL=429, V_TOTAL=262 → 6,750,000 / (429×262) = 60.054 Hz, H-freq = 6,750,000/429 = 15,734.27 Hz (NTSC-exact). ✓
- **PLL math (16:9):** `pll_video_169_0002.v:48` `output_clock_frequency0("34.827586 MHz")`. With M=101/N=5/C=29 → VCO = 50 MHz × 101/5 = 1010 MHz (in range), output = 1010/29 = 34.827586 MHz. CE_PIXEL ÷4 → 8.7069 MHz. H_TOTAL=545, V_TOTAL=266 → 8,706,896 / (545×266) = 60.060 Hz, H-freq = 8,706,896/545 = 15,975.04 Hz. ✓
- **video.cpp ternary aligns with PLL output:** `(aspect_169_native ? (1010.0/29.0) : 27.0)` at `video.cpp:3086-3087`. The literals are CLK_VIDEO Hz (the DAC clock the YC encoder runs from), not pixel clock. Matches plan and matches the PLL `output_clock_frequency0` strings exactly. ✓
- **Glitch-free 2:1 clock mux pattern:** `menu.sv:386-397` follows the canonical Altera "Glitch-Free Clock Multiplexers" recipe — separate 2-FF synchronizers in EACH input clock domain, cross-coupled enables (`en43 = sel_sync_43[1] & ~sel_sync_169[1]`), then AND-OR. Verified by reading the synchronizer chain logic by hand:
  - `aspect_169 = 0`: `sel_sync_43` latches `~0=1` → after 2 cycles `sel_sync_43[1]=1`; `sel_sync_169` latches `0` → `sel_sync_169[1]=0`; `en43 = 1 & ~0 = 1`, `en169 = 0 & ~1 = 0`; `clk_pix = clk_pix_43`.
  - `aspect_169 = 1`: opposite, `clk_pix = clk_pix_169`.
  - During transition: BOTH enables can be 0 simultaneously (clean gap), but both are NEVER 1 simultaneously.
- **Status-bit map agreement** between (a) `menu.sv:306-325` CONF_STR, (b) `menu.sv:216` `aspect_169 = status[13]`, (c) `sonicmania_wrapper.cpp:1851-1859` env-var emission via `user_io_status_get("[10]")`, `("[12:11]")`, `("[13]")`, (d) `MiSTerRenderDevice.cpp:69-77` (reads `SONIC_MANIA_ASPECT`), `MiSTerRenderDevice.cpp:91-112` (reads `SONIC_MANIA_FPS_OVERLAY`), `RetroEngine.cpp:79-86` (reads `SONIC_MANIA_MODS`). All five references agree on bits 10, 11-12, 13 with the same encoding (0=On for Mods, 0=Off / 1=Simple / 2=Detailed for FPS, 0=4:3 / 1=Widescreen for Aspect). ✓
- **Env var contract:** Wrapper emits values exactly as engine expects. `mods_off ? "0" : "1"` → engine `mods_env[0] != '0'` decides enable. `fps_overlay == 1 ? "1" : ...` → engine `atoi(fpso)` and `switch (mode)`. `aspect_169 ? "169" : "43"` → engine `strcmp(aspect_env, "169") == 0`. All three round-trip cleanly. ✓
- **NV runtime dim flow:** `MiSTerRenderDevice::Init` at lines 68-77 sets `videoSettings.pixWidth` from env var, then line 84 calls `NativeVideoWriter_SetDims(pixWidth, SCREEN_YSIZE)`, which updates `nv_frame_width_runtime`/`nv_frame_height_runtime`/`nv_frame_bytes_runtime`/`nv_buf1_offset_runtime` BEFORE `SetupRendering→InitGraphicsAPI→SetScreenSize` runs at line 186 and BEFORE `NativeVideoWriter_Init()` at line 117 mmaps the DDR3 region. `FlipScreen` at line 262 then guards `screens[0].size.x != nv_frame_width_runtime` so a stale frame is dropped if dims drift mid-run. ✓
- **DDR3 region accommodation:** 16:9 frame_bytes = 203,520 → BUF1_OFFSET = 0x100 + 0x31B00 = 0x31C00. BUF1+frame_bytes = 0x63700 (407,296 B). New region 0x80000 = 524,288 B. Fits with 117 KB headroom. `NativeVideoWriter.c:18-19` carries the same arithmetic as a comment. ✓
- **FPGA reader BUF1 ↔ engine BUF1 agreement:** `native_video_reader.sv:100` `BUF1_ADDR = aspect_169 ? 29'h07406380 : 29'h07404B20`. Decoding the qword address: 0x07406380 << 3 = 0x3A031C00 = NV_DDR_PHYS_BASE + 0x31C00 = NV_DDR_PHYS_BASE + (NV_BUF0_OFFSET + 16:9 frame_bytes). `0x07404B20 << 3 = 0x3A025900 = base + 0x25900 = base + (NV_BUF0_OFFSET + 4:3 frame_bytes)`. Both match the engine-side `nv_buf1_offset_runtime`. ✓
- **CONF_STR syntax format:** All `O[N:M]` 2-bit options have exactly the right number of comma-separated values for 2^(N-M+1) bit width. `O[12:11],FPS Overlay,Off,Simple,Detailed` = 3 of 4 options (one reserved value 11=undefined acceptable in MiSTer). `O[38:37],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer` = 4 of 4 options. `O[36:33],Crop Offset,...` = 12 of 16 options (4 unmapped — same as 3sx baseline, accepted as fine). 4-bit `O[42:39] H Size` = 9 of 16 options, mapped via `case` block in `menu.sv:237-244`. `O[28:25] H Position` and `O[46:43] V Position` = 16 of 16 (full). Header `"Sonic Mania;UART31250,MIDI;"` matches MiSTer convention. `J1,A,B,Select,Start;` and `jn,B,A,Select,Start;` follow the existing pattern. ✓
- **`clk_video` consumed downstream:** `assign CLK_VIDEO = clk_pix;` at `menu.sv:399` flows to `native_video_top.clk_vid` (line 760), which threads to both `native_video_timing.clk` (timing.sv line 76→39) and `native_video_reader.clk_vid` (reader.sv line 119→54). All three modules now accept `aspect_169` as an input port (timing.sv:46, reader.sv:60, top.sv:28). ✓
- **3sx-specific runtime config writers left in place but no longer called from `poll_status_changes`:** `write_runtime_super_effect_quality_default`, `_ghost_resolution_default`, `_ghost_count_default`, `_arm_clock_default`, `_game_mode_default`, `_hold_to_pause_default` are still defined but `poll_status_changes` (lines 1990-2159) has comment markers documenting the removal at lines 2031-2044. `g_wrapper_arm_clock_active = g_wrapper_arm_clock` at line 2978 is harmless because both default to `kArmClockStock=0` and the gating `if (g_wrapper_arm_clock_active != kArmClockStock)` at line 2910 stays false. ✓
- **input_switch fix preserved:** `vendor/Main_MiSTer/video.cpp:3421, 3434, 3441, 3449` all still call `input_switch(0)` per the existing post-Phase-7 fix. Plan §3 step 5 instruction respected. ✓
- **`pll_q17.qip` includes new pll_video_169 line:** `vendor/Menu_MiSTer/sys/pll_q17.qip:6` adds `set_global_assignment -name QIP_FILE rtl/pll_video_169.qip` matching the existing line 5 format for the 4:3 PLL. ✓
- **`pll_video_169.qip` mirrors `pll_video.qip`:** Both use `[file join $::quartus(qip_path) ...]` and reference `pll_video_169/pll_video_169.v` and `pll_video_169/pll_video_169_0002.v`. Directory structure parallel: `vendor/Menu_MiSTer/rtl/pll_video/{.v, _0002.v}` and `rtl/pll_video_169/{.v, _0002.v}`. ✓
- **No bare `status[12]` reads remain in `menu.sv`:** Verified by grep — only references to `status[12]` are inside comment blocks (lines 213, 293, 295). ✓
- **`engine.version = 5` runs after the gated `InitModAPI`:** `RetroEngine.cpp:90` is unconditional, so engine version is correctly set even when `SONIC_MANIA_MODS=0` skips the mod scan. ✓
- **Diagnostic signals confirmed false positives:** clangd-on-Mac complaints about `RenderDevice` undeclared (file textually included), `Expected namespace name` in RetroEngine.cpp (sysroot), `is_void` template error in libstdc++ vector, and missing Linux headers (`linux/*.h`, `cpu_set_t`, `FBIO_WAITFORVSYNC`, `jni.h`) are all expected on Mac and not regressions.

## Cross-references checked

- **Plan locked values** (`docs/phase-9-plan.md` "Quick reference — locked values" tables, lines 1030-1124): every numeric value in the implementation traces back to the plan's locked tables (PLL coefficients, H/V totals, status bits, env vars, DDR3 memory map). No deviations.
- **`user_io_status_get` API signature** (`vendor/Main_MiSTer/user_io.h:185`): `uint32_t user_io_status_get(const char *opt, int ex = 0)`. Matches the wrapper and `video.cpp` call pattern (`user_io_status_get("[10]")`, etc.). The default arg `ex=0` is OK; existing baseline at `user_io.cpp:882` calls `user_io_status_get(p+2)` without `ex`. ✓
- **Existing PLL files pattern** (`vendor/Menu_MiSTer/rtl/pll_video/pll_video.v`): the new `pll_video_169.v` wrapper follows the exact 7-line shape (module header + single instantiation + endmodule). Module/instance names renamed to `pll_video_169` and `pll_video_169_inst`. ✓
- **Existing SDC pattern** (`vendor/Menu_MiSTer/sys/sys_top.sdc`): the unchanged file uses `derive_pll_clocks` plus an explicit `set_clock_groups -exclusive` enumeration of named groups. The new video PLLs are NOT in the explicit list — see P-2.3 above for the recipe.
- **Drawing.cpp constraint** (`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:145-146`): `MiSTerRenderDevice.cpp` is `#include`d into Drawing.cpp after `NativeVideoWriter.h`, which is `#include`d on the preceding line. So the C linkage globals (`nv_frame_width_runtime` etc.) are visible in MiSTerRenderDevice.cpp. ✓
- **NV_DDR_PHYS_BASE and DDR3 region collision:** the FPGA reader at `native_video_reader.sv:98-100` hard-codes `CTRL_ADDR=0x07400000` and `BUF0_ADDR=0x07400020` (qword addresses, == 0x3A000000 and 0x3A000100 byte). The 16:9 BUF1 ends at byte 0x63700 (qword 0x740C6E0). 0x80000 (qword 0x10000) reach is 0x07410000, well above 0x740C6E0. No collision with anything else mapped in DDR3 (the wrapper's `g_nv_ddr3_base` mmap is 4 KB at 0x3A000000; SDRAM clear at `menu.sv:451-505` uses different addresses 0x4000000, 0x2000000, 0x0000000, 0x1000000 in SDRAM — separate physical bank). ✓
- **Glitch-free clock mux reference** (Altera "Glitch-Free Clock Multiplexers" app note pattern, mirrored in Cyclone V `altera_clkctrl` IP): the explicit AND/OR + cross-coupled enable + 2-FF synchronizer pattern at `menu.sv:386-397` is the canonical fabric implementation. ✓
- **Implement report `phase-9-implement-report.md` lines 426-429** claimed a `write_log_line(wrapper_log, "phase9: ...")` call exists in the wrapper; verification by reading `vendor/Main_MiSTer/sonicmania_wrapper.cpp:1850-1860` shows it does NOT. Documented as P-2.1 above. The claim is the only material divergence between the implement report and the actual code.
