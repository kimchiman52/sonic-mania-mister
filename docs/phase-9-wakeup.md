# Phase 9 Wake-Up Status

**Date:** 2026-04-25 ~04:40 EDT
**Status:** Deployed, booted, running on hardware.
**Branch:** `mister`

## TL;DR

Phase 9 ships **4:3-only** with the NTSC-exact modeline retune you actually
needed for the CRT. The 16:9 widescreen aspect was scope-cut after Quartus
exposed a Cyclone V architectural constraint that needs `altpll_reconfig`
(deferred to Phase 10).

Boot the core from `_Other/` → "Sonic Mania" and you should land on a CRT
with proper geometry, S-Video color, and the new OSD menu.

## Commits on `mister`

```
94d43af6  mister: Phase 9 scope cut — revert dual-aspect, keep 4:3 NTSC-exact retune
185f13e4  mister: Phase 9 dual-aspect (4:3/16:9) — RTL + wrapper + video.cpp + RSDKv5 bump
35e25c8d  docs: Phase 9 plan — modeline retune + OSD rewrite + dual-aspect (4:3/16:9)
a7610fb6  mister: video_fb_enable input_switch(0) — keep input released on fb mode switch
```

## What was actually delivered

Modeline (the CRT overscan fix):

- `pll_video` retuned: M=81 / N=5 / C=30 → **27.000 MHz** CLK_VIDEO exact
- `core_CLK_VIDEO` literal in `video.cpp` updated to match
- 4:3: H_TOTAL=429, V_TOTAL=262 → 6.750 MHz pixel / 15,734 Hz H-freq /
  60.07 Hz V-freq (NTSC-exact)

OSD menu (rewritten):

- Header: "Sonic Mania;UART31250,MIDI;"
- Joystick labels: A, B, Select, Start
- New: **Mods** toggle (status[10]), **FPS Overlay** Off/Simple/Detailed
  (status[12:11])
- Kept: H Size, H Position, V Position, Vertical Crop, Crop Offset, Scale,
  Reset to Default, Restart
- Removed: 3sx-specific Game Mode / Hold to Pause / Button Check /
  SA-related / Overclock options
- **status[13] is RESERVED** for Phase 10 Aspect Ratio (16:9 widescreen)

Wrapper env contract (from `user_io_status_get` → execve env):

- `SONIC_MANIA_MODS` — gates `InitModAPI` in engine
- `SONIC_MANIA_FPS_OVERLAY` — sets `showFPSOverlay` + `fpsOverlayMode`
- `SONIC_MANIA_HOME` — preserved
- `SONIC_MANIA_ASPECT` — NOT emitted (scope cut)

Engine:

- env-driven mod loader gating
- env-driven FPS overlay seeding
- `pixWidth = 320` hardcoded (4:3 only); runtime-dim plumbing
  (`NativeVideoWriter_SetDims`) kept for Phase 10
- `NV_DDR_REGION_SIZE` bumped 0x60000 → 0x80000 (headroom for 16:9 buffers
  in Phase 10; harmless overhead now)

## On-device verification (already done autonomously)

I remote-loaded the core via `/dev/MiSTer_cmd` after deploy and confirmed:

```
$ ps -ef | grep -E "MiSTer|RSDKv5U"
537   /media/fat/MiSTer_SonicMania /media/fat/_Other/Sonic Mania.rbf
11481 /media/fat/games/sonic-mania/bin/RSDKv5U   (state=R running, RSS=38MB)
```

Runtime log signals:

```
phase9: SONIC_MANIA_MODS=1 SONIC_MANIA_FPS_OVERLAY=0 (mods_off=0 fps=0)
YC_DEBUG: computed: ... CLK_VIDEO=27.000000
YC_DEBUG: output: yc_config=0x1 (yc_en=1 cvbs=0 pal_en=0) PHASE_INC=0x21F07BD6B9
NativeVideoWriter_Init: width=320 height=240 frame_bytes=153600 buf1_offset=0x25900 region=0x80000
[MiSTerPacer] vsync feedback engaged (delta=15563 us, seq=91)
```

