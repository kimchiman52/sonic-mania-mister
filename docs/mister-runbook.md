# MiSTer Runbook (Sonic Mania — Phases 0 + 1 + 2 + 3)

## Scope

This runbook targets stock MiSTer Linux (Cyclone V HPS, Cortex-A9 armhf,
glibc 2.31) with the current Sonic Mania build profile through **Phase 3**:

- Cross-compiled inside Debian 11 + clang-20 Docker container.
- `RETRO_SUBSYSTEM=MiSTer` under `PORT_MISTER=ON` — selects the MiSTer
  render-device backend (Phase 1). Stubs-only for most methods; Phase 2
  wires in the real DDR3 path (see below).
- `USE_SDL_AUDIO=ON` + `RETRO_DISABLE_PLUS=ON`.
- Single static binary (`GAME_STATIC=ON`); engine and game ship together as
  `RSDKv5U`.
- Launcher sets `SDL_VIDEODRIVER=dummy` so SDL2 input/audio initializes
  without trying to open a window. Video output does NOT go through SDL on
  MiSTer — it goes through the MiSTer backend writing directly to DDR3 for
  the FPGA pixel reader to scan out.

### Phase 2 — NativeVideoWriter (live)

- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.{h,c}`
  is a port of 3sx's writer, reparameterized for Mania's 320×240 RGB565
  layout.
- `videoSettings.pixWidth = 320;` is the first statement of
  `MiSTerRenderDevice::Init()`; engine default `424` would mismatch Phase 4
  RTL.
- `FlipScreen()` calls `NativeVideoWriter_WriteFrame(screens[0].frameBuffer,
  320, 240, screens[0].pitch * sizeof(uint16))`. Note: RSDK's
  `ScreenInfo::pitch` is in uint16 pixels, hence the `* sizeof(uint16)`
  byte-conversion. The writer's parameter is therefore named `pitch_bytes`
  to avoid the footgun.
- DDR3 memory map (must match Phase 4 RTL):
  - `NV_DDR_PHYS_BASE = 0x3A000000`, `REGION_SIZE = 0x60000`
  - `CTRL @ 0x0`, `FEEDBACK @ 0x40`
  - `BUF0 @ 0x100` (153,600 B), `BUF1 @ 0x25900` (153,600 B)
  - Control word encoding: `[1:0]=active_buf`, `[31:2]=frame_counter`
- The `.c` file is dual-guarded by `#if defined(__linux__) &&
  defined(PORT_MISTER)` — on Mac host, the writer compiles but `Init()`
  returns `false`; engine logs and continues (no abort).
- `#include "MiSTer/NativeVideoWriter.h"` lives in `Drawing.cpp` above the
  textual `#include "MiSTer/MiSTerRenderDevice.cpp"`, not in
  `MiSTerRenderDevice.cpp` — the Phase 1 "no includes here" guardrail is
  preserved.

Current **exit criterion**: the deployed binary on MiSTer opens `/dev/mem`,
mmaps `0x3A000000`, writes frames into DDR3 with a monotonically advancing
control-word counter, attempts to open `Data.rsdk`, and exits cleanly
whether or not the data file is present. Verify via `busybox devmem
0x3A000000` — the control word should be non-zero and should change
between samples. On Mac, inspect
`~/Library/Application Support/RSDKv5/log.txt` for the expected lines.

### Canary test — does the writer actually run?

Because Mania can't render real pixels without `Data.rsdk`, a canary
test proves the writer pipeline works end-to-end:

```bash
ssh root@192.168.1.188 'busybox devmem 0x3A000000 32 0xDEADBEEF; \
                        busybox devmem 0x3A000100 32 0xCAFEBABE; \
                        busybox devmem 0x3A025900 32 0xFEEDFACE'
# run the binary briefly
ssh root@192.168.1.188 'cd /media/fat/games/SonicMania && timeout 5 ./RSDKv5U'
ssh root@192.168.1.188 'busybox devmem 0x3A000000; busybox devmem 0x3A000100; busybox devmem 0x3A025900'
# expected: ctrl non-zero+changed, BUF0 and BUF1 zeroed (by memset in Init)
```

If ctrl advanced (e.g. to `0x00000009` = frame_counter=2, active_buf=1)
AND BUF0/BUF1 zeroed, the writer mmap'd, memset, and wrote frames.

### Phase 3 — Audio + input (live)

