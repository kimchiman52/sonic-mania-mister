# Phase 0 — Cross-compile Plumbing — Implementation Plan

**Document date:** 2026-04-24
**Status:** Plan under review. Do not implement until signed off.
**Parent docs:** [mister-port-research.md](mister-port-research.md), [mister-port-plan.md](mister-port-plan.md) (Phase 0 section)
**Sibling reference tree:** `/Users/sb/Developer/3sx-mister/` — the working MiSTer port of SF3:3S, source of the Docker + clang-20 + armhf flow we are mirroring.

---

## Scope of this plan

Produce the cross-compile plumbing that turns an unmodified macOS checkout of `sonic-mania-mister` into an `armhf` MiSTer-ready `RSDKv5U` executable, built inside Docker, deployable to MiSTer HPS over SSH.

**Phase 0 stops at "binary runs on MiSTer and exits on missing Data.rsdk."** No MiSTer backend code, no native video writer, no FPGA work. Those are Phase 1+.

### Baked-in decisions (DO NOT revisit in this plan)

- Target triple: `arm-linux-gnueabihf`
- Compiler: `clang-20` from `apt.llvm.org` Bullseye repo
- `GAME_STATIC=ON` (single executable; no runtime `libGame.so`)
- `RETRO_SUBSYSTEM=SDL2` + `USE_SDL_AUDIO=ON`
- `RETRO_DISABLE_PLUS=ON`
- Cutscenes stubbed at runtime only; build still links against `libogg` + `libtheora` because `Video.cpp` is compiled unconditionally when `RETRO_REV0U` is ON (default). See Architectural Fact #3.
- Telemetry flavor mirrors 3sx's split (telemetry default for dev, clean for player)

### Exit criteria (phase-level)

1. `tools/mister/build-game.sh --flavor telemetry` on macOS produces, under `build/mister-telemetry-install/bin/`, an ELF reported by `file` as:
    > `ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked, ...`
2. `readelf -h` reports `Machine: ARM`; `readelf -A` shows `Tag_ABI_VFP_args: VFP registers`.
3. SCP to MiSTer target (`192.168.1.188`), run over SSH, binary starts, opens required shared objects (verified via `ldd`/`strace`), reaches the `Data.rsdk` read path, exits cleanly (non-crash) because the file is absent.
4. `docs/mister-runbook.md` (new) documents the flow end-to-end.

### Out of scope for Phase 0

- `MiSTerRenderDevice.cpp/hpp` (Phase 1)
- `NativeVideoWriter.{c,h}` (Phase 2)
- FPGA / RTL work (Phase 4)
- Wrapper HPS binary (Phase 4)
- Any game data packaging (user supplies `Data.rsdk`)
- Changes to upstream engine source beyond the minimum needed to make the build succeed with Decisions baked in

---

## Architectural facts driving this plan

These are load-bearing facts confirmed by reading code and docs; every later step depends on them.

