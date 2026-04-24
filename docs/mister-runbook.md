# MiSTer Runbook (Sonic Mania — Phase 0)

## Scope

This runbook targets stock MiSTer Linux (Cyclone V HPS, Cortex-A9 armhf,
glibc 2.31) with the **Phase 0** Sonic Mania build profile:

- Cross-compiled inside Debian 11 + clang-20 Docker container.
- SDL2 subsystem + `USE_SDL_AUDIO=ON` + `RETRO_DISABLE_PLUS=ON`.
- Single static binary (`GAME_STATIC=ON`); engine and game ship together as
  `RSDKv5U`.
- No MiSTer render backend yet (Phase 1); launcher forces
  `SDL_VIDEODRIVER=dummy` so the stock SDL2 backend can at least initialize.

Phase 0 **exit criterion**: the deployed binary starts on MiSTer, attempts
to open `Data.rsdk`, and exits cleanly within 10 seconds whether or not
the data file is present. No rendering, no controller, no audio are
required.

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
