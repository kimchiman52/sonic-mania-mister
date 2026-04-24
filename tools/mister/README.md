# `tools/mister/` — Sonic Mania MiSTer build helpers

Phase 0 of the Sonic Mania MiSTer port. This directory ships the scripts that
turn an unmodified macOS checkout of `sonic-mania-mister` into a Cortex-A9
hard-float `armhf` ELF that deploys to MiSTer HPS.

All scripts are idempotent, shell-portable (bash 3.2 on macOS), and prefer
failing fast over emitting silent fallbacks.

See `docs/mister-runbook.md` for the full end-to-end procedure.

## Scripts

| Script | Purpose |
|---|---|
| `setup-build-container.sh` | Create / reuse the Debian 11 + clang-20 Docker container with armhf cross packages. Idempotent. |
| `build-game.sh`            | Cross-compile `RSDKv5U` inside the container. Flavor flag `--flavor telemetry\|clean\|both`. |
| `package.sh`               | Internal. Takes a cmake install prefix and stages a MiSTer-ready directory with launcher. Called by `build-game.sh`. |
| `deploy-to-mister.sh`      | SCP packaged binary to MiSTer. Reads `MISTER_HOST`, `MISTER_PASSWORD`. Whitelist-guarded path. |

## Quick start

```bash
# One-time Docker bootstrap (5-15 min first run, <5s reruns).
bash tools/mister/setup-build-container.sh

# Default dev build (telemetry flavor).
bash tools/mister/build-game.sh --flavor telemetry

# Deploy to MiSTer at 192.168.1.188 (see env vars below).
MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 \
    bash tools/mister/deploy-to-mister.sh

# Smoke test (bound to 10s; binary should exit itself before then).
sshpass -p "${MISTER_PASSWORD:-1}" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@192.168.1.188 \
    'timeout -s TERM 10 /media/fat/games/SonicMania/scripts/run-mania.sh' \
    2>&1 | tee /tmp/mania-smoke.log
```

## Environment variables

| Var | Used by | Default |
|---|---|---|
| `MISTER_BUILD_CONTAINER` | setup/build     | `sonic-mania-mister-arm-build` |
| `MISTER_DOCKER_PLATFORM` | setup/build     | `linux/amd64` |
| `MISTER_LLVM_VERSION`    | setup/build     | `20` |
| `JOBS`                   | build           | `2` |
| `EXTRA_CMAKE_ARGS`       | build           | (empty) |
| `MANIA_FLAVOR`           | deploy          | `telemetry` |
| `MISTER_HOST`            | deploy          | `192.168.1.188` |
| `MISTER_USER`            | deploy          | `root` |
| `MISTER_PASSWORD`        | deploy          | `1` |
| `MISTER_REMOTE_BASE`     | deploy          | `/media/fat/games/SonicMania` |

## Phase scope

Phase 0 stops at "binary runs on MiSTer and exits cleanly on missing
`Data.rsdk`." The MiSTer render backend (RETRO_RENDERDEVICE_MISTER),
native video writer, and FPGA wrapper are Phase 1/2/4 respectively; this
directory does not touch any of them.