1. **Build shape is two-tiered.** Root `CMakeLists.txt` (`sonic-mania-mister/CMakeLists.txt`) defines the `SonicMania` game target and `add_subdirectory(dependencies/RSDKv5)`. When `GAME_STATIC=ON` (decision #4), the engine executable `RetroEngine` (output name `RSDKv5U`) links against the `SonicMania` static library. One binary comes out: `RSDKv5U`.
2. **`Linux.cmake` is the template.** `dependencies/RSDKv5/platforms/Linux.cmake` drives dep discovery via `pkg-config`. For SDL2 subsystem: `pkg_check_modules(SDL2 sdl2 REQUIRED)`. For ogg: optional (`COMPILE_OGG=TRUE` triggers in-tree build of bundled `dependencies/android/libogg` if pkg-config fails). For theora: optional too, but there is a hidden catch — `dependencies/android/libtheora` is **not present in this tree** (only `libogg` is vendored). If pkg-config cannot find `theora`, `COMPILE_THEORA=TRUE` will fire and the build **will fail** at `add_library(libtheora STATIC dependencies/android/libtheora/lib/analyze.c ...)` because those sources do not exist. See `dependencies/RSDKv5/CMakeLists.txt:96-134`.
3. **`Video.cpp` theora code is gated by `RETRO_REV0U`** (`RETRO_REVISION >= 3`). Default is 3. So with a REV0U build, `Video.cpp` WILL try to link against `th_*` / `ogg_*` / `theora_*` symbols even if cutscenes are "stubbed" at the engine level. The plan therefore treats the theora linker need as real, and resolves it by either (a) installing `libtheora-dev:armhf` from Debian Bullseye into the sysroot, or (b) using a small upstream patch that `#ifdef`s out the theora code paths when a `RETRO_DISABLE_VIDEO` define is set. Option (a) is cheaper and lets us defer the upstream patch to Phase 5/7 if ever needed. **Note:** `RETRO_DISABLE_PLUS=ON` does NOT disable the theora code — it only affects Plus DLC content gating. Do not confuse the two.
4. **stb_vorbis is vendored header-only** at `dependencies/RSDKv5/dependencies/all/stb_vorbis/stb_vorbis.c` and does NOT require `libogg` at link time. Earlier worry about `stb_vorbis` pulling libogg is wrong. The only ogg consumer is `Video.cpp`. (Verified — see `Audio.cpp:12` which does `#include "stb_vorbis/stb_vorbis.c"` with `STB_VORBIS_NO_*` guards; confirms no external libogg pull-in from the audio path.)
5. **Backend dispatch macros use `_DIRECTX9`/`_DIRECTX11`, not `_DX9`/`_DX11`.** Verified at `Drawing.hpp:245-257` and `Drawing.cpp:133-146`: the `#elif` chain uses `RETRO_RENDERDEVICE_DIRECTX9`, `RETRO_RENDERDEVICE_DIRECTX11`, `RETRO_RENDERDEVICE_SDL2`, `RETRO_RENDERDEVICE_GLFW`, `RETRO_RENDERDEVICE_VK`, `RETRO_RENDERDEVICE_EGL`. The research doc's §2.4 paraphrases some of these as `RETRO_RENDERDEVICE_DX9` — that shorthand does NOT appear in the source. Phase 1's future patch must use the long names.
6. **`RSDK_USE_SDL2=1` is sufficient to activate the SDL2 backend.** `RetroEngine.hpp:262-264` translates `RSDK_USE_SDL2` into `RETRO_RENDERDEVICE_SDL2=1` automatically, and `dependencies/RSDKv5/CMakeLists.txt:155` already sets `RSDK_USE_${RETRO_SUBSYSTEM}=1` based on the `RETRO_SUBSYSTEM` cache var. So when the build driver passes `-DRETRO_SUBSYSTEM=SDL2`, everything downstream lights up. We MUST NOT re-define `RETRO_RENDERDEVICE_SDL2` ourselves — doing so will trigger `-Wmacro-redefined`.
7. **3sx's Docker flow uses no custom Dockerfile.** `tools/mister/setup-build-container.sh` (3sx) pulls vanilla `debian:11` (not `debian:11-slim`) and runs `apt-get` inside. That same pattern is reused here verbatim — we inherit `clang-20` from `apt.llvm.org`, cmake 3.25.1 from `bullseye-backports`, and `*:armhf` cross packages from Debian multi-arch. **No Dockerfile under `tools/mister/docker/` is needed** (earlier prompt assumed one; the 3sx pattern is simpler). The plan delivers a setup script, not an image definition.
8. **Cross-build uses clang `--target=`, not `CMAKE_SYSROOT`.** 3sx proves this works: env vars carry `--target=arm-linux-gnueabihf` and `--gcc-toolchain=/usr` with `-isystem /usr/arm-linux-gnueabihf/include`. clang finds libstdc++, libc, linker, and lib paths through the GCC installation that Debian's `gcc-arm-linux-gnueabihf` + `libstdc++-10-dev-armhf-cross` packages provide. `CMAKE_SYSROOT=/usr/arm-linux-gnueabihf` would be WRONG — that path is only the cross-compiler's internal include prefix, not a full sysroot, and setting `CMAKE_SYSROOT` to it would hide the multi-arch `/usr/lib/arm-linux-gnueabihf/` and `/usr/include/arm-linux-gnueabihf/` directories that host our SDL2/theora/ogg libs. The toolchain file we deliver uses the 3sx env-var pattern without `CMAKE_SYSROOT`.
9. **No existing `install(TARGETS RetroEngine ...)` rule.** Grep of `dependencies/RSDKv5/CMakeLists.txt` and `dependencies/RSDKv5/platforms/*.cmake` confirms: no install target anywhere. `cmake --install` would be a no-op for `RetroEngine`. Our `MiSTer.cmake` must add one.
10. **Broken `Game/` symlink.** A stale `Game -> Sonic Mania` symlink sits in the repo root; the actual game source is `SonicMania/`. Root `CMakeLists.txt:32` defaults `GAME_NAME` to `SonicMania`, so the build is fine. But the symlink's presence may confuse newcomers or IDEs. Not a Phase 0 blocker.
11. **Exit code 20 is 3sx's analog, not ours.** 3sx exits with code 20 on missing assets. RSDKv5 doesn't — it `PrintLog`s and reaches the game init loop regardless. Our "exit criteria" for Phase 0 is "the engine process starts, logs its init banner, attempts to open `Data.rsdk`, and terminates cleanly (no segfault, no linker error at runtime)." We do not require an engineered exit code in Phase 0.

---

## Deliverables summary

| # | Deliverable | Path | Size estimate |
|---|---|---|---|
| D1 | Setup-container script | `tools/mister/setup-build-container.sh` | ~130 lines, ported from 3sx |
| D2 | Game build driver | `tools/mister/build-game.sh` | ~180 lines, ported+adapted from 3sx |
| D3 | Package staging script | `tools/mister/package.sh` | ~60 lines, adapted (simpler than 3sx) |
| D4 | Deploy script | `tools/mister/deploy-to-mister.sh` | ~80 lines, new (3sx uses bigger `misterctl.sh`; we keep Phase 0 deploy minimal) |
| D5 | CMake toolchain file | `cmake/toolchain-mister.cmake` | ~40 lines, new |
| D6 | CMake options: `PORT_MISTER` + flavor | edits to `CMakeLists.txt` (root) + `dependencies/RSDKv5/platforms/MiSTer.cmake` (new) | ~30 lines edits + ~60 lines new |
| D7 | Runbook | `docs/mister-runbook.md` | ~200 lines, new |
| D8 | Tools README | `tools/mister/README.md` | ~50 lines, new |

The new `platforms/MiSTer.cmake` in D6 is the minimum that lets a MiSTer build pick up the correct deps and flags; it is **not** the backend file. It is a platform dep file that looks almost exactly like `Linux.cmake` but adds our defines/flags. The backend `Graphics/MiSTer/` directory is Phase 1.

---

## Dependency order / bring-up

```
Step 1 (Docker container bootstrap) ───┐
                                        ├── Step 4 (toolchain file, build driver)
Step 2 (host-baseline macOS build)  ────┤
                                        ├── Step 5 (end-to-end armhf build)
Step 3 (MiSTer platform CMake shim) ────┘
                                                │
                                                ├── Step 6 (package + deploy scripts)
                                                │
                                                └── Step 7 (MiSTer-side smoke run)
                                                                │
                                                                └── Step 8 (runbook + README)
```

Step 2 (macOS baseline) is a risk-mitigation dry run: it confirms the tree builds *at all* with our flags, before we pay the Docker setup cost. Skippable if the agent has already verified it manually, but the plan keeps it in for determinism.

---

## Step 1 — Docker container bootstrap script

### Title

Port the 3sx `setup-build-container.sh` pattern to `sonic-mania-mister`, adapted for Mania's dep list.

### Why it matters

Unlocks every later step. Without a reproducible Debian 11 + clang-20 + armhf cross env, no cross-build is possible. 3sx's pattern is battle-tested; reusing it verbatim is low-risk and saves writing a Dockerfile from scratch.

### Files to read first (mandatory)

- `/Users/sb/Developer/3sx-mister/tools/mister/setup-build-container.sh` (170 lines, the canonical pattern)
- `/Users/sb/Developer/3sx-mister/docs/mister-runbook.md` lines 44-82 (toolchain rationale)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Linux.cmake` (Mania's dep list)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/CMakeLists.txt` lines 80-134 (libogg/libtheora conditional build)

### Files to create/modify

- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/setup-build-container.sh`
  - Copy 3sx's script as baseline.
  - Default container name: `sonic-mania-mister-arm-build` (not 3sx's `3s-mister-arm-build`).
  - Default platform: `linux/amd64`.
  - Default LLVM: `20`.
  - Debian base: `debian:11` (same as 3sx).
  - Sources.list: same Bullseye + bullseye-updates + security + bullseye-backports.
  - LLVM repo: `http://apt.llvm.org/bullseye/ llvm-toolchain-bullseye-20 main`.
  - Base packages (amd64 side): `build-essential ca-certificates curl git gpg make pkg-config rsync zlib1g-dev`. **DIVERGES FROM 3sx:** drop amd64 `libasound2-dev` (and do not add amd64 `libsdl2-dev`). Debian Bullseye's `libsdl2-dev` and `libasound2-dev` have historical multi-arch co-presence conflicts between amd64 and armhf `-dev` copies (different header-shipping posture across arches). We install **only** the armhf variants (listed below) because the `-dev` headers are needed only for the cross-compile target, NOT for the amd64 host side (nothing on the host links against SDL2/ALSA in our pipeline).
  - CMake: `apt-get install -y -t bullseye-backports cmake` (>= 3.25 required; upstream RSDKv5 needs only 3.10 but our toolchain-mister.cmake pattern prefers 3.24+).
  - Clang: `apt-get install -y clang-20`.
  - **armhf cross packages** (CRITICAL LIST, differs from 3sx by adding theora/ogg/sdl2/mesa). Install **only the `:armhf` variants** of the `-dev` packages — never the amd64 side. Debian's multi-arch `-dev` copresence for libsdl2/libasound is fragile on Bullseye:
    ```
    gcc-arm-linux-gnueabihf
    binutils-arm-linux-gnueabihf
    libc6-dev-armhf-cross
    libstdc++-10-dev-armhf-cross
    libasound2-dev:armhf        # armhf-only (M1/M3): do NOT install amd64 libasound2-dev
    zlib1g-dev:armhf
    libsdl2-dev:armhf           # armhf-only (M1): do NOT install amd64 libsdl2-dev
                                # NEW vs 3sx (3sx builds SDL3 from source; Mania uses distro SDL2)
    libogg-dev:armhf            # NEW vs 3sx (Mania's Video.cpp needs ogg linker symbols)
    libtheora-dev:armhf         # NEW vs 3sx (Mania's Video.cpp needs theora linker symbols)
    ```
  - NOTE: 3sx uses SDL3 built from source; we intentionally diverge and use Debian's `libsdl2-dev:armhf` because (a) RSDKv5's SDL2 backend expects SDL 2.x APIs, (b) Bullseye ships SDL2 ≥ 2.0.14 (the exact version depends on what Debian's stable updates stream has) which covers all SDL2 symbols RSDKv5 uses, (c) eliminates the "build SDL first" step entirely.

  - **M2 Pre-flight (Bullseye SDL 2.0.14 symbol coverage).** Before committing to the distro SDL2 pin, run this grep at the repo root to enumerate every SDL2 symbol the engine uses, and cross-reference the list against SDL2 2.0.14's symbol table (upstream `SDL/WhatsNew.txt` or `libsdl2-2.0-0` dpkg `objdump -T`):
    ```bash
    grep -rhn "SDL_[A-Z][a-zA-Z_]*" dependencies/RSDKv5/RSDKv5/RSDK/ \
        | grep -oE "SDL_[A-Z][a-zA-Z_]*" | sort -u
    ```
    Known tight APIs to flag:
    - `SDL_GameControllerHasButton` — requires SDL 2.0.14+ (OK on Bullseye 2.0.14).
    - `SDL_GameControllerGetSensorData` — requires SDL 2.0.14+ (OK on Bullseye 2.0.14).
    - `SDL_RenderGeometry` — requires SDL **2.0.18+**. **If used, Bullseye's 2.0.14 will NOT work** and we must either build SDL2 from source (mirroring 3sx's SDL3 pattern) or drop to a conditional stub. Flag as a Step-1 blocker if the grep hits `SDL_RenderGeometry`.

    Document this as a mandatory pre-commit check in the runbook. Not a verification script in Phase 0; the implementer runs it manually and records the findings.
  - DO NOT add `libvorbis-dev:armhf` "just in case." stb_vorbis is header-only and vendored; SDL2's core build doesn't pull vorbis. Only `SDL2_mixer` would — we don't use it.
  - Verify post-install: `clang-20 --version`, `cmake --version`, `arm-linux-gnueabihf-gcc --version`, `dpkg -l libsdl2-dev:armhf libogg-dev:armhf libtheora-dev:armhf`.
  - Final printed summary: container=, platform=, cross_build=, src_mount=/src, sdl2_armhf=<version>, ogg_armhf=<version>, theora_armhf=<version>.

- **Do NOT create** a `Dockerfile` or `tools/mister/docker/` directory. The original user prompt asked for one, but the 3sx pattern avoids custom images by running `apt` against vanilla `debian:11`. This plan deliberately inherits that decision.

### Success criteria

Running from project root:
```bash
bash tools/mister/setup-build-container.sh
```
produces (idempotent on re-run):
- A running Docker container named `sonic-mania-mister-arm-build`.
- `docker exec sonic-mania-mister-arm-build clang-20 --version` reports 20.x.
- `docker exec sonic-mania-mister-arm-build cmake --version` reports 3.25.x or later.
- `docker exec sonic-mania-mister-arm-build dpkg -l libsdl2-dev:armhf` shows installed.
- `docker exec sonic-mania-mister-arm-build dpkg -l libogg-dev:armhf libtheora-dev:armhf` shows both installed.
- `docker exec sonic-mania-mister-arm-build bash -lc 'pkg-config --cflags --libs sdl2 2>&1; echo "---"; PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig pkg-config --cflags --libs sdl2'` succeeds and prints hardfloat paths on the second call.
- Second run completes in < 5 seconds (existing container reused, apt-get no-op).

### Dependencies

None. This is the root of the DAG.

### What NOT to do

- Do not write a `Dockerfile`.
- Do not install Quartus, Mono, or anything FPGA-related.
- Do not install GLFW/GLEW — Mania's SDL2 subsystem doesn't use them.
- Do not install `libglew-dev:armhf` even though PortMaster does — we don't need it for SDL2 path.
- Do not change the default Debian base (no `debian:bookworm`). 3sx is validated on bullseye and glibc skew with MiSTer's Linux 5.15 + glibc 2.31 requires sticking with Bullseye (see "glibc skew" note below).
- Do not use `apt-get upgrade` blanket — stick to targeted installs for reproducibility.

### What to do if it fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `Get:1 http://apt.llvm.org ... 403 Forbidden` | LLVM infrastructure churn | Try `clang-19` or `clang-18` as transitional. The runbook notes that clang-20 is the 2026-03 pin; older versions may also work. If all fail, unblock by commenting the LLVM sources.list line and verify that distro `clang` (13.x on Bullseye) compiles upstream RSDKv5 sources. Expected per 3sx experience: GCC 10 fails, clang may too — escalate rather than ship with distro clang. |
| `E: Unable to locate package libtheora-dev:armhf` | multiarch misconfigured | Check `dpkg --print-foreign-architectures` inside the container; `dpkg --add-architecture armhf` must precede the second `apt-get update`. |
| `exec format error` when starting container | user set `--platform linux/arm/v7` without binfmt_misc | Fall back to default `linux/amd64`. |
| Bind-mount ownership errors on macOS Docker Desktop | `tar --same-owner` from vendored archives | Not relevant in Step 1 (no tar extraction yet); becomes relevant in Step 4's inner build. |

### Rough effort

1 focused session. Mostly typing + verification.

---

## Step 2 — macOS host baseline build (sanity dry run)

### Title

Configure and build the project on macOS with no MiSTer flags, to prove the tree compiles cleanly before we touch cross-compile.

### Why it matters

Catches bitrot in the checkout independent of our Docker/cross work. If the host build is broken, the cross build will be broken too and we'll waste sessions chasing ghosts. Research doc §6.1 calls this out as the "first concrete step."

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/CMakeLists.txt` (full)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/CMakeLists.txt` (full)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Darwin.cmake` (confirm it exists; research doc §4 implies it does)

### Files to create/modify

None. This step is **read/verify only** plus a scratch build directory (`build/host/`).

### Success criteria

From project root:
```bash
brew install sdl2 libtheora libogg pkg-config
# Note: no glew/glfw — RSDKv5's SDL2 subsystem doesn't need them. Only install them
# if you're experimenting with the GLFW/OGL subsystems (not our target).
cmake -S . -B build/host -DCMAKE_BUILD_TYPE=Release -DRETRO_SUBSYSTEM=SDL2 -DUSE_SDL_AUDIO=ON -DRETRO_DISABLE_PLUS=ON
cmake --build build/host --parallel
file build/host/dependencies/RSDKv5/RSDKv5U
```
must produce a Mach-O 64-bit executable (`RSDKv5U` or `.app` bundle — Darwin.cmake path dependent). Document which. Additional sanity checks:
- `ls SonicMania/` lists `Game.c`, `All.h`, `Objects/` — confirms the repo layout the root `CMakeLists.txt` expects.
- `ls Game` returns `broken symbolic link to Sonic Mania` on macOS — harmless, no code path depends on it. Document in Step 8's troubleshooting.

Phase 0 baseline intentionally does NOT force `GAME_STATIC=ON` on macOS; baseline matches upstream defaults so any breakage we see is attributable to the upstream checkout, not our flags.

### Dependencies

None (independent of Step 1). Can run in parallel with Step 1 on a dev laptop.

### What NOT to do

- Do not write any MiSTer-specific code.
- Do not attempt to run the binary; we're only proving it links.

### What to do if it fails

| Symptom | Fix |
|---|---|
| Homebrew missing packages | `brew install` the listed deps. |
| CMake complains about `GAME_STATIC` on UNIX | The root CMakeLists defaults it to OFF on UNIX (`CMakeLists.txt:9-10`). Explicit `-DGAME_STATIC=ON` overrides; if CMake still fights, inspect `CMakeLists.txt:16` — the `option()` default uses a generator-expression that may not expand as expected. Fall back to editing the project-level default. |
| Darwin.cmake missing | Stop and escalate — baseline broken; this blocks all downstream work. |

### Rough effort

20-40 minutes including Homebrew install.

---

## Step 3 — MiSTer platform CMake shim (`PORT_MISTER=ON`)

### Title

Add the `PORT_MISTER` CMake option at the game-root level, the new `platforms/MiSTer.cmake` at the engine level, and the minimum glue to make `cmake ... -DPORT_MISTER=ON -DPLATFORM=MiSTer` configure cleanly — even though no backend source exists yet.

### Why it matters

Gives us a MiSTer-flavored build that is deterministic and isolated from Linux/Darwin/Windows paths. Without this shim, Step 4's build driver has no CMake option to set. This is the **smallest possible diff** that creates a named platform; the real backend lands in Phase 1.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Linux.cmake` (96 lines, the template to copy)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/Darwin.cmake`
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/CMakeLists.txt` lines 58-68 (how `PLATFORM` dispatches)
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt` lines 1-100 (PORT_MISTER gating pattern, ARM hardening flags at 169-199)

### Files to create/modify

- **Create** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake`:
  - Copy `Linux.cmake` as starting point (96 lines).
  - Drop the OGL/VK/GLFW/GLEW branches entirely — we only support SDL2 subsystem on MiSTer.
  - Keep the SDL2 + USE_SDL_AUDIO + libogg/libtheora pkg_check blocks.
  - Add `target_compile_definitions(RetroEngine PRIVATE PORT_MISTER=1 RETRO_MISTER=1)`.
  - Include the ARM hardening block from 3sx CMakeLists.txt:169-199, target `RetroEngine` (not `3s-arm`):
    ```cmake
    if(PORT_MISTER)
        string(TOLOWER "${CMAKE_C_COMPILER_TARGET}" _target_lc)
        if(_target_lc MATCHES "arm-linux-gnueabihf" OR _target_lc MATCHES "armv7")
            target_compile_options(RetroEngine PRIVATE
                -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard)
            target_link_options(RetroEngine PRIVATE
                -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard)
            message(STATUS "MiSTer ARM hardening flags enabled")
        endif()
    endif()
    ```
  - Reminder: do NOT add `RETRO_RENDERDEVICE_MISTER=1` here yet — the MiSTer render device is Phase 1. For Phase 0 we fall back to the SDL2 backend so the engine links against a real backend and can actually start up. This is the fork-from-upstream compromise that lets Phase 0 produce a runnable binary.
  - Do NOT re-define `RETRO_RENDERDEVICE_SDL2` from `MiSTer.cmake`. Architectural fact #6 above: `RetroEngine.hpp:262-264` auto-translates `RSDK_USE_SDL2` (set by `dependencies/RSDKv5/CMakeLists.txt:155` when `RETRO_SUBSYSTEM=SDL2`) into `RETRO_RENDERDEVICE_SDL2=1`. Duplicating the define via `target_compile_definitions` would trigger a `-Wmacro-redefined` warning and adds no value.

- **Modify** `/Users/sb/Developer/sonic-mania-mister/CMakeLists.txt`:
  - Add `option(PORT_MISTER "Enable MiSTer-oriented build profile" OFF)` near line 4, next to `WITH_RSDK`.
  - When `PORT_MISTER` is ON:
    - Force `GAME_STATIC=ON` (decision #4). **M5 — upstream quirk:** the root CMakeLists.txt line 16 defaults `GAME_STATIC` via a generator-expression that is broken (does not expand correctly when `PORT_MISTER` is ON). We sidestep by force-setting via `CACHE STRING FORCE` **before** `add_subdirectory(${RSDK_PATH})`, so the submodule picks up our value rather than the broken default. Explicitly: `set(GAME_STATIC ON CACHE STRING "force-static for MiSTer" FORCE)`.
    - Force `RETRO_SUBSYSTEM=SDL2` and `USE_SDL_AUDIO=ON` via `set(... CACHE STRING ... FORCE)` before `add_subdirectory(${RSDK_PATH})`.
    - Force `RETRO_DISABLE_PLUS=ON`.
    - Add `set(PLATFORM MiSTer CACHE STRING "" FORCE)` so the RSDKv5 subdir picks our new platform file.
  - Add `message(STATUS "PORT_MISTER=${PORT_MISTER}")`.
  - Add a telemetry flavor option (plan delivers the flag even though no telemetry hooks exist in Mania yet — mirrors 3sx's pattern, harmless when unused):
    ```cmake
    option(ENABLE_PERF_TELEMETRY "Enable perf telemetry capture (no-op in Phase 0)" ON)
    ```
    **B3 — option gate location.** This `option()` MUST sit at **top-level** of the root `sonic-mania-mister/CMakeLists.txt`, NOT inside any `if(PORT_MISTER)` conditional block. Reason: the build driver in Step 4 passes `-DENABLE_PERF_TELEMETRY=${telemetry_flag}` on the command line; CMake needs to see the `option()` declaration at configure-time regardless of whether `PORT_MISTER` is ON, so the variable is defined and respected. Placing the option inside a PORT_MISTER guard would mean `-DENABLE_PERF_TELEMETRY=OFF` silently no-ops on non-PORT_MISTER builds, which is fine today but future-hostile. Keep it at top-level.

    **B3 — flavor split scope.** The `telemetry` vs `clean` flavor split in Phase 0 is **primarily a build-directory / install-prefix naming convention** (`build/mister-telemetry-install/` vs `build/mister-clean-install/`) — it does NOT gate any real telemetry code today because no telemetry code exists in Mania yet. Real perf-gating on `ENABLE_PERF_TELEMETRY` arrives in Phase 6. Document this explicitly in the runbook so readers don't expect runtime differences between the two flavors in Phase 0.

- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/CMakeLists.txt`:
  - No changes. Platform dispatch at `CMakeLists.txt:68` (`include(platforms/${PLATFORM}.cmake)`) will pick up `MiSTer.cmake` without further edits.

### Success criteria

**B2 — No macOS configure smoke in Step 3.** Previously this step proposed running `cmake -S . -B build/mister-config-test -DPORT_MISTER=ON` on macOS as a configure-only smoke test. That fails at configure time because `Linux.cmake`'s (and hence `MiSTer.cmake`'s) `pkg_check_modules(SDL2 sdl2 REQUIRED)` needs SDL2 discoverable via `pkg-config`, and the armhf sysroot does not exist on macOS. Phase 1 has its own Mac-validation path (using host SDL2 to exercise the backend interface); Phase 0 does not need a macOS configure smoke. Step 2 already proves the tree builds on macOS with stock flags — that is sufficient baseline.

The only configure smoke for Step 3 runs **inside the Docker container** (anticipating Step 4):
```bash
docker exec sonic-mania-mister-arm-build bash -lc 'cd /src && cmake -S . -B /tmp/phase0-probe -DPORT_MISTER=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER_TARGET=arm-linux-gnueabihf -DCMAKE_CXX_COMPILER_TARGET=arm-linux-gnueabihf'
```
must:
- Succeed configuring (does not need to build — build happens in Step 4).
- Print `PORT_MISTER=ON` in CMake output.
- Print the ARM hardening flag status message (target matches `arm-linux-gnueabihf`, so the block fires).
- Exit 0 from cmake.

### Dependencies

Step 1 (for the pkg-config probe inside container). Independent of Step 2.

### What NOT to do

- Do not add `MiSTerRenderDevice.{cpp,hpp}` or `Graphics/MiSTer/` directory. That is Phase 1.
- Do not add `NativeVideoWriter.{c,h}`. That is Phase 2.
- Do not patch `Drawing.hpp:245-257` or `Drawing.cpp:133-146`. Those are Phase 1.
- Do not add `RETRO_RENDERDEVICE_MISTER` as a compile define anywhere. Phase 1.
- Do not add `dependencies/android/libtheora/...` fallback sources to `MiSTer.cmake` — we rely on distro `libtheora-dev:armhf` from Step 1.

### What to do if it fails

| Symptom | Fix |
|---|---|
| `include(platforms/MiSTer.cmake)` not found | Check spelling / directory. CMake is case-sensitive on Linux Docker even though macOS-local may hide errors. |
| `pkg-config ... not found` during configure inside container | Verify `PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig` is exported. |
| Configure fails on `COMPILE_THEORA=TRUE` path | Verify `libtheora-dev:armhf` is installed. If it isn't: go back to Step 1 and add the package, OR apply the fallback upstream patch (see "Phase 0 stretch goal" below). |

### Rough effort

1-2 hours. Mostly one CMake file to write + small root edits.

### Phase 0 stretch goal (OPTIONAL, only if libtheora cross install fails)

A conditional upstream patch to `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Video.cpp` that wraps the theora-using blocks (lines 41-150, 181-280 roughly) with `#if !defined(RETRO_DISABLE_VIDEO)`. Skip this unless libtheora:armhf install fails in Step 1. Keep the diff minimal and guarded so upstream `git pull` merges cleanly.

---

## Step 4 — Cross-compile toolchain file + build driver script

### Title

Write `cmake/toolchain-mister.cmake` and `tools/mister/build-game.sh` to produce the `armhf` build inside Docker.

### Why it matters

This is the workhorse. Combines Steps 1, 3 into a single idempotent command that a developer (or CI, later) can invoke. Mirrors 3sx's `tools/mister/build-game.sh` pattern directly.

### Files to read first

- `/Users/sb/Developer/3sx-mister/tools/mister/build-game.sh` (253 lines — canonical form, already read)
- `/Users/sb/Developer/3sx-mister/docs/mister-runbook.md` lines 142-182 (the validated cross-build commands and the `readelf` verification)
- `/Users/sb/Developer/3sx-mister/CMakeLists.txt` lines 169-199 (ARM hardening pattern)

### Files to create/modify

- **Create** `/Users/sb/Developer/sonic-mania-mister/cmake/toolchain-mister.cmake`:
  ```cmake
  # Cross-compile toolchain for MiSTer HPS (Cortex-A9, armhf, Debian Bullseye sysroot).
  # Intentionally MINIMAL: we do NOT set CMAKE_SYSROOT or CMAKE_FIND_ROOT_PATH.
  # Debian's multi-arch layout puts armhf libs at /usr/lib/arm-linux-gnueabihf/
  # and armhf headers at /usr/include/arm-linux-gnueabihf/, both of which
  # clang-20 picks up automatically when given `--target=arm-linux-gnueabihf`
  # and `--gcc-toolchain=/usr`. Setting CMAKE_SYSROOT here would hide those
  # paths and break pkg-config discovery.
  set(CMAKE_SYSTEM_NAME Linux)
  set(CMAKE_SYSTEM_PROCESSOR armv7-a)
  set(CMAKE_C_COMPILER clang-20)
  set(CMAKE_CXX_COMPILER clang++-20)
  set(CMAKE_C_COMPILER_TARGET arm-linux-gnueabihf)
  set(CMAKE_CXX_COMPILER_TARGET arm-linux-gnueabihf)
  set(CMAKE_C_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include")
  set(CMAKE_CXX_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include")
  set(CMAKE_EXE_LINKER_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr")
  # Point pkg-config at armhf .pc files before host-arch ones.
  set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig")
  ```
  **NOTE:** The 3sx runbook path does NOT use a toolchain file and instead relies on env vars + explicit `-DCMAKE_C_COMPILER_TARGET=`. Both approaches work on Debian Bullseye's multi-arch layout. We include this toolchain file as a one-stop ergonomic win for humans running `cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mister.cmake ...` directly; Step 4's build driver uses the env-var form (matches 3sx byte-for-byte). If the toolchain file conflicts with the env-var form in a future refactor, delete the toolchain file — it's redundant. Do not set `CMAKE_SYSROOT` here; doing so masks multi-arch directories and breaks SDL2/theora/ogg discovery.

- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/build-game.sh`:
  Port 3sx's script line-for-line, with these diffs:
  1. Default container name: `sonic-mania-mister-arm-build`.
  2. Output binary path: `dependencies/RSDKv5/RSDKv5U` (engine target's output) vs 3sx's `bin/3s-arm`.
  3. `cmake_target_args` same.
  4. Drop the call to `build-deps.sh --profile mister` — Mania does not have one. Instead, the inner build just runs cmake configure + build + install directly.
  5. Define `build_one()` with:
     ```bash
     build_one() {
         local flavor_name="$1"
         local telemetry_flag="$2"
         local build_dir="build/mister-${flavor_name}"
         local install_dir="build/mister-${flavor_name}-install"
         local package_dir="build/mister-${flavor_name}-package"
         local binary_path="${install_dir}/bin/RSDKv5U"

         cmake -S . -B "${build_dir}" \
             -DCMAKE_BUILD_TYPE=Release \
             -DPORT_MISTER=ON \
             -DGAME_STATIC=ON \
             -DRETRO_SUBSYSTEM=SDL2 \
             -DUSE_SDL_AUDIO=ON \
             -DRETRO_DISABLE_PLUS=ON \
             -DENABLE_PERF_TELEMETRY="${telemetry_flag}" \
             "${cmake_target_args[@]}" \
             "${extra_args[@]}"
         cmake --build "${build_dir}" --parallel "${jobs}"
         cmake --install "${build_dir}" --prefix "${install_dir}"
         tools/mister/package.sh "${install_dir}" "${package_dir}"

         readelf -h "${binary_path}" | grep -q "Machine:.*ARM"
         readelf -A "${binary_path}" | grep -q "Tag_ABI_VFP_args"
     }
     ```
  6. Same `copy_out_dir` back to host pattern.
  7. Same telemetry/clean/both flavor dispatch.
  8. Same `EXTRA_CMAKE_ARGS` forwarding hook.
  9. **NEW:** Detect and fail fast if the RSDKv5 subdir doesn't define an `install(TARGETS RetroEngine RUNTIME DESTINATION bin)` rule — upstream RSDKv5's `CMakeLists.txt` does NOT have an install() call as of v1.1.1 (verified by grep). The build driver must either (a) add its own `install()` via a tacked-on CMake snippet, (b) copy the built binary directly from `build_dir/dependencies/RSDKv5/RSDKv5U` into `install_dir/bin/RSDKv5U`, or (c) append an install rule patch to `MiSTer.cmake` in Step 3. **Decision: choose option (c)** — add `install(TARGETS RetroEngine RUNTIME DESTINATION bin)` inside `MiSTer.cmake` (safer than modifying the root, doesn't break other platforms). Record this as a small addendum to Step 3.

### Files to create/modify (expanded)

- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake` (append to Step 3's file):
  ```cmake
  # Phase 0 bare-minimum install rule. RSDKv5 upstream ships no install()
  # for RetroEngine on any platform; we add one here so cmake --install
  # populates build/mister-*-install/bin/RSDKv5U.
  install(TARGETS RetroEngine RUNTIME DESTINATION bin)
  ```
  Plain `DESTINATION bin` avoids pulling in `GNUInstallDirs` — simpler and Phase 0-appropriate.

  **M6 — install(TARGETS) scope verification.** The `RetroEngine` target is defined inside the engine submodule's `dependencies/RSDKv5/CMakeLists.txt`. `MiSTer.cmake` is included FROM that same submodule CMakeLists via `include(platforms/${PLATFORM}.cmake)` (line 68), so `install(TARGETS RetroEngine ...)` written in `MiSTer.cmake` executes at engine-subdir scope and CAN see the `RetroEngine` target. If we were to write this `install()` in the outer `sonic-mania-mister/CMakeLists.txt`, it would fail because the target is not visible at root scope. Confirmed correct placement.

- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh`:
  Adapted from 3sx's 195-line version down to ~60 lines. Required behaviors:
  - Args: `<install-prefix> <output-dir>`.
  - Copy `${install_prefix}/bin/RSDKv5U` to `${output_dir}/bin/RSDKv5U`.
  - Do NOT create `${output_dir}/lib/` in Phase 0. Our install() rule only emits the binary; bundling shared libs is a Phase 7 polish concern once we decide which libs MiSTer provides vs which we ship.
  - Generate a launcher script `${output_dir}/scripts/run-mania.sh`:
    ```sh
    #!/bin/sh
    set -eu
    SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    APP_DIR="$(CDPATH= cd -- "${SELF_DIR}/.." && pwd)"
    # Force SDL2 headless video driver on MiSTer HPS: no /dev/fb0-based
    # presenter; Phase 1 replaces this with the MiSTer native-video path.
    # Without `dummy`, SDL2 backend hangs trying to open a window.
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
    # Run from the binary's directory so relative paths (like Data.rsdk
    # lookup) resolve next to the executable.
    cd "${APP_DIR}"
    exec ./bin/RSDKv5U "$@"
    ```
  - Do NOT bundle `Data.rsdk` (user-supplied per decision; mirrors 3sx's `SF33RD.AFS` posture).
  - Do NOT include any MiSTer-wrapper-specific bits (those belong to Phase 4).
  - Do NOT set `LD_LIBRARY_PATH`. Phase 0 relies entirely on MiSTer's system-provided SDL2/theora/ogg. If Step 7 reveals a missing SONAME, revisit.

### Success criteria

From project root, on macOS:
```bash
bash tools/mister/setup-build-container.sh   # idempotent, runs Step 1
bash tools/mister/build-game.sh --flavor telemetry --jobs 2
```
must produce:
- `build/mister-telemetry-install/bin/RSDKv5U` (ARM hard-float binary).
- `file build/mister-telemetry-install/bin/RSDKv5U` reports `ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked`.
- `readelf -h build/mister-telemetry-install/bin/RSDKv5U | grep Machine` reports `Machine: ARM`.
- `readelf -A build/mister-telemetry-install/bin/RSDKv5U | grep -iE 'Tag_CPU_name|Tag_ABI_VFP_args|Tag_Advanced_SIMD_arch'` shows VFP + NEON tags.
- `build/mister-telemetry-package/bin/RSDKv5U` exists (packaged copy).
- `build/mister-telemetry-package/scripts/run-mania.sh` exists and is executable.
- Second invocation with the same flavor completes in <1 min (incremental build, not a from-scratch recompile).

### Dependencies

Steps 1 and 3 must both be complete. Step 2 (macOS baseline) is nice-to-have but not strictly blocking.

### What NOT to do

- Do not parallelize with `--jobs $(nproc)` — 3sx runbook warns that emulated ARM containers OOM-kill at high job counts. Default 2. For cross-build on amd64, more jobs is fine but keep default conservative.
- Do not add an `--arm` native-container flag. 3sx's `linux/arm/v7` path is validated but macOS QEMU performance is bad; stick with cross on `linux/amd64`.
- Do not add `-fno-exceptions` / `-fno-rtti` — research doc §2.12 confirms `ModAPI.cpp` has try-blocks. Would break mod loader. Mod loader stays ON per research doc recommendation.
- Do not cache the Docker image under a non-obvious tag name — keep the container name matching 3sx's pattern so developers who flip between projects see consistent naming.

### What to do if it fails

| Symptom | Diagnostic | Fix |
|---|---|---|
| `No rule to make target '.../libSDL2.so'` | SDL probe wrong path | Confirm `PKG_CONFIG_LIBDIR` is set; run `pkg-config --libs sdl2` inside container manually. |
| `clang: error: argument unused during compilation: '--gcc-toolchain=/usr'` on link | `LDFLAGS` not split correctly | Ensure `CFLAGS`, `CXXFLAGS`, `LDFLAGS` each independently carry `--target=` + `--gcc-toolchain=`. |
| `/usr/bin/ld: unrecognised emulation mode: armelfb_linux_eabi` | wrong linker picked | Clang-20 must use GNU ld from `binutils-arm-linux-gnueabihf`; use `-fuse-ld=bfd` if clang tries lld. 3sx doesn't need this but worth knowing. |
| `ModAPI.cpp` compile errors about filesystem | `<filesystem>` header missing in cross sysroot | Install `libstdc++-10-dev-armhf-cross` (should already be from Step 1). Bullseye's GCC 10 libstdc++ ships `<filesystem>` in the main library — **no `-lstdc++fs` is needed** (that was a GCC 7/8-era hack). If link still fails, set `RETRO_MOD_LOADER=OFF` temporarily — not ideal, but unblocks Phase 0. |
| Links fails with theora undefined symbols | `libtheora-dev:armhf` not installed | Return to Step 1; install `libtheora-dev:armhf`. |
| Links fails with `dlopen`/`dlerror` unresolved | missing `-ldl` | Add `-ldl` to link in MiSTer.cmake via `target_link_libraries(RetroEngine dl)`. |
| Binary produced but `file` says `EABI5 version 1 (GNU/Linux)` instead of `(SYSV)` | linker chose GNU_HASH but OS ABI tag wrong | Cosmetic, usually fine; check `readelf -e | grep OS/ABI`. If tag is `UNIX - GNU`, MiSTer will still load. |

### Rough effort

2 focused sessions. First produces a working build; second shakes out linker edge cases.

---

## Step 5 — Sanity-check the produced armhf binary locally

### Title

Verify the Docker-produced `armhf` binary's dynamic-library footprint is MiSTer-compatible without actually deploying.

### Why it matters

Catches glibc skew, missing NEEDED libraries, and accidental hard dependencies on libraries that MiSTer doesn't ship — before we waste an SSH round trip.

### Files to read first

None — pure inspection.

### Files to create/modify

- Optional: append a `--verify` or `--inspect` subcommand to `tools/mister/build-game.sh` that runs the checks below. If skipped, the Step 5 agent just runs them manually and documents the commands in the runbook (Step 8).

### Success criteria

Inside the Docker container (so we have `arm-linux-gnueabihf-readelf` available):
```bash
docker exec sonic-mania-mister-arm-build bash -lc '
    bin=/work-mister/build/mister-telemetry-install/bin/RSDKv5U
    arm-linux-gnueabihf-readelf -d "$bin" | grep NEEDED
    arm-linux-gnueabihf-readelf -h "$bin"
    arm-linux-gnueabihf-readelf -A "$bin"
'
```
must:
- List only NEEDED libs that MiSTer's root filesystem provides: `libc.so.6`, `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libpthread.so.0`, `libdl.so.2`, `libSDL2-2.0.so.0`, `libasound.so.2`, `libogg.so.0`, `libtheora.so.0`, `libtheoradec.so.1`, possibly `libvorbis*`, `libz.so.1`. No surprises like `libGL`, `libEGL`, `libGLESv2`, `libX11`, `libxcb*`.
- Report `Machine: ARM`, `Flags: 0x5000400` (or similar hard-float flag), `OS/ABI: UNIX - System V` or `UNIX - GNU`.
- Report `Tag_CPU_name: "7-A"`, `Tag_ABI_VFP_args: VFP registers`, `Tag_Advanced_SIMD_arch`.

Document any surprise NEEDED lib in the runbook's troubleshooting section.

Additionally, compare glibc version requirement:
```bash
docker exec sonic-mania-mister-arm-build bash -lc '
    bin=/work-mister/build/mister-telemetry-install/bin/RSDKv5U
    arm-linux-gnueabihf-readelf -V "$bin" | grep -i glibc | sort -u
'
```
Record the highest required GLIBC_X.Y symbol. Debian Bullseye ships glibc 2.31. MiSTer Linux 5.15 also ships glibc 2.31 as of the 2026 MiSTer releases (verify empirically once we have SSH access in Step 7). If the binary requires GLIBC > 2.31, fail this step and document.

### Dependencies

Step 4.

### What NOT to do

- Do not attempt to run the binary on the dev machine via `qemu-user-static` — not reliable for validating MiSTer compatibility.
- Do not strip the binary.

### What to do if it fails

| Symptom | Fix |
|---|---|
| Required `GLIBC_2.32+` symbol | Bullseye's glibc is 2.31. Something weird is happening — check `readelf -V` output; most likely cause is an inlined system-call wrapper. File a note and continue to Step 7 for empirical verification on device. |
| Unexpected NEEDED lib (`libGL.so.1`, `libX11.so.6`) | Our MiSTer.cmake accidentally pulled in a GL dep. Inspect `target_link_libraries` for `RetroEngine`; remove the offender. |
| Missing `Tag_ABI_VFP_args` | Hardening flags didn't apply. Inspect `MiSTer.cmake`, confirm `_target_lc MATCHES "arm-linux-gnueabihf"` fired. |

### Rough effort

30 minutes.

---

## Step 6 — Deploy helper

### Title

Write `tools/mister/deploy-to-mister.sh` — a minimal, opinionated SCP-based deploy that copies the packaged binary + launcher to `/media/fat/games/SonicMania/` on the MiSTer target.

### Why it matters

Phase 0's exit criterion requires running the binary on MiSTer hardware. We need a one-command deploy. 3sx's deploy is via `misterctl.sh` (a 500+ line monster with locking, multi-agent coordination, etc.); we deliberately deliver a small Phase 0 deploy script and defer the full misterctl to Phase 5+.

### Files to read first

- `/Users/sb/Developer/3sx-mister/tools/mister/misterctl.sh` (read the `deploy` subcommand only — roughly the `rsync ... --exclude ...` block)
- Memory: `/Users/sb/.claude/projects/-Users-sb-Developer-3sx-mister/memory/reference-mister-credentials.md` (host + password)
- Memory: `feedback-no-rsync-delete.md` (NEVER use `rsync --delete` on MiSTer)

### Files to create/modify

- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/deploy-to-mister.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

  flavor="${MANIA_FLAVOR:-telemetry}"
  mister_host="${MISTER_HOST:-192.168.1.188}"
  mister_user="${MISTER_USER:-root}"
  mister_password="${MISTER_PASSWORD:-1}"
  remote_base="${MISTER_REMOTE_BASE:-/media/fat/games/SonicMania}"
  src_dir="${ROOT_DIR}/build/mister-${flavor}-package"

  if [ ! -d "${src_dir}" ]; then
      echo "No packaged build at ${src_dir}. Run tools/mister/build-game.sh first." >&2
      exit 2
  fi

  command -v sshpass >/dev/null || { echo "install sshpass (brew install hudochenkov/sshpass/sshpass)" >&2; exit 2; }

  # SAFETY: never --delete; never retarget outside /media/fat/games/SonicMania.
  case "${remote_base}" in
      /media/fat/games/SonicMania|/media/fat/games/SonicMania/) ;;
      *)
          echo "refusing to deploy to non-whitelisted remote base: ${remote_base}" >&2
          exit 3
          ;;
  esac

  sshpass -p "${mister_password}" ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${mister_user}@${mister_host}" "mkdir -p '${remote_base}'"

  sshpass -p "${mister_password}" rsync -av --no-owner --no-group --no-perms \
      -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
      "${src_dir}/" \
      "${mister_user}@${mister_host}:${remote_base}/"

  echo "deployed ${src_dir} -> ${mister_user}@${mister_host}:${remote_base}"
  echo "smoke test: sshpass -p \"\${MISTER_PASSWORD}\" ssh ${mister_user}@${mister_host} '${remote_base}/scripts/run-mania.sh'"
  ```
  Notable safety rails:
  - `--no-delete` NEVER present.
  - Remote base is whitelist-checked against a single allowed path.
  - Password defaults match MiSTer's stock `1`.
  - `sshpass` required but easy to install.

### Success criteria

With a MiSTer booted and reachable at 192.168.1.188:
```bash
MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 \
    bash tools/mister/deploy-to-mister.sh
```
must:
- Create `/media/fat/games/SonicMania/` on the target if absent.
- Copy `build/mister-telemetry-package/` contents under it, including `bin/RSDKv5U`, `lib/*` (if any), `scripts/run-mania.sh`.
- Print the suggested smoke-test command.
- Exit 0.

Verify on MiSTer (sshpass reads `$MISTER_PASSWORD`, do not hardcode `1` in shell history):
```bash
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'ls -la /media/fat/games/SonicMania/bin/'
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'file /media/fat/games/SonicMania/bin/RSDKv5U'
```
The `file` output on-device must match what Step 5 reported.

### Dependencies

Step 4 (must have a packaged binary).

### What NOT to do

- Do not use `rsync --delete`. Ever. Memory says so explicitly.
- Do not retarget the deploy at `/media/fat/` or any path outside `/media/fat/games/SonicMania/`. The whitelist guard exists to catch typos.
- Do not deploy `Data.rsdk` (user-supplied).
- Do not add `misterctl.sh`-style multi-agent locking. Overkill for Phase 0; we use one-at-a-time manual deploys.

### What to do if it fails

| Symptom | Fix |
|---|---|
| `Host key verification failed` | Already disabled via `-o StrictHostKeyChecking=no`. If still firing, confirm `UserKnownHostsFile=/dev/null` is in the ssh args. |
| `Connection refused` | Confirm MiSTer is at `192.168.1.188` (or update env var). `reference-mister-credentials.md` was updated from `.171` to `.188`. |
| `rsync: read error` mid-copy | Usually transient; re-run. If persistent, check MiSTer's `/media/fat` free space (`df -h`). |
| `sshpass: not found` on macOS | `brew install hudochenkov/sshpass/sshpass`. |

### Rough effort

1 hour.

---

## Step 7 — MiSTer-side smoke test

### Title

Run the deployed binary on MiSTer hardware and confirm it reaches the `Data.rsdk` read path before exiting cleanly.

### Why it matters

This is the Phase 0 exit criterion. Everything before this is preparation; only this step proves the toolchain/deploy produces something that actually runs on target.

### Files to read first

None — empirical step.

### Files to create/modify

None (smoke test is read-only from the MiSTer side; we only generate a local log).

### Pre-flight on MiSTer (do before deploy)

Sanitize sshpass usage by reading `$MISTER_PASSWORD` from env, not hardcoding `1`:

```bash
# 1. Verify required SONAMEs exist in MiSTer's rootfs.
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 \
    'ldconfig -p | grep -E "libSDL2|libogg|libtheora|libasound|libstdc\+\+"'
# Expected: libSDL2-2.0.so.0, libogg.so.0, libtheora.so.0, libtheoradec.so.1,
# libasound.so.2, libstdc++.so.6 — all present.
# If any missing, Step 6 package.sh must bundle them into build/mister-*-package/lib/.

# 2. Verify glibc version on MiSTer matches Bullseye's 2.31.
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 'ldd --version | head -1'
# Expected: "ldd (Debian GLIBC 2.31-...) 2.31" or a 2.31.x line.
# If MiSTer is < 2.31, the binary produced in Step 4 will fail to start on device —
# this is a genuine glibc skew surprise; escalate.
```

Document findings in the runbook. Both probes are no-risk read-only SSH.

### Success criteria

On the dev machine:
```bash
sshpass -p "${MISTER_PASSWORD}" ssh root@192.168.1.188 '/media/fat/games/SonicMania/scripts/run-mania.sh' 2>&1 | tee /tmp/mania-smoke.log
echo "exit-code=$?"
```
Expected observations in `/tmp/mania-smoke.log`:
- No `Segmentation fault`, no `Illegal instruction`.
- No dynamic-linker errors (`error while loading shared libraries: ...`).
- Some RSDKv5 log banner output (e.g. `RSDK Revision: 3`, or similar — format TBD; verify at implementation time from `RetroEngine.cpp`).

**M4 — tightened Phase 0 pass criteria.** Previously "infinite loop trying to open a window" was listed as an acceptable fallback; that is NOT acceptable. `SDL2RenderDevice.cpp:596` hardcodes `SDL_RENDERER_ACCELERATED`, and combined with `SDL_VIDEODRIVER=dummy` in the launcher, `SDL_CreateRenderer` may return NULL. The engine may hard-assert on NULL, or worse, spin. Pass criteria for Phase 0 are now BOTH of the following:

1. **Progress marker in log.** At least one of:
   - A log line showing the engine attempted to open `Data.rsdk` (e.g., `fopen("Data.rsdk"…) failed`, `Attempting to load user file`, or equivalent — match against actual strings in `RetroEngine.cpp` / `Storage.cpp` at implementation time).
   - A log line showing renderer creation was attempted (even if it failed), indicating the engine got past static init and into the main boot path.
2. **Clean termination within 10 seconds.** The process must exit on its own (any exit code) within 10s — NOT be killed by SIGTERM/SIGKILL from a timeout wrapper. A hang past 10s means `SDL_CreateRenderer` is blocking (or asserting), and we must escalate: add a proper NULL-check fallback patch in the engine's SDL2 backend, or add `SDL_HINT_RENDER_DRIVER=software` to the launcher before trying `SDL_VIDEODRIVER=dummy`.

If the binary hangs indefinitely, that is a FAILURE — Phase 0 requires self-termination. Document the observed failure mode in the runbook's troubleshooting section and escalate.

**BRANCH on SDL2 renderer behavior:** Research doc §2.6 notes that the SDL2 backend requests `SDL_RENDERER_ACCELERATED` at `SDL2RenderDevice.cpp:596`. Combined with `SDL_VIDEODRIVER=dummy`, `SDL_CreateRenderer` may return NULL on MiSTer HPS. Expected failure mode under M4: SDL2 backend fails to create a renderer, engine logs the failure, exits cleanly with a non-zero code — that is a PASS per the criteria above. A hang is a FAIL. We are not fixing the SDL2 backend in Phase 0; Phase 1 replaces it with MiSTerRenderDevice, which is why Phase 0's bar is just "exits cleanly, reaches an identifiable progress marker."

The launcher sets `export SDL_VIDEODRIVER=dummy` (via `package.sh`) to force SDL2's headless video driver and avoid the "hangs trying to open /dev/fb0" trap that 3sx also hit.

### Dependencies

Steps 4, 6.

### What NOT to do

- Do not copy `Data.rsdk` to the target just to make the binary get further. Phase 0 exit criterion is "reaches the read-Data.rsdk point on missing file." If you have a `Data.rsdk` handy, set it aside for Phase 5.
- Do not debug crashes by modifying engine source in Phase 0. Log the crash, note it, and escalate to Phase 1 (where the MiSTer backend replaces SDL2RenderDevice).

### What to do if it fails

| Symptom | Diagnostic | Fix |
|---|---|---|
| `error while loading shared libraries: libtheora.so.0` | MiSTer doesn't ship libtheora | Bundle `libtheora.so.0` into `build/mister-telemetry-package/lib/` (should already be there if package.sh copies `install/lib/`), OR re-run build with a static-linked theora. If MiSTer literally lacks the lib and our package also doesn't have it, Phase 0 is compromised — add a static-theora CMake path in Step 3's MiSTer.cmake (use the in-tree Android libogg sources as template for libtheora static build? No — libtheora sources aren't in-tree. Next recourse: stub the Video.cpp theora code with the upstream patch in Step 3's stretch goal). |
| `error while loading shared libraries: libSDL2-2.0.so.0` | MiSTer's SDL2 at a different name | `ssh root@192.168.1.188 'ls /lib/*sdl* /usr/lib/*sdl* 2>&1'` — if the .so is there but different SONAME, set `LD_LIBRARY_PATH` in the launcher. |
| Hangs on fbdev open | SDL2 default video driver | Add `SDL_VIDEODRIVER=dummy` to launcher. |
| `Illegal instruction` | NEON/VFP mismatch or wrong CPU flags | Check `readelf -A` output and verify `-mcpu=cortex-a9` vs whatever MiSTer reports (`ssh root@192.168.1.188 'cat /proc/cpuinfo'`). Cyclone V is Cortex-A9 per research doc §1 — if mismatch, something is wrong with the hardening flags. |
| `Segmentation fault` at startup | Stack-guard / PIE / ASLR issue | Try building with `-no-pie`. |

### Rough effort

1-2 hours depending on what surfaces.

---

## Step 8 — Runbook + tools README

### Title

Document Phase 0 end-to-end in `docs/mister-runbook.md` and `tools/mister/README.md`.

### Why it matters

Future Phase 1 agents need to re-invoke the build without re-discovering the commands. This locks in the process.

### Files to read first

- `/Users/sb/Developer/3sx-mister/docs/mister-runbook.md` (589 lines — use as template, strip Quartus/netplay/wrapper sections)
- Everything produced in Steps 1-7.

### Files to create/modify

- **Create** `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md`:
  Sections (mirroring 3sx but slimmed to Phase 0 surface):
  1. Scope (offline-first, no netplay, Phase 0 baseline)
  2. Canonical Docker quick start (`tools/mister/build-game.sh --flavor telemetry`)
  3. Build flavors (telemetry, clean) — same semantics as 3sx
  4. Manual Docker bootstrap (for debugging): `tools/mister/setup-build-container.sh`
  5. Cross-compile invocation (reference, not required for most)
  6. Binary verification (`file`, `readelf -h`, `readelf -A` commands from Step 5)
  7. Deploy to MiSTer (`tools/mister/deploy-to-mister.sh`)
  8. Smoke test on device (Step 7 command)
  9. Required game data (`/media/fat/games/SonicMania/Data.rsdk` — user-supplied)
  10. Troubleshooting (pull from the "What to do if it fails" blocks above)

- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/README.md`:
  Short index, ~50 lines:
  - `setup-build-container.sh` — what it does, one-line usage.
  - `build-game.sh` — what it does, one-line usage, points to runbook.
  - `package.sh` — internal, called by build-game.sh.
  - `deploy-to-mister.sh` — what it does, env vars.
  - Pointer to `docs/mister-runbook.md` for the full flow.

### Success criteria

- `docs/mister-runbook.md` exists and is coherent.
- `tools/mister/README.md` exists and lists every script in the directory.
- Fresh reader can go from `git clone` to "binary on MiSTer" using only the runbook.

### Dependencies

All prior steps complete and validated.

### What NOT to do

- Do not copy the Quartus / FPGA sections from 3sx's runbook. Those belong to Phase 4.
- Do not document `misterctl.sh`-style features we didn't ship.
- Do not add release-zip packaging instructions.

### Rough effort

1 hour.

---

## Known risks & branch points

### Risk 1: libogg / libtheora on armhf clang-20

**Source of concern:** RSDKv5 engine issue #167 documents historical pain.
**Research doc claim:** stb_vorbis (audio) may pull libogg. **This is WRONG** — verified during planning. stb_vorbis is vendored header-only at `dependencies/all/stb_vorbis/stb_vorbis.c` and does not depend on external libogg. The only ogg/theora consumer is `Video.cpp` under `#if RETRO_REV0U`.
**Mitigation path A (primary):** Install `libtheora-dev:armhf`, `libogg-dev:armhf` from Debian Bullseye in Step 1. These are stable, well-tested packages. Step 3's `MiSTer.cmake` links against them via `pkg_check_modules`.
**Mitigation path B (fallback, only if A fails):** Apply the conditional `#if !defined(RETRO_DISABLE_VIDEO)` patch to `Video.cpp` as noted in Step 3's stretch goal. Adds ~10 lines of upstream patch.
**Mitigation path C (last resort):** Set `RETRO_REVISION=2` in CMake to drop REV0U entirely. Downside: we lose v5U-specific features forever.

Decision for plan: commit to path A. Path B is only invoked if Step 1's `apt-get install libtheora-dev:armhf` fails (extremely unlikely on Bullseye).

### Risk 2: glibc version skew between Docker sysroot and MiSTer runtime

**Concern:** if Debian Bullseye's glibc is newer than MiSTer's, the binary links against symbols MiSTer doesn't provide.
**Ground truth:** Debian Bullseye ships **glibc 2.31**. MiSTer's Linux 5.15 userland ships **glibc 2.31** (verified implicitly because 3sx, built with identical toolchain, runs cleanly on the same MiSTer). Skew is zero.
**Mitigation:** Step 5 explicitly checks the produced binary's max required `GLIBC_X.Y` version tag. If > 2.31, this is a genuine surprise — file it as a bug and escalate.

### Risk 3: clang-20 + armhf hardening flag compatibility

**Concern:** the exact flags `-mfpu=neon-vfpv3 -mfloat-abi=hard -mcpu=cortex-a9` must produce a Cortex-A9-compatible binary.
**Ground truth:** 3sx ships this exact flag set via clang-20 and runs on MiSTer. Direct copy, no risk.
**Mitigation:** `readelf -A` verification in Step 5 empirically confirms the produced binary uses VFP registers and NEON arch tags. If the verification fails, Step 5 fails and Step 3's hardening block is suspect.

### Risk 4: SDL2 backend requires SDL_RENDERER_ACCELERATED on MiSTer

**Concern:** research doc §2.6 flags this. At SDL2RenderDevice.cpp:596, the upstream code requests GPU-backed rendering which MiSTer HPS cannot provide.
**Impact on Phase 0:** at the smoke-test step, the binary will fail to create its window. That's acceptable — Phase 0 only requires the binary to start up and fail cleanly, which it will.
**Mitigation:** Phase 1 replaces this backend with MiSTerRenderDevice. In Phase 0 we ensure the launcher sets `SDL_VIDEODRIVER=dummy` so SDL2 can even initialize without needing a framebuffer.

### Risk 5: Upstream RSDKv5 has no `install(TARGETS)` rule

**Concern:** `cmake --install build/mister --prefix ...` won't copy `RSDKv5U` out. Build-driver's `readelf` check will fail because the install-dir path is empty.
**Mitigation:** Step 3 (addendum under Step 4) adds an `install(TARGETS RetroEngine RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})` in our `MiSTer.cmake`. This keeps the install hook scoped to MiSTer builds only and doesn't disturb other platforms.

### Risk 6: SonicMania/Objects/All.c compile time

**Concern:** `Game/Objects/All.c` is a massive include-all file. Compile times in an emulated / cross environment may be brutal.
**Mitigation:** The root `CMakeLists.txt` already has `GAME_INCREMENTAL_BUILD` option at line 37. If Phase 0 agent finds clean builds taking > 30 minutes, they can flip that option ON to use per-object compilation. Not a blocker, just ergonomics.

### Risk 7: Memory's "Always telemetry flavor" guidance

**Guidance:** `feedback-always-telemetry.md` says dev builds should always be telemetry.
**Phase 0 interpretation:** no telemetry code exists in Mania yet, so the flag is a no-op. We still thread `ENABLE_PERF_TELEMETRY=ON/OFF` through the build driver so Phase 6+ can wire up real telemetry on top. Build driver defaults to `--flavor telemetry`. Behavior matches 3sx.

---

## Open questions requiring user input before `/implement`

1. **MiSTer remote path.** Should we use `/media/fat/games/SonicMania/` (spaces-free) or `/media/fat/games/Sonic Mania/` (matches the RBF name decision #7)? Plan defaults to `SonicMania/` because shell-quoting space-in-path is error-prone for Phase 0 scripts; the FPGA core's RBF filename (with space) is a separate concern. **Phase 0 picks `SonicMania/` (no space) as the interim choice; Phase 4 revisits this when the user-facing games-path decision is finalized alongside the RBF filename.** The Phase 0 deploy whitelist is narrow enough that flipping to `Sonic Mania/` later is a single-line edit in `deploy-to-mister.sh`.

2. **libtheora bundled vs distro.** Plan commits to distro `libtheora-dev:armhf`. If the user has a strong preference for in-tree vendored build (matching the Android.cmake precedent), flag it before implementation — it's a larger change.

3. **SDL2 version pin.** Debian Bullseye ships SDL2 2.0.14. Upstream RSDKv5 was tested at least through SDL 2.0.20+. If 2.0.14 is missing APIs RSDKv5 relies on, we'll discover at link time. **Decision needed:** accept the Bullseye SDL2 pin, or build SDL2 from source (adds ~30 min to Step 1 and replicates 3sx's SDL3-from-source pattern)? Plan assumes distro SDL2 is fine; escalate if Step 4 reveals missing symbols.

4. **ASAN / UBSAN in telemetry flavor.** 3sx does NOT enable sanitizers in any MiSTer flavor (confirmed via grep). Mania plan matches. If the user wants a debug+sanitizer MiSTer build for development, that's Phase 7 polish — not Phase 0.

---

## Pre-implementation checklist

Before `/implement` is invoked on any step:

- [ ] User has acknowledged the Open Questions above.
- [ ] `docker` is installed and running on the dev box.
- [ ] The `sonic-mania-mister` repo root contains an unmodified checkout of RSDKv5 at `dependencies/RSDKv5/` (git submodule if applicable).
- [ ] MiSTer target is reachable at `192.168.1.188` (ping + SSH) OR the user has provided an alternate host via `MISTER_HOST=`.
- [ ] At least 5 GB free disk under the repo (Docker image layers + build outputs).
- [ ] `sshpass` is installed on the dev machine (any of: `brew install hudochenkov/sshpass/sshpass`, `brew install esolitos/ipa/sshpass`, or `apt-get install sshpass` on Linux). Used by Step 6.

---

## Post-Phase-0 hand-off to Phase 1

When this phase's exit criteria are met, Phase 1 (Skeleton MiSTer backend) begins with:

- A known-good `tools/mister/build-game.sh` invocation.
- A deployable `armhf` binary that links against SDL2 but doesn't render.
- A `MiSTer.cmake` platform file with install rules + hardening flags — ready to have `Graphics/MiSTer/*.cpp` sources added.
- A `RETRO_MISTER=1` define already flowing through the build.

The Phase 1 agent adds `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}` and the 4-line edits to `Drawing.hpp:245-257` + `Drawing.cpp:133-146`. No build-pipeline changes required — everything the pipeline needs was delivered in Phase 0.
