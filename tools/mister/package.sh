#!/usr/bin/env bash
# Phase 0 packager: takes a cmake --install prefix that contains bin/RSDKv5U
# and stages a MiSTer-ready directory tree with a headless launcher.
#
# Deliberately slim compared to the sibling 3sx-mister/tools/mister/package.sh
# (no license bundle, no OSD launcher, no SDL lib rehoming). Phase 7 polish
# picks up the heavier bits once we know which SONAMEs MiSTer ships.
#
# ===============================================================
# DEVIATION from docs/phase-0-plan.md Step 4
# ===============================================================
# The plan explicitly said "Do NOT create ${output_dir}/lib/ in Phase 0".
# That guidance predates the discovery (during M2 bring-up) that MiSTer's
# stock rootfs ships neither libtheora.so.0 nor libtheoradec.so.1. Without
# those SONAMEs, the binary cannot `dlopen` at startup and the Phase 0
# smoke test fails before reaching the Data.rsdk read path that the exit
# criterion targets.
#
# The deviation is: package.sh creates `${output_dir}/lib/` and bundles
# cairo-free libtheora/libtheoradec built by tools/mister/build-libtheora.sh.
# run-mania.sh prepends that dir to LD_LIBRARY_PATH. This is the minimum
# bundling required for the Phase 0 binary to load at all.
#
# Everything else the plan called out (SDL2 rehoming, license bundles,
# OSD launcher wrappers) is still deferred to Phase 7. See the same-named
# "Bundling deviation" subsection in docs/mister-runbook.md.
# ===============================================================

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <cmake-install-prefix> <output-dir>" >&2
    exit 1
fi

INSTALL_PREFIX="$1"
OUTPUT_DIR="$2"

if [ ! -d "$INSTALL_PREFIX" ]; then
    echo "Install prefix not found: $INSTALL_PREFIX" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/scripts"

if [ ! -f "$INSTALL_PREFIX/bin/RSDKv5U" ]; then
    echo "Missing binary: $INSTALL_PREFIX/bin/RSDKv5U" >&2
    echo "(The platforms/MiSTer.cmake install(TARGETS RetroEngine) rule may have failed to run.)" >&2
    exit 1
fi

cp "$INSTALL_PREFIX/bin/RSDKv5U" "$OUTPUT_DIR/bin/RSDKv5U"

# Bundle libs MiSTer's rootfs does NOT ship. Empirically (stock MiSTer kernel
# 5.15.1 as of 2026-04): SDL2, libogg, libasound, libstdc++ are present; but
# libtheora / libtheoradec are NOT. We bundle them here.
#
# IMPORTANT: Debian Bullseye's libtheora0:armhf is built with a link-time
# dependency on libcairo2 — which pulls in X11, fontconfig, freetype, etc.
# MiSTer does not ship any of these, so bundling Debian's copy would
# require dragging a dozen more SONAMEs along (many of which MiSTer also
# lacks). We instead prefer a locally-built, cairo-free libtheora from
# upstream source at /work-theora-install/ inside the container. Fall back
# to Debian's copy (with a warning) if that tree is not present.
#
# If $INSTALL_PREFIX is not inside a cross container (e.g., someone runs
# package.sh manually on macOS host), neither source exists — skip with a
# note. Deploy will then fail at runtime on device; fix is to run
# package.sh inside the container (via build-game.sh) not on the host.
CUSTOM_THEORA_DIR="/work-theora-install/lib"
SYSROOT_LIB_DIR="/usr/lib/arm-linux-gnueabihf"

bundle_soname_from() {
    local src_dir="$1"
    local soname="$2"
    local src="$src_dir/$soname"
    if [ ! -e "$src" ]; then
        return 1
    fi
    local real real_name
    real="$(readlink -f "$src")"
    real_name="$(basename "$real")"
    cp "$real" "$OUTPUT_DIR/lib/$real_name"
    ( cd "$OUTPUT_DIR/lib" && ln -sf "$real_name" "$soname" )
    return 0
}

for soname in libtheora.so.0 libtheoradec.so.1; do
    if [ -d "$CUSTOM_THEORA_DIR" ] && bundle_soname_from "$CUSTOM_THEORA_DIR" "$soname"; then
        echo "bundled $soname from $CUSTOM_THEORA_DIR (cairo-free, upstream)"
    elif [ -d "$SYSROOT_LIB_DIR" ] && bundle_soname_from "$SYSROOT_LIB_DIR" "$soname"; then
        echo "WARNING: bundled $soname from $SYSROOT_LIB_DIR (Debian, pulls libcairo!)" >&2
        echo "         Binary will fail at runtime on MiSTer. Build cairo-free" >&2
        echo "         libtheora via tools/mister/build-libtheora.sh first." >&2
    else
        echo "warning: could not bundle $soname — neither $CUSTOM_THEORA_DIR nor $SYSROOT_LIB_DIR has it." >&2
    fi
done

# Launcher. SDL_VIDEODRIVER=dummy is REQUIRED for Phase 0 because:
#   - MiSTer HPS has no X server, no Wayland, no stock /dev/fb0 available to
#     unprivileged processes in a useful way for SDL2.
#   - Leaving SDL2 to default to `kmsdrm` / `x11` / `wayland` causes the
#     backend to spin or abort at SDL_CreateWindow.
#   - In Phase 1, MiSTerRenderDevice replaces SDL2RenderDevice and the
#     SDL_VIDEODRIVER knob becomes irrelevant; until then, `dummy` lets SDL
#     initialize and the engine progress to the Data.rsdk read path.
cat > "$OUTPUT_DIR/scripts/run-mania.sh" <<'LAUNCHER'
#!/bin/sh
set -eu
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_DIR="$(CDPATH= cd -- "${SELF_DIR}/.." && pwd)"

# Force headless SDL2 video. Phase 1 wires MiSTerRenderDevice and this
# launcher override becomes moot.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"

# Prefer our bundled libtheora/libtheoradec (MiSTer rootfs doesn't ship
# them). SDL2/libogg/libasound/libstdc++ resolve from MiSTer's /usr/lib.
export LD_LIBRARY_PATH="${APP_DIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Run from the binary's directory so relative paths (like Data.rsdk lookup
# and settings.ini writeback) resolve next to the executable.
cd "${APP_DIR}"
exec ./bin/RSDKv5U "$@"
LAUNCHER

chmod +x "$OUTPUT_DIR/scripts/run-mania.sh" "$OUTPUT_DIR/bin/RSDKv5U"

echo "MiSTer package created at: $OUTPUT_DIR"