- `MiSTerRenderDevice::Init()` now calls `(void)AudioDevice::Init();` and
  `InitInputDevices();` after the existing Phase 2 Init chain (pixWidth →
  SetupRendering → NativeVideoWriter_Init). The `(void)` cast is
  intentional: `SDL2AudioDevice::Init()` always returns `true` even when
  `SDL_OpenAudioDevice` fails — the `if (!...)` branch would be dead code.
- `ProcessEvent` / `ProcessEvents` are a lift-and-shift from
  `SDL2RenderDevice` (~320 LOC), with the `SDL_WINDOWEVENT` case
  (`SDL2RenderDevice.cpp:697-721`) and the Alt+Enter fullscreen toggle
  (`:819-825`) fully stripped. These don't apply when there's no SDL
  window.
- `MiSTerRenderDevice.hpp` now includes `<SDL2/SDL.h>` — the Phase 1
  "SDL-type-free" comment is updated. The `.cpp` body still has zero
  `#include` lines (guardrail preserved).
- **Upstream bug fix:** `KBInputDevice.cpp` previously gated
  `SDLToWinAPIMappings` on `RETRO_RENDERDEVICE_SDL2`; should have been
  `RETRO_INPUTDEVICE_SDL2`. Without this fix, MiSTer (render=MiSTer,
  input=SDL2) would bypass the scancode remap and fail keyboard bindings.
  Three places widened: function-definition guard at `:13`, and two
  call-site guards at `:822` and `:856`.
- **Release double-call avoidance:** `RenderDevice::Release()` must NOT
  call `AudioDevice::Release()` or `ReleaseInputDevices()`.
  `RetroEngine.cpp:326-328` already does this at engine shutdown.
- Telemetry log line in `SDL2AudioDevice::Init` reports device/freq/
  channels/samples/format/driver after successful open. Gated on
  `#if defined(ENABLE_PERF_TELEMETRY) && ENABLE_PERF_TELEMETRY`.

### Phase 4 — FPGA core (RBF complete, deploy pending)

- `Sonic Mania.rbf` built successfully in colima VM Quartus. 72 min
  wall clock, 0 errors, 78 (expected) warnings.
- Modeline: 320×240 @ 59.587 Hz, pixel clock 6.151 MHz (PLL
  integer-N M=62/N=3/C=42, verified by fitter log).
- Wrapper HPS binary `MiSTer_SonicMania` built (armhf, ~1 MB).
- Deploy procedure: `tools/mister-wrapper/deploy-step5.sh` SCPs RBF +
  wrapper + test-frame-writer to `/media/fat/_Other/` and
  `/media/fat/games/SonicMania/`, then injects the `[Sonic Mania]` section
  with `vga_scaler=0` into `MiSTer.ini`.

### Backend selection chain (Phase 1)

```
-DPORT_MISTER=ON (root CMakeLists.txt)
  → PLATFORM=MiSTer        (forces submodule to load platforms/MiSTer.cmake)
  → RETRO_SUBSYSTEM=MiSTer (forces submodule to emit RSDK_USE_MiSTer=1)
  → MiSTer.cmake also emits RSDK_USE_MISTER=1 (all-caps, for the RetroEngine.hpp arm)
  → RetroEngine.hpp Linux/OSX arms: #if defined(RSDK_USE_MISTER) → RETRO_RENDERDEVICE_MISTER=1
  → Drawing.hpp / Drawing.cpp: #elif RETRO_RENDERDEVICE_MISTER → include MiSTer/MiSTerRenderDevice.hpp
```

All upstream patches (`RetroEngine.hpp`, `Drawing.hpp`, `Drawing.cpp`) are
`#if defined(RSDK_USE_MISTER)`-guarded — non-MiSTer builds see no change.

## Canonical Docker quick start

```bash
bash tools/mister/build-game.sh --flavor telemetry
```

Produces:
- `build/mister-telemetry-install/bin/RSDKv5U` (armhf ELF)
- `build/mister-telemetry-package/bin/RSDKv5U` (deployable copy)
- `build/mister-telemetry-package/scripts/run-mania.sh` (launcher)

Other flavors:
- `--flavor clean` → `build/mister-clean-install/...`, `build/mister-clean-package/...`
- `--flavor both`  → both trees

Stop here unless you're debugging the container/toolchain flow itself.

## Build flavors

| Flavor | `ENABLE_PERF_TELEMETRY` | Target reader |
|---|---|---|
| `telemetry` | `ON`  | developer |
| `clean`     | `OFF` | player |

