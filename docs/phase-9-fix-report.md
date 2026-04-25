# Phase 9 Fix Report

## Per-finding disposition

### P-2.1 — Missing wrapper log line

- **Verified:** yes — read `vendor/Main_MiSTer/sonicmania_wrapper.cpp:1850-1860`. The `set_runtime_environment` block emitted the three env vars via `setenv` but had no `write_log_line(wrapper_log, "phase9: ...")` call. The implement report's claim that the log line was present did not match the actual code.
- **Action:** fixed
- **Diff summary:** Took reviewer's path 2 (no signature change to `set_runtime_environment` — that function does not have `wrapper_log` in scope). Inserted a fresh log-emit block at the call site `vendor/Main_MiSTer/sonicmania_wrapper.cpp:2776-2793`, immediately after `set_runtime_environment(startup_scale_mode);`. Reads the env vars back via `getenv` (so it stays in sync with whatever the function actually emitted) and re-fetches the raw status bits via `user_io_status_get` so both the resolved string and the source bit are in the log line.

### P-2.2 — `<cstdlib>` reachability for getenv/atoi

- **Verified:** yes — `MiSTerRenderDevice.cpp:69, 92, 93` use bare `getenv`, `atoi`, `strcmp`. `Drawing.cpp` had no `#include <cstdlib>` (or `<stdlib.h>`) before the textual `#include "MiSTer/MiSTerRenderDevice.cpp"`. `<string.h>` (for `strcmp`) is already pulled in via `RetroEngine.hpp:8` so that part is portable; only `<cstdlib>` was the latent fragility.
- **Action:** fixed
- **Diff summary:** Added `#include <cstdlib>` inside the `#elif RETRO_RENDERDEVICE_MISTER` branch of `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:144-153`, scoped so other backends are not affected. Did NOT touch `MiSTerRenderDevice.cpp` per the textual-include constraint at its file header.

### P-2.3 — SDC `set_clock_groups -exclusive` for video PLLs

- **Verified:** yes — `vendor/Menu_MiSTer/sys/sys_top.sdc:13-22` has the existing exclusive group block; it lists the system PLL, HDMI PLL, audio PLL, etc., but nothing for `pll_vid_43` or `pll_vid_169`. With Phase 9's dual-PLL feeding a glitch-free clock mux, Quartus's `derive_pll_clocks` would create two generated clocks sharing fanout into `clk_pix` and emit cross-domain timing checks between them.
- **Action:** fixed (preemptively rather than waiting for the build phase to surface a critical warning)
- **Diff summary:** Appended a second `set_clock_groups -exclusive` block at `vendor/Menu_MiSTer/sys/sys_top.sdc:24-32` listing both video PLLs. Pattern mirrors the existing PLL groups (instance-name | wrapper-instance | altera_pll_i | indexed | divclk). The plan and reviewer both noted the exact instance names may need a fitter-log adjustment; comment block above the new directive points at the existing groups as the template.

### P-2.4 — `usleep(50000)` pre-execve

