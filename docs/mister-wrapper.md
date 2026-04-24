# Sonic Mania MiSTer Wrapper — User Guide

User-facing reference for installing and running Sonic Mania on a MiSTer
DE10-Nano. Covers the install layout, MiSTer.ini contract, launch flow,
and common troubleshooting. For the full engineering history see
`docs/mister-runbook.md` and `docs/mister-port-research.md`.

## Overview

Sonic Mania on MiSTer is a hybrid ARM + FPGA port. The RSDKv5 game engine
runs on the Cortex-A9 HPS as a normal Linux userland binary; the FPGA core
(`Sonic Mania.rbf`) provides the native 320×240 video pixel reader, audio
buffering, and DAC conversion path. A small wrapper executable
(`MiSTer_SonicMania`) replaces the stock `MiSTer` binary for this core only;
when the user selects "Sonic Mania" from the OSD the wrapper takes over,
seeds the core's video/PLL settings, then `execve()`s the engine binary.

## Install Layout

The release ZIP is structured so that extracting it onto the SD card root
lands every file in its final location. Path layout matches what
`tools/mister-wrapper/deploy-step5.sh` produces and what
`vendor/Main_MiSTer/sonicmania_wrapper.cpp` expects at runtime
(constants `kRuntimeHome`, `kRuntimeBinary`, `kRuntimeArchive` at
lines 56–58).

```text
/media/fat/
  MiSTer_SonicMania                       (HPS wrapper, replaces stock MiSTer for this core)
  _Other/
    Sonic Mania.rbf                       (FPGA bitstream)
  games/
    sonic-mania/
      Data.rsdk                           (USER-SUPPLIED — legally-owned game data)
      bin/RSDKv5U                         (game engine binary)
      lib/libtheora.so.0                  (bundled — MiSTer rootfs lacks it)
      lib/libtheoradec.so.1               (bundled — same reason)
      scripts/run-mania.sh                (launcher; sets LD_LIBRARY_PATH and execs RSDKv5U)
      saves/                              (engine-managed, see Saves below)
      logs/                               (wrapper stdout/stderr captures)
      resources/                          (reserved for future read-only assets)
```

The ZIP does NOT include `Data.rsdk` for copyright reasons. The user must
supply their own legally-owned copy and place it at
`/media/fat/games/sonic-mania/Data.rsdk` before launching.

## MiSTer.ini Contract

Add a `[Sonic Mania]` section to `/media/fat/MiSTer.ini`. The minimum
required keys are:

```ini
[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0
```

Both keys are required:

- `main=MiSTer_SonicMania` tells the OSD to run the Mania-specific wrapper
  instead of the stock `MiSTer` binary when this core is selected.
- `vga_scaler=0` keeps the FPGA core's native pixel path connected to the
  YC encoder. With `vga_scaler=1`, the FPGA routes the HDMI scaler's plain
  RGB signal to the VGA DAC, bypassing the core video path — that produces
  grayscale S-Video and an aspect-ratio mismatch on CRT. This applies even
  if the user has `vga_scaler=1` set globally; the per-core override here
  takes precedence.

Do NOT add a `video_mode=` override. The native 320×240 timing
(~59.59 Hz, 6.151 MHz pixel clock) is owned by the FPGA core and the PLL
inside `Sonic Mania.rbf`; manual `video_mode` overrides will desync the
display.

The `tools/mister-wrapper/deploy-step5.sh` helper appends this section
automatically if the INI does not already contain one.

## CRT Notes

The native video path uses a 320×240 progressive modeline at ~59.59 Hz
(see `docs/mister-runbook.md` Phase 4 block — PLL integer-N M=62/N=3/C=42,
verified by the Quartus fitter log to a 40.645 ns period). This is below
NTSC 15.7 kHz horizontal frequency standard, so most 15 kHz CRTs and
arcade monitors should sync directly with `vga_scaler=0`.

For S-Video color (vs. grayscale), `vga_scaler=0` is mandatory. The
`core_CLK_VIDEO` constant in `vendor/Main_MiSTer/video.cpp` is calibrated
to the actual PLL rate so the YC subcarrier phase is correct.

If your CRT does not sync at all, see Troubleshooting below.

## Launch Flow

```text
MiSTer OSD
  └─> select "Sonic Mania" (under _Other/)
      └─> stock MiSTer binary reads MiSTer.ini, sees main=MiSTer_SonicMania
          └─> execs /media/fat/MiSTer_SonicMania <Sonic Mania.rbf>
              ├─> wrapper seeds core PLL, video, scaler
              ├─> wrapper validates /media/fat/games/sonic-mania/bin/RSDKv5U
              │   and /media/fat/games/sonic-mania/Data.rsdk
              └─> execve /media/fat/games/sonic-mania/bin/RSDKv5U
                  ├─> engine opens Data.rsdk
                  ├─> NativeVideoWriter writes RGB565 frames into DDR3 0x3A000000
                  └─> FPGA pixel reader scans DDR3 → YC encoder → DAC
```

