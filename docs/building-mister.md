# Building the MiSTer port

This document covers the **MiSTer-specific** build pipeline only. For the desktop (Windows / macOS / Linux native) build of upstream Sonic Mania Decompilation, see the bottom of [README.md](../README.md) — that flow still works on non-MiSTer hosts.

The MiSTer port has two independently-built artifacts:

1. **HPS engine binary** (`MiSTer_SonicMania` + `RSDKv5U`) — the userland Linux process that runs on the DE10-Nano's Cortex-A9. Built via Docker armhf cross-compile in ~2 minutes on a typical host.
2. **FPGA RBF** (`Sonic_Mania_43_YYYYMMDD.rbf` + `Sonic_Mania_YYYYMMDD.rbf`) — the FPGA bitstream that wires up the native-video pipeline. Built via Quartus 17.0 Lite in ~75–90 minutes per aspect, requires an x86_64 Linux build environment.

Most port iteration only touches the HPS binary; the FPGA RBF rarely changes.

## Prerequisites

| What | Why | Notes |
|---|---|---|
| Docker (Desktop or CLI) | armhf cross-compile container for HPS binary | Linux/amd64 platform required |
| `sshpass` | scp/ssh to MiSTer non-interactively | macOS: `brew install hudochenkov/sshpass/sshpass` |
| Network access to MiSTer | Deploy step pushes binaries via rsync over SSH | Default IP `192.168.1.188`, override with `MISTER_HOST` |
| Quartus 17.0 Lite (FPGA only) | Synthesizes the RBF | Linux/amd64. We run it inside a [colima](https://github.com/abiosoft/colima) x86_64 VM on macOS — see "FPGA build" below |

The HPS pipeline does not need Quartus. If you only modify ARM code (most perf/feature iterations), you only need Docker + sshpass.

## HPS engine build

```bash
# From the repo root:
tools/mister/build-game.sh --flavor telemetry
```

Flavors:
- `telemetry` — instrumentation enabled (FPS overlay, perf scope timers, [perf-spike] / [perf-window] / [perf-run] log lines). Use for development.
- `clean` — instrumentation compiled out. Use for release.

Output lands at `build/mister-telemetry-package/` (or `build/mister-clean-package/`):
- `bin/RSDKv5U` — the engine binary
- `lib/libtheora.so.0`, `lib/libtheoradec.so.1` — bundled video decode libs (the MiSTer rootfs doesn't ship them)
- `scripts/run-mania.sh` — launcher

The Docker container `sonic-mania-mister-arm-build` is built on first run from `tools/mister/setup-build-container.sh`. ~5 minutes one-time, cached afterwards.

### Deploy

```bash
tools/mister/deploy-to-mister.sh
```

This:
1. SCPs the HPS binary + libs + run-mania.sh to `/media/fat/games/sonic-mania/`
2. SCPs the wrapper to `/media/fat/MiSTer_SonicMania`
3. SCPs the latest `Sonic_Mania*.rbf` files from `build/mister-wrapper-core/` to `/media/fat/_Other/`
4. Idempotently injects `[Sonic Mania]` and `[Sonic Mania (4:3)]` sections into `/media/fat/MiSTer.ini` if missing
5. Idempotently injects `username=MiSTer FPGA` under `[Game]` in `/media/fat/games/sonic-mania/Settings.ini` if no username is set

Override defaults via env:
- `MISTER_HOST` (default `192.168.1.188`)
- `MISTER_USER` (default `root`)
- `MISTER_PASSWORD` (default `1` — the stock MiSTer password)
- `MANIA_FLAVOR` (default `telemetry`)
- `MISTER_REMOTE_BASE` (default `/media/fat/games/sonic-mania`; **whitelist-checked**)

The script never uses `rsync --delete` — your existing `Data.rsdk`, save data, and config are preserved across deploys.

## HPS wrapper build (rare)

The HPS wrapper (`MiSTer_SonicMania`) is built separately and only when the wrapper code (`vendor/Main_MiSTer/sonicmania_wrapper.cpp`) changes:

```bash
tools/mister-wrapper/build-hps.sh
```

Output: `build/mister-wrapper-hps/MiSTer_SonicMania`. The deploy script copies this automatically.

## FPGA RBF build

The FPGA build runs Quartus 17.0 Lite, which is x86_64 Linux only. If you're on macOS, run it inside an x86_64 Linux VM via colima (or a real Linux host).

### One-time colima setup (macOS)

```bash
brew install colima
colima --profile quartus2 start --arch x86_64 --cpu 4 --memory 8 --disk 20
```

Install Quartus 17.0 Lite inside the VM at `/home/<user>/intelFPGA_lite/17.0/` (download from [Intel's archive](https://www.intel.com/content/www/us/en/software-kit/669513/intel-quartus-prime-lite-edition-design-software-version-17-0-for-linux.html)). The colima VM auto-mounts `/Users/<you>/` from the host so the repo is accessible at the same path.

### Building an RBF

```bash
# 4:3 aspect (named variant — Sonic_Mania_43_*.rbf):
colima --profile quartus2 ssh -- bash -lc '
  export PATH=/home/<user>/intelFPGA_lite/17.0/quartus/bin:$PATH \
         LC_ALL=C.UTF-8 LANG=C.UTF-8 RUBYOPT="-EUTF-8" &&
  cd /Users/<you>/Developer/sonic-mania-mister &&
  nohup env OUTPUT_DIR=/home/<user>/build/sonic-mania-mister-core \
    bash tools/mister-wrapper/build-core.sh --aspect 4:3 --seed menu \
    > /home/<user>/build/sonic-mania-43-build.log 2>&1 &
  echo "Quartus 4:3 build PID: $!"
'

# 16:9 aspect (default — Sonic_Mania_*.rbf):
# Same, with --aspect 16:9 and a different log file. Quartus license is
# single-instance — sequence the two builds, do not run in parallel.
```

Wall-clock: ~75–90 minutes per RBF on a 4-CPU colima VM. The build script handles the source-tree patching for 16:9 (PLL coefficients, modeline timings, BUF1 offset, ARX/ARY).

### Pulling the RBF back to the host

```bash
colima --profile quartus2 ssh -- \
  cp /home/<user>/build/sonic-mania-mister-core/Sonic_Mania_43_YYYYMMDD.rbf \
     /Users/<you>/Developer/sonic-mania-mister/build/mister-wrapper-core/

cd build/mister-wrapper-core && ln -sf Sonic_Mania_43_YYYYMMDD.rbf Sonic_Mania_43.rbf
```

The deploy script's `resolve_latest_rbf` follows the symlink, so future deploys will pick the new RBF automatically.

## Build flavors and gating

The MiSTer-specific code uses two compile gates:

- `RSDK_USE_MISTER` — defined when building any MiSTer target (set in `dependencies/RSDKv5/CMakeLists.txt:153-156` from `RETRO_SUBSYSTEM=MISTER`, plus on the `${GAME_NAME}` target via `CMakeLists.txt:126-138` for SonicMania-side code).
- `ENABLE_PERF_TELEMETRY` — defined when `--flavor telemetry`. Gates the FPS overlay and per-frame perf scopes (`MiSTerPacer.{cpp,hpp}`, `MISTER_PERF_SCOPE_*`, `mister_perf_*`).

If you add MiSTer-specific code, gate it with `#if defined(RSDK_USE_MISTER)` so non-MiSTer builds aren't affected. If the code is performance-instrumentation-only, additionally gate it with `#if defined(ENABLE_PERF_TELEMETRY) && ENABLE_PERF_TELEMETRY` so the clean release build doesn't carry the cost.

## Troubleshooting

### "Quartus license is single-instance"
Don't run two Quartus flows in parallel. Sequence 4:3 then 16:9, or share a single license file via `MISTER_QUARTUS_LICENSE_FILE`.

### "ld: error: linker command failed due to signal" during HPS build
ThinLTO (`-flto=thin`) was attempted but the cross-build sysroot's binutils ld doesn't grok LLVM bitcode. We don't ship LTO. If you re-add `-flto=thin` to `MiSTer.cmake`, also add `lld` to the build container and `-fuse-ld=lld` to `target_link_options`.

### Pre-existing dirty files in the working tree
This branch typically has a few in-flight WIP files:
- `SonicMania/Objects/Menu/LogoSetup.c` — Phase 10b 224p Logos page-pitch fix
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.{cpp,hpp}` — perf instrumentation
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` — fb-diag instrumentation
- `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp` — per-class draw-cost telemetry
- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` — per-frame spike-log emit hook

These are intentionally uncommitted while the perf-triage cycle is in progress. They'll be either rebased into a single instrumentation commit or reverted before a release.

### "rbf_hide_datecode" hides the dated RBF
Set `rbf_hide_datecode=0` in `/media/fat/MiSTer.ini` if you want the date suffix visible in the menu.

## Risk catalog cross-reference

The [mister-port-playbook](https://github.com/sambae/mister-port-playbook) repo documents every cross-port gotcha encountered during this and the sister `3sx-mister` port. If you're porting another RSDKv5 game (or hitting a similar bug), start there:

- R-12: `MiSTerRenderDevice.cpp` is `#include`d into `Drawing.cpp`, not its own TU
- R-25: `native_video_reader.sv` stale-recovery flash
- R-26: 16:9 RBF patcher leaves ARX/ARY=4/3
- R-27: `Prepare3DScene` memset hides AddModel partial-write
- R-28: Scene3D batching cross-sibling counter trap

## See also

- [`docs/mister-runbook.md`](mister-runbook.md) — operational notes for running on real hardware
- [`docs/mister-rbf-naming.md`](mister-rbf-naming.md) — RBF filename convention and dual-aspect dispatch
- [`docs/mister-settings.md`](mister-settings.md) — Settings.ini and MiSTer.ini reference
- [`docs/mister-wrapper.md`](mister-wrapper.md) — HPS wrapper architecture and lifecycle