**In Phase 0 the flavor split is a naming convention**: no telemetry code
exists in Mania yet, so `ENABLE_PERF_TELEMETRY` is purely a compile-time
define that future Phase 6 work can hook onto. The two packages differ only
in path name (`build/mister-telemetry-*` vs `build/mister-clean-*`). See
`docs/phase-0-plan.md` Step 3 for the long-form rationale.

Default for dev is `telemetry` (matches the sibling 3sx-mister convention;
see `feedback-always-telemetry.md`).

## Toolchain

- Debian 11 (Bullseye) base image.
- `clang-20` from `apt.llvm.org`'s Bullseye repo.
- `cmake 3.25.1` from `bullseye-backports`.
- `arm-linux-gnueabihf-gcc 10.2.1` (used for linker + crt1/crti/crtn + gcc
  toolchain includes; clang's `--gcc-toolchain=/usr` picks it up).
- Debian multi-arch `:armhf` cross libs: `libsdl2-dev 2.0.14`,
  `libogg-dev 1.3.4`, `libtheora-dev 1.1.1`, `libasound2-dev`, `zlib1g-dev`,
  `libc6-dev-armhf-cross`, `libstdc++-10-dev-armhf-cross`.
- No `CMAKE_SYSROOT` is set. Debian's multi-arch layout exposes armhf libs
  under `/usr/lib/arm-linux-gnueabihf/` and headers under
  `/usr/include/arm-linux-gnueabihf/`, which clang picks up via
  `--target=arm-linux-gnueabihf --gcc-toolchain=/usr`. Setting
  `CMAKE_SYSROOT` would hide those paths.

### libtheora is cairo-free (built from upstream source)

Debian Bullseye's `libtheora0:armhf` package is linked against
`libcairo2`, which transitively pulls X11, fontconfig, freetype, etc.
**MiSTer's stock rootfs ships none of those.** To avoid bundling a large
dep graph, `tools/mister/build-libtheora.sh` fetches `libtheora 1.1.1`
from xiph.org during container bootstrap and cross-builds it with
`--disable-examples`, producing a `libtheora.so.0` whose only runtime
dep is `libogg.so.0` (which MiSTer ships). `package.sh` bundles these
cairo-free copies into `build/mister-*-package/lib/`. See
`tools/mister/build-libtheora.sh` comments for the full rationale.

### SDL2 2.0.14 API coverage

Bullseye ships SDL2 2.0.14, older than upstream RSDKv5's preferred
2.0.18+. RSDKv5's SDL2 backend (`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp:114`)
already guards all `SDL_RenderGeometryRaw` calls behind
`#if SDL_COMPILEDVERSION >= SDL_VERSIONNUM(2, 0, 18)`, so the code
compiles cleanly against 2.0.14 and falls back to `SDL_RenderCopy`. No
patch required. If upstream adds more 2.0.18+ APIs without a guard,
flag that as a Phase 7 polish.

**Pre-flight coverage check (run from repo root):**

```bash
# How many unique SDL_* symbol references exist in the engine?
grep -rhoE "SDL_[A-Z][a-zA-Z_]+" dependencies/RSDKv5/RSDKv5/RSDK/ | sort -u | wc -l
# 2026-04-24 on dependencies/RSDKv5 @ 2203458: 202

# Where are the post-2.0.14 APIs used? Each hit must be #if-guarded.
grep -rn "SDL_RenderGeometry\|SDL_RenderGeometryRaw" \
    dependencies/RSDKv5/RSDKv5/RSDK/
# All 11 hits live in SDL2RenderDevice.cpp inside the
# #if (SDL_COMPILEDVERSION >= SDL_VERSIONNUM(2, 0, 18)) block (line 114
# through line 196). The #else branch falls back to SDL_RenderCopy.
```

Findings as of 2026-04-24: 202 unique SDL symbols referenced.
`SDL_RenderGeometryRaw` (2.0.18+) is the only post-2.0.14 API; all 11
call sites are behind the version guard. `SDL_OpenURL` (2.0.14) appears
once in `User/Dummy/DummyCore.cpp:116` but is exactly our floor.
`SDL_RenderSetLogicalSize` and similar are ancient. Nothing else
requires patching.

Re-run the two greps whenever the RSDKv5 submodule bumps; a new
unguarded 2.0.16+/2.0.18+ hit is a Phase 7 follow-up.

### Bundling deviation from `phase-0-plan.md`

The plan Step 4 said **do not create `${output_dir}/lib/` in Phase 0**.
Implementation deviates: `tools/mister/package.sh` does stage
`${output_dir}/lib/` and bundles cairo-free libtheora + libtheoradec
there. Reason: MiSTer's stock rootfs ships neither SONAME, so the
binary cannot load without them and the Phase 0 smoke test fails before
reaching the Data.rsdk path that the exit criterion actually targets.

Scope of the deviation is limited to those two libraries and the
corresponding `LD_LIBRARY_PATH` prepend in `run-mania.sh`. Everything
else the plan deferred (SDL2 rehoming, license bundles, OSD launcher
wrappers, full dep-graph bundling) stays deferred until Phase 7. See
the explanatory block at the top of `tools/mister/package.sh` for
the parallel comment that lives with the code.

## Manual Docker bootstrap (for debugging)

```bash
bash tools/mister/setup-build-container.sh
```

Installed packages (amd64 side): `build-essential ca-certificates curl git
gpg make pkg-config rsync zlib1g-dev cmake clang-20`. Installed packages
(armhf cross): `gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf
libc6-dev-armhf-cross libstdc++-10-dev-armhf-cross libasound2-dev:armhf
zlib1g-dev:armhf libsdl2-dev:armhf libogg-dev:armhf libtheora-dev:armhf`.

Idempotent: rerun completes in seconds if the container exists and the
packages are installed.

Verify:
```bash
docker exec sonic-mania-mister-arm-build clang-20 --version
docker exec sonic-mania-mister-arm-build cmake --version
docker exec sonic-mania-mister-arm-build arm-linux-gnueabihf-gcc --version
docker exec sonic-mania-mister-arm-build bash -lc \
    'PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig pkg-config --modversion sdl2 ogg theora'
```

## Cross-compile invocation (reference)

The build driver runs this inside the container. You almost never need to
run it by hand; keep this as a reference for future debugging.

```bash
docker exec sonic-mania-mister-arm-build bash -lc '
set -euxo pipefail
cd /work-mister
export CC=clang-20 CXX=clang++-20
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
export CFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr"
cmake -S . -B build/mister-telemetry \
    -DCMAKE_BUILD_TYPE=Release \
    -DPORT_MISTER=ON \
    -DGAME_STATIC=ON \
    -DRETRO_SUBSYSTEM=SDL2 \
    -DUSE_SDL_AUDIO=ON \
    -DRETRO_DISABLE_PLUS=ON \
    -DENABLE_PERF_TELEMETRY=ON \
    -DCMAKE_C_COMPILER_TARGET=arm-linux-gnueabihf \
    -DCMAKE_CXX_COMPILER_TARGET=arm-linux-gnueabihf
cmake --build build/mister-telemetry --parallel 2
cmake --install build/mister-telemetry --prefix build/mister-telemetry-install
'
```

Humans may equivalently invoke `cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mister.cmake ...`
instead of the env-var form; both paths produce the same binary.

## Binary verification

After `build-game.sh` completes:

```bash
file    build/mister-telemetry-install/bin/RSDKv5U
readelf -h build/mister-telemetry-install/bin/RSDKv5U | grep Machine
readelf -A build/mister-telemetry-install/bin/RSDKv5U | grep -iE 'Tag_CPU_name|Tag_ABI_VFP_args|Tag_Advanced_SIMD_arch'
readelf -d build/mister-telemetry-install/bin/RSDKv5U | grep NEEDED
```

Expected:
- `file` reports `ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked, ...`
- `Machine: ARM`
- `Tag_ABI_VFP_args: VFP registers` present, `Tag_CPU_name: "7-A"` or equivalent.
- NEEDED list should be a subset of: `libSDL2-2.0.so.0`, `libogg.so.0`,
  `libtheora.so.0`, `libtheoradec.so.1`, `libvorbis*`, `libasound.so.2`,
  `libstdc++.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`,
  `libz.so.1`, `libc.so.6`, `libgcc_s.so.1`. No `libGL*`, `libX11`, `libxcb*`.

`build-game.sh` runs the `readelf -h` and `readelf -A` grep checks
automatically and fails hard if either misses.

## Deploy to MiSTer

```bash
MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 \
    bash tools/mister/deploy-to-mister.sh
```

Copies `build/mister-telemetry-package/` to
`/media/fat/games/SonicMania/` via `rsync` over `ssh` (using `sshpass` to
pass the stock MiSTer `1` password). Safety:

- Never uses `rsync --delete`; preserves any `Data.rsdk` + save files
  already on device. (See memory `feedback-no-rsync-delete.md`.)
- Remote path is whitelist-checked against `/media/fat/games/SonicMania`.
  Retarget via `MISTER_REMOTE_BASE`, but the whitelist will reject any
  other path until updated deliberately.
- `MANIA_FLAVOR=clean` switches to the clean-flavor package.

On the MiSTer after deploy:
```bash
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'ls -la /media/fat/games/SonicMania/bin/'
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'file /media/fat/games/SonicMania/bin/RSDKv5U'
```
The `file` output on-device must match what the host reported.

## Pre-deploy SSH probe

Before running the binary on device, confirm MiSTer's shared libraries
cover the binary's NEEDED list and glibc is 2.31:

```bash
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 \
    'ldconfig -p | grep -E "libSDL2|libogg|libtheora|libasound|libstdc\+\+"'

sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'ldd --version | head -1'
```

Expected: `libSDL2-2.0.so.0`, `libogg.so.0`, `libtheora.so.0`,
`libtheoradec.so.1`, `libasound.so.2`, `libstdc++.so.6` all present.
`ldd --version` on stock MiSTer is `(Debian GLIBC 2.31-...) 2.31`.

If any SONAME is missing on device, extend `tools/mister/package.sh` to
bundle the missing lib under `build/mister-*-package/lib/` and extend
`run-mania.sh` to set `LD_LIBRARY_PATH`. (Deferred — not expected in
Phase 0.)

## Smoke test on device

```bash
sshpass -p "${MISTER_PASSWORD}" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@192.168.1.188 \
    'timeout -s TERM 10 /media/fat/games/SonicMania/scripts/run-mania.sh' \
    2>&1 | tee /tmp/mania-smoke.log
```

`timeout -s TERM 10` bounds the run to 10 seconds; the exit criterion is
that the engine terminates **on its own** before the timeout fires. A run
that reaches 10s and gets SIGTERM'd by the wrapper is a FAIL (the engine
is most likely spinning inside `SDL_CreateRenderer`, see the M4 branch in
`docs/phase-0-plan.md` Step 7).

