#!/usr/bin/env bash
# Phase 0 auxiliary: build a cairo-free libtheora + libtheoradec inside the
# Docker build container, and install them under /work-theora-install.
#
# Rationale (see tools/mister/package.sh for the matching bundling logic):
#   Debian Bullseye's libtheora0:armhf package links against libcairo2 — a
#   packaging quirk that pulls in X11, fontconfig, freetype, etc. MiSTer's
#   stock rootfs ships none of these, so bundling Debian's libtheora would
#   require bundling a dozen more SONAMEs transitively. Upstream libtheora
#   1.1.1's library itself has NO cairo dependency (cairo is only used by
#   the `dump_video` / `player_example` example programs). Building upstream
#   from source with `--disable-examples` gives us a clean libtheora whose
#   only runtime dep is libogg.
#
# This script is idempotent: if /work-theora-install/lib/libtheora.so.0.*
# already exists, it skips.

set -euo pipefail

if [ "${1:-}" != "--force" ] && [ -e /work-theora-install/lib/libtheora.so.0 ]; then
    echo "libtheora already built under /work-theora-install — skipping."
    echo "(Pass --force to rebuild.)"
    exit 0
fi

THEORA_TARBALL_URL="https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2"
SRC_DIR="/work-theora-src"

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

if [ ! -f libtheora-1.1.1.tar.bz2 ]; then
    echo "downloading libtheora-1.1.1 source..."
    curl -fsSL -o libtheora-1.1.1.tar.bz2 "$THEORA_TARBALL_URL"
fi

rm -rf libtheora-1.1.1 /work-theora-install
tar xjf libtheora-1.1.1.tar.bz2
cd libtheora-1.1.1

# libtool doesn't reliably propagate --target= to its link-mode clang
# invocations, so we embed target flags into CC itself. See phase-0-plan.md
# Step 4 troubleshooting notes about cross-link edge cases.
export CC="clang-20 --target=arm-linux-gnueabihf --gcc-toolchain=/usr"
export CFLAGS="-isystem /usr/arm-linux-gnueabihf/include -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard -O2 -fPIC"
export LDFLAGS=""
export PKG_CONFIG_LIBDIR="/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig"

./configure \
    --host=arm-linux-gnueabihf \
    --disable-examples \
    --disable-oggtest \
    --disable-vorbistest \
    --disable-spec \
    --enable-shared \
    --disable-static \
    --prefix=/work-theora-install

make -j"${JOBS:-2}"
make install

echo "---"
echo "built cairo-free libtheora at /work-theora-install/lib/"
ls -la /work-theora-install/lib/libtheora.so.0.* /work-theora-install/lib/libtheoradec.so.1.*
echo "---"
# Version-agnostic readelf probes: use a glob so a future xiph micro-bump
# (e.g. 1.1.2 shipping libtheoradec.so.1.1.5) doesn't break the script.
# Resolve each SONAME glob to a concrete file; bail loudly if the build
# produced nothing to probe.
theora_real="$(ls /work-theora-install/lib/libtheora.so.0.*.* 2>/dev/null | head -n 1 || true)"
theoradec_real="$(ls /work-theora-install/lib/libtheoradec.so.1.*.* 2>/dev/null | head -n 1 || true)"
if [ -z "${theora_real}" ] || [ -z "${theoradec_real}" ]; then
    echo "error: expected libtheora.so.0.* and libtheoradec.so.1.* under /work-theora-install/lib/" >&2
    ls -la /work-theora-install/lib/ >&2 || true
    exit 1
fi
echo "NEEDED on libtheora.so.0 (${theora_real##*/}):"
arm-linux-gnueabihf-readelf -d "${theora_real}" | grep NEEDED
echo "NEEDED on libtheoradec.so.1 (${theoradec_real##*/}):"
arm-linux-gnueabihf-readelf -d "${theoradec_real}" | grep NEEDED