- **Verified:** yes — re-read the wrapper. The implement-agent's reasoning (cold-boot wrapper overhead naturally covers FPGA settle time) is plausible for first launch but doesn't hold on Restart toggle (the per-launch loop minimal path between `setenv` and `execve` could be milliseconds).
- **Action:** fixed (chose to add it; it's a one-line belt-and-suspenders insert and `<unistd.h>` plus other `usleep()` calls already exist in the file)
- **Diff summary:** Added `usleep(50000);` at `vendor/Main_MiSTer/sonicmania_wrapper.cpp:1868`, just inside `set_runtime_environment` after the env-var setenv block. Comment references plan §6 failure-mode (raise to 200 ms or extend FF chain if torn frames at toggle).

### P-2.5 — Stale 24.6032 MHz comment block in video.cpp

- **Verified:** yes — `vendor/Main_MiSTer/video.cpp:3069-3075` had the Phase-4 PLL coefficients (50 MHz × 62/3 / 42 → 24.6032 MHz) in a block comment, immediately above a (correct) Phase-9 comment block. Contradiction.
- **Action:** fixed (rewrote the block to point at status[13] without restating the now-wrong literal)
- **Diff summary:** Replaced the offending block at `vendor/Main_MiSTer/video.cpp:3069-3075`; it now says "selected by the Phase-9 dual-PLL mux on status[13]" and references both `phase-4-plan.md` (history) and `phase-9-plan.md` (dual-modeline). Did not delete the second Phase-9 comment block immediately below — they don't conflict anymore.

### P-2.6 — `kAspectRatioFull` enum + "full" persistence string

- **Verified:** yes — read `vendor/Main_MiSTer/sonicmania_wrapper.cpp:132-137` and the persistence path. Reviewer's diagnosis is correct.
- **Action:** SKIPPED (per orchestrator instructions and reviewer note: rename ripples to `Sonic Mania.cfg` persistence file format and would require a config-migration step; not in plan scope; both 0 and 1 still map correctly through the env-var pipeline so no functional defect).
- **Diff summary:** none.

### P-2.7 — dcfifo "3.2 lines" comment + 16:9 margin sanity check

- **Verified:** yes — `vendor/Menu_MiSTer/rtl/native_video_reader.sv:399`. Re-checked the math:
  - 4:3 mode: 320/4 = 80 beats/line, 256/80 = 3.20 lines slack.
  - 16:9 mode: 424/4 = 106 beats/line, 256/106 = 2.41 lines slack.
  - 3sx baseline: 384/4 = 96 beats/line, 256/96 = 2.67 lines slack — field-tested OK.
  - We're 0.25 lines tighter than 3sx baseline. Producer rate (DDR3 burst from 100 MHz fabric) is far above consumer rate (8.7069 MHz / 4 = 2.18 MBeats/s peak in 16:9), so 2.4-line slack covers worst-case bus contention. Reviewer correctly chose P-2 not P-1; concur.
- **Action:** fixed (comment-only)
- **Diff summary:** Updated the dcfifo header comment at `vendor/Menu_MiSTer/rtl/native_video_reader.sv:394-405` to spell out both aspect modes with their beats/line figures, the 3sx baseline reference, and a "bump to 512 only if hardware test shows underruns" note. Also corrected the stale `clk_vid (24.6032 MHz)` line to reference the dual-mode clock.

## Files modified

- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp` — added P-2.1 wrapper log emission at call site (lines 2776-2793) and P-2.4 `usleep(50000)` settle delay inside set_runtime_environment (line 1868).
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/video.cpp` — P-2.5 rewrote stale Phase-4 24.6032 MHz comment block at lines 3069-3075 to reference Phase-9 status[13] dual-PLL.
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/sys/sys_top.sdc` — P-2.3 appended `set_clock_groups -exclusive` for `pll_vid_43` and `pll_vid_169` at lines 24-32.
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv` — P-2.7 updated dcfifo header comment to cover both aspect modes and document margin headroom.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — P-2.2 added `#include <cstdlib>` scoped to `RETRO_RENDERDEVICE_MISTER` branch at lines 145-151.

## New issues discovered (if any)

None. Cross-checked the reviewer's confirmed-correct list against the diff while reading and did not find any P-1s the reviewer missed. The fitter-pattern guess for the SDC `set_clock_groups` block (P-2.3) may need adjustment when Quartus is run; flagged in the comment above the directive.

## Verification command output

```
$ git status
On branch mister
Changes not staged for commit:
	modified:   dependencies/RSDKv5 (modified content)
	modified:   vendor/Main_MiSTer/sonicmania_wrapper.cpp
	modified:   vendor/Main_MiSTer/video.cpp
	modified:   vendor/Menu_MiSTer/menu.sv
	modified:   vendor/Menu_MiSTer/rtl/native_video_reader.sv
	modified:   vendor/Menu_MiSTer/rtl/native_video_timing.sv
	modified:   vendor/Menu_MiSTer/rtl/native_video_top.sv
	modified:   vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v
	modified:   vendor/Menu_MiSTer/sys/pll_q17.qip
	modified:   vendor/Menu_MiSTer/sys/sys_top.sdc
Untracked files:
	docs/phase-9-implement-report.md
	docs/phase-9-review-report.md
	grabtest.c
	vendor/Menu_MiSTer/rtl/pll_video_169.qip
	vendor/Menu_MiSTer/rtl/pll_video_169/

$ grep -n "phase9" vendor/Main_MiSTer/sonicmania_wrapper.cpp
2788:			               "phase9: SONIC_MANIA_MODS=%s SONIC_MANIA_FPS_OVERLAY=%s SONIC_MANIA_ASPECT=%s (mods_off=%u fps=%u aspect_169=%u)",

$ grep -n "cstdlib" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp
146:// SONIC_MANIA_FPS_OVERLAY). Pulling <cstdlib> via <cmath> in RetroEngine.hpp
151:#include <cstdlib>

$ grep -n "set_clock_groups" vendor/Menu_MiSTer/sys/*.sdc
13:set_clock_groups -exclusive \
30:set_clock_groups -exclusive \

$ grep -n "27.0\|1010.0/29.0" vendor/Main_MiSTer/video.cpp
3078:		//   4:3:  M=81/N=5/C=30 -> 27.000000 MHz exact.
3081:		//   rejected M=101 and used the fallback, change `(1010.0 / 29.0)` to
3086:			? (aspect_169_native ? (1010.0 / 29.0)  // 16:9: 34.827586 MHz
3087:			                     : 27.0)            // 4:3:  27.000000 MHz

$ grep -n "0x80000\|NV_DDR_REGION_SIZE" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h
17://   NV_DDR_REGION_SIZE = 0x00080000  (BUMPED from 0x60000 to fit 16:9 buffers:
30:#define NV_DDR_REGION_SIZE  0x00080000u   /* 512 KB — fits 2 * 203,520 B (16:9) + ctrl + feedback */

$ grep -n "SONIC_MANIA_ASPECT" vendor/Main_MiSTer/sonicmania_wrapper.cpp dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:61:    // Phase 9: pixWidth is now aspect-keyed off SONIC_MANIA_ASPECT env var
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:69:        const char *aspect_env = getenv("SONIC_MANIA_ASPECT");
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:75:        PrintLog(PRINT_NORMAL, "Phase 9: SONIC_MANIA_ASPECT=%s -> pixWidth=%d",
dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:261:    // Phase 9: dims are runtime-keyed off SONIC_MANIA_ASPECT (see Init()).
vendor/Main_MiSTer/sonicmania_wrapper.cpp:1849:	//   SONIC_MANIA_ASPECT       "43" or "169"
vendor/Main_MiSTer/sonicmania_wrapper.cpp:1859:		setenv("SONIC_MANIA_ASPECT", aspect_169 ? "169" : "43", 1);
vendor/Main_MiSTer/sonicmania_wrapper.cpp:2056:	// SONIC_MANIA_ASPECT on startup; runtime poll just tracks UI state.
vendor/Main_MiSTer/sonicmania_wrapper.cpp:2065:			// Engine picks it up on next exec via SONIC_MANIA_ASPECT.
vendor/Main_MiSTer/sonicmania_wrapper.cpp:2783:			const char *aspect_env  = getenv("SONIC_MANIA_ASPECT");
vendor/Main_MiSTer/sonicmania_wrapper.cpp:2788:			               "phase9: SONIC_MANIA_MODS=%s SONIC_MANIA_FPS_OVERLAY=%s SONIC_MANIA_ASPECT=%s (mods_off=%u fps=%u aspect_169=%u)",
```

## Ready for build phase

Yes. All P-2 findings dispositioned (5 fixed, 1 skipped with reason — P-2.6 enum rename, deferred to follow-up cleanup pass, both code paths still functionally correct). No new P-1s discovered. Caveats:

- The new `set_clock_groups -exclusive` patterns for `pll_vid_43` / `pll_vid_169` (P-2.3) use the same instance-name pattern as the existing PLL groups in the SDC. If Quartus's fitter rewrites the hierarchy under a different prefix, the patterns may not match — verify against the `*.fit.rpt` after the first synthesis run and adjust if the timing analyzer still emits cross-domain warnings between the two video PLLs.
- The `usleep(50000)` (P-2.4) is conservative; if observed boot times degrade noticeably, the comment block at the call site references plan §6 for tuning back down.
- No builds run; no commits made. Working tree is dirty across superproject + RSDKv5 submodule. Orchestrator handles commit.