A passing `/tmp/mania-smoke.log` shows either:
1. An engine banner line + a Data.rsdk open-attempt log (e.g.
   `fopen("Data.rsdk"...) failed`, or "Attempting to load user file..."),
   followed by a non-zero exit code from the engine itself;
2. An SDL2-backend init message + a clean bail-out (if
   `SDL_CreateRenderer` fails under `SDL_VIDEODRIVER=dummy`, the engine
   logs and exits).

## Required game data

`Data.rsdk` is NOT shipped. User supplies. Upload separately (for example
`scp Data.rsdk root@192.168.1.188:/media/fat/games/SonicMania/`). The
deploy script intentionally does not touch `Data.rsdk`.

## Troubleshooting

### libtheora bootstrap failed (half-configured container)

`setup-build-container.sh` runs `build-libtheora.sh` inline as its last
step. If that step aborts (xiph tarball mirror was down, a transient
network failure, missing `autoconf`, etc.), the container ends up with
cross packages installed but no `/work-theora-install/` tree; `package.sh`
then falls back to Debian's cairo-linked libtheora and the resulting
binary cannot run on MiSTer.

Manual recovery (does not require re-bootstrapping the container from
scratch):

```bash
# Re-runs the whole upstream xiph fetch + cross-build. --force wipes
# any partial state under /tmp/theora-* inside the container.
docker exec sonic-mania-mister-arm-build \
    bash /src/tools/mister/build-libtheora.sh --force

# Confirm the cairo-free libs now exist:
docker exec sonic-mania-mister-arm-build \
    ls -la /work-theora-install/lib/
```