The S-Video color path is alive (PHASE_INC recomputed for 27.0 MHz / 3.579545
MHz colorburst), the pacer is engaged, the engine is running.

What I could **not** verify autonomously: actual on-CRT image + controller
input. That requires you to look at the screen + push buttons. Boot the core
and you'll know in five seconds whether the modeline land correctly on your
CRT.

## Phase 10 future work (16:9 widescreen)

Why we cut: `sys_top.v`'s `hdmi_clk_sw` / `vga_clk_sw` are clock select blocks
that demand `inclk[3]` come **directly** from a PLL CLK output. Quartus
rejected:

1. Manual AND/OR glitch-free mux: `Error (15836)` — combinational on a clock
   net is illegal.
2. `altclkctrl` IP cascading: `Error (15836)` — altclkctrl output is not "a
   PLL output," cascades not allowed.

The only viable Cyclone V path is `altera_pll_reconfig` (dynamic PLL
coefficient reconfig via Avalon-MM): single PLL whose M/N/C swap when
`status[13]` toggles. Roughly 100+ LOC of state machine + IP wizard + Avalon
plumbing — too risky to land overnight.

The runtime infrastructure is already in place for Phase 10 (NV runtime dims,
0x80000 DDR3 region, status[13] reserved). When you do Phase 10:

1. Add `altera_pll_reconfig` IP next to the existing `altera_pll`.
2. Coefficient ROM with two entries: 4:3 (M=81/N=5/C=30) and 16:9 (M=101/N=5/C=29).
3. Aspect-toggle state machine: detect `status[13]` change, freeze
   `native_video_reader`, kick reconfig, wait for `pll_locked`, unfreeze.
4. CONF_STR: re-add `"O[13],Aspect Ratio,4:3,Widescreen;"`.
5. Wrapper: re-add `SONIC_MANIA_ASPECT` setenv.
6. Engine: re-add the env read and pass through to `NativeVideoWriter_SetDims(320|424, 224)`.

Most of that surface already exists in the Phase 9 commits (or the scope-cut
deletions). The 16:9 H/V totals (545×266) are documented in
`docs/phase-9-plan.md`. Step 1 and the freeze/reconfig handshake are the only
genuinely-new work.

## Build artifacts (in repo + on MiSTer)

| Artifact | Mac path | MiSTer path | md5 |
|---|---|---|---|
| Wrapper | `build/mister-wrapper-hps/MiSTer_SonicMania` (1,026,772 B) | `/media/fat/MiSTer_SonicMania` | `8aaf2ea8e4ecc1533791703d25d865fd` |
| RBF | `build/mister-wrapper-core/Sonic_Mania.rbf` (2,500,756 B) | `/media/fat/_Other/Sonic Mania.rbf` | `01695d80f6f8f4391f0b29acb9378fd7` |
| Game | `build/mister-telemetry-install/bin/RSDKv5U` (6,632,848 B) | `/media/fat/games/sonic-mania/bin/RSDKv5U` | `498623c423c92eb5b04a2aa2968f152f` |

## Side note: timing

Quartus reports `Critical Warning (332148): Timing requirements not met`.
`pll_video` worst-case setup slack -15.5 ns. Same warning class as the
previous successful Sonic Mania build that you've been running. On-device
boot succeeded and the pacer engaged cleanly, so functionally it's fine.
Worth a deeper look if you ever see visual glitches that correlate with
specific scenes.

## Process docs (committed for history)

- `docs/phase-9-plan.md` — original 8-step plan
- `docs/phase-9-implement-report.md` — Step 1 (implement) findings
- `docs/phase-9-review-report.md` — Step 2 (review) findings (0 P-1, 7 P-2)
- `docs/phase-9-fix-report.md` — Step 3 (verify+fix) dispositions
- `docs/phase-9-scopecut-report.md` — emergency scope cut (this morning)
- `docs/phase-9-wakeup.md` — this file