Wrapper logs land at `/media/fat/games/sonic-mania/logs/osd-wrapper.log`
(lifecycle events) and `…/logs/last-run.log` (engine stdout/stderr capture).
The engine's own log goes to `…/log.txt` at the runtime home.

## Saves

Game saves (`SGame.bin`, replay files), `Settings.ini`, and the SDL
gamepad-mapping override (`gamecontrollerdb.txt`) all live under
`/media/fat/games/sonic-mania/saves/`. The directory is auto-created on
first launch by both the launcher (`scripts/run-mania.sh`) and the engine
(`InitUserDirectory()` in `dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserStorage.cpp`
on the MiSTer arm).

Keeping saves in a dedicated subdirectory means future release ZIPs can
overwrite `bin/`, `lib/`, and `scripts/` without colliding with user
save data. Upgrading from a pre-`saves/` build is described in the
"Upgrading from a dev build" section below.

## Input Rebinding

Sonic Mania ships its own in-game rebinder. From the title screen,
navigate to Options → Controls; the menu auto-detects the active
controller type (Xbox / PS4 / Switch / etc.) and presents the
corresponding rebind page. The rebound mappings persist into the
engine's `Settings.ini` under `/media/fat/games/sonic-mania/saves/`.

For SDL2-level controller mapping overrides (e.g., a non-recognised
arcade pad that Mania misidentifies), drop a custom
`gamecontrollerdb.txt` into `/media/fat/games/sonic-mania/saves/`.
The engine loads it via `SDL_GameControllerAddMappingsFromFile` at
startup. See `docs/mister-settings.md` Input Rebinding section for
details.

## Troubleshooting

**Black screen, core appears to do nothing.**
Most common cause: missing `Data.rsdk`. The launcher checks for the file
before exec'ing the engine and logs an error to
`/media/fat/games/sonic-mania/logs/first-run.log` if absent. Verify the
file exists at `/media/fat/games/sonic-mania/Data.rsdk`.

**HDMI image but no S-Video color (grayscale only).**
Check that `[Sonic Mania] vga_scaler=0` is present in `MiSTer.ini`. A
global `vga_scaler=1` higher up in the file does not override the
per-core setting if the section line exists, but if you have your
section header but no `vga_scaler` key, the wrapper will inherit the
global value.

**No sync at all on CRT.**
Try the MiSTer scaler path as a fallback (HDMI scaler routed to VGA DAC,
no native YC color). Add to the `[Sonic Mania]` section:

```ini
vga_scaler=1
video_mode=320,16,32,48,240,8,3,17,6151
```

This routes through the MiSTer scaler at 320×240 native timing with
no pixel resampling. If your CRT requires composite sync, also add
`composite_sync=1`. Note this disables S-Video color.

**Core launches and immediately exits back to MiSTer.**
Check `/media/fat/games/sonic-mania/logs/osd-wrapper.log` and
`…/last-run.log`. The most common causes are: missing `Data.rsdk`
(see above), missing `bin/RSDKv5U`, and glibc / libtheora version
mismatch. The bundled `lib/libtheora.so.0` and `libtheoradec.so.1`
are required — the launcher prepends `lib/` to `LD_LIBRARY_PATH`.

## Upgrading from a Dev Build

If you previously installed a development build that wrote saves
directly into `/media/fat/games/sonic-mania/` (alongside `Data.rsdk`)
rather than under `saves/`, before extracting the new release:

1. Move existing save data:
   ```sh
   ssh root@<mister-ip>
   mkdir -p /media/fat/games/sonic-mania/saves
   mv /media/fat/games/sonic-mania/SGame.bin \
      /media/fat/games/sonic-mania/Settings.ini \
      /media/fat/games/sonic-mania/Replay_*.bin \
      /media/fat/games/sonic-mania/gamecontrollerdb.txt \
      /media/fat/games/sonic-mania/saves/ 2>/dev/null
   ```
2. Wipe the binary tree (do NOT delete `Data.rsdk` or `saves/`):
   ```sh
   rm -rf /media/fat/games/sonic-mania/bin \
          /media/fat/games/sonic-mania/lib \
          /media/fat/games/sonic-mania/scripts
   ```
3. Extract the new release ZIP onto the SD card root.

For new installs there is nothing to migrate — the launcher and engine
both `mkdir -p saves/` automatically.

## See Also

- `docs/mister-runbook.md` — engineering operational state, build flavors, libtheora
- `docs/mister-settings.md` — `Settings.ini` keys, defaults, and rebinding details
- `docs/mister-port-plan.md` — phase plan and roadmap
- `docs/phase-7-plan.md` — Phase 7 (this polish step) plan and rationale