If the failure was transient, the rerun usually succeeds. If the xiph
tarball URL itself is unreachable, mirror the tarball manually into
`/work-theora-src/libtheora-1.1.1.tar.bz2` inside the container (the
script reuses a cached tarball if it finds one), or edit the
`THEORA_TARBALL_URL` at the top of `build-libtheora.sh` to point at
a mirror.

Once `/work-theora-install/` is populated, rerun `bash
tools/mister/build-game.sh --flavor telemetry`; `package.sh` will
prefer the cairo-free copies automatically.

### Build errors

| Symptom | Likely cause | Fix |
|---|---|---|
| `libtheora not found via pkg-config` in `MiSTer.cmake` | `libtheora-dev:armhf` missing in container | `docker exec sonic-mania-mister-arm-build apt-get install -y libtheora-dev:armhf` or rerun `setup-build-container.sh`. |
| clang emits `argument unused during compilation: '--gcc-toolchain=/usr'` on link | `LDFLAGS` not propagated | Ensure `CFLAGS`, `CXXFLAGS`, `LDFLAGS` each independently carry `--target=` + `--gcc-toolchain=`. |
| `/usr/bin/ld: unrecognised emulation mode` | clang picked `lld` instead of GNU ld | Add `-fuse-ld=bfd` to link flags. 3sx doesn't need this, flag if it hits. |
| `ModAPI.cpp` fails to find `<filesystem>` | `libstdc++-10-dev-armhf-cross` missing | Rerun `setup-build-container.sh`. Bullseye GCC 10 libstdc++ ships `<filesystem>` without needing `-lstdc++fs`. |
| broken `Game` symlink in repo root | Cosmetic | Ignore. The build uses `SonicMania/` via `GAME_NAME` default. |

### Deploy errors

| Symptom | Fix |
|---|---|
| `sshpass: not found` on macOS | `brew install hudochenkov/sshpass/sshpass`. |
| `Host key verification failed` | Already disabled via `-o StrictHostKeyChecking=no`. If still firing, confirm `UserKnownHostsFile=/dev/null` is in the ssh args. |
| `Connection refused` | Confirm MiSTer is at `192.168.1.188` (or set `MISTER_HOST`). |
| `rsync: read error` mid-copy | Transient; re-run. If persistent, `df -h` on device to check free space. |
| `refusing to deploy to non-whitelisted remote base` | Update the whitelist in `deploy-to-mister.sh` deliberately; do not bypass. |

### Smoke-test failures

| Symptom | Interpretation |
|---|---|
| `error while loading shared libraries: libtheora.so.0` | MiSTer lacks the SONAME. Extend `package.sh` + launcher to bundle. |
| `error while loading shared libraries: libSDL2-2.0.so.0` | Ditto for SDL2. Inspect `ls /lib/*sdl* /usr/lib/*sdl*` on device. |
| Hangs past 10s, killed by `timeout` | `SDL_CreateRenderer` is spinning. Phase 0 FAIL — escalate to Phase 1 SDL2 backend NULL-check patch. |
| `Illegal instruction` | VFP/NEON mismatch. Check `readelf -A` vs `cat /proc/cpuinfo` on device. |
| `Segmentation fault` at startup | PIE/ASLR interaction. Try building with `-no-pie` via `EXTRA_CMAKE_ARGS="-DCMAKE_EXE_LINKER_FLAGS=-no-pie"`. |

## Memory / feedback cross-refs

- `feedback-always-telemetry.md` — default dev flavor is `telemetry`.
- `feedback-no-rsync-delete.md` — deploy never uses `rsync --delete`.
- `feedback-read-runbooks-before-deploy.md` — this file is the runbook to
  read before shipping Phase 0 binaries.
- `reference-mister-credentials.md` — `MISTER_HOST=192.168.1.188`, stock
  password is `1`.
- `feedback-debug-build-for-live-tests.md` — Phase 1+ lives tests should
  ship DEBUG-flavor binaries with diagnostics on. Phase 0 ships Release
  because we are verifying toolchain plumbing, not investigating behavior.

## Phase 0 post-conditions (what Phase 1 inherits)

1. Working `tools/mister/setup-build-container.sh` + `build-game.sh`
   producing armhf ELFs under `build/mister-telemetry-install/`.
2. `PORT_MISTER=1`, `RETRO_MISTER=1`,
   `ENABLE_PERF_TELEMETRY={0,1}` defines flowing through the build.
3. `dependencies/RSDKv5/platforms/MiSTer.cmake` — place to add
   `Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}` sources in Phase 1.
4. `deploy-to-mister.sh` + launcher suitable for a Phase 1 skeleton
   backend that still runs on stock SDL2 + MiSTer side-by-side.

Phase 1's `RETRO_RENDERDEVICE_MISTER` wiring and the 4-line backend
dispatch edits to `Drawing.hpp` / `Drawing.cpp` are **out of scope** for
this runbook. See `docs/phase-1-plan.md`.
