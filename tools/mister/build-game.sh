#!/usr/bin/env bash
# Phase 0 — canonical Docker-driven armhf cross-build for the Sonic Mania
# MiSTer port. Ported line-for-line from 3sx-mister/tools/mister/build-game.sh,
# with these diffs:
#
#   - Default container name: sonic-mania-mister-arm-build.
#   - Output binary path: dependencies/RSDKv5/... / installed to bin/RSDKv5U
#     (engine target name), NOT 3sx's bin/3s-arm.
#   - No `build-deps.sh --profile mister` step (Mania has no dep-build
#     script; SDL2/ogg/theora come from distro packages installed by
#     setup-build-container.sh).
#   - `-DPORT_MISTER=ON` flows through to dependencies/RSDKv5/platforms/MiSTer.cmake
#     via the sonic-mania-mister root CMakeLists.txt, which also forces
#     GAME_STATIC=ON, RETRO_SUBSYSTEM=SDL2, USE_SDL_AUDIO=ON,
#     RETRO_DISABLE_PLUS=ON before add_subdirectory(dependencies/RSDKv5).
#
# Phase 0 exit criterion: this script, called with --flavor telemetry, must
# produce build/mister-telemetry-install/bin/RSDKv5U as an ELF 32-bit LSB
# ARM hard-float executable. See docs/phase-0-plan.md Step 4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_CONTAINER_SCRIPT="${ROOT_DIR}/tools/mister/setup-build-container.sh"

container_name="${MISTER_BUILD_CONTAINER:-sonic-mania-mister-arm-build}"
platform="${MISTER_DOCKER_PLATFORM:-linux/amd64}"
flavor="telemetry"
jobs="${JOBS:-2}"

usage() {
    cat <<EOF
Usage:
  tools/mister/build-game.sh [options]

Purpose:
  Canonical Docker build for the Sonic Mania MiSTer runtime (Phase 0).
  Uses the validated Docker flow, builds in a container-local workdir, and
  copies ARM MiSTer outputs back into the host repo under build/.

Options:
  --flavor <telemetry|clean|both>   Build flavor to produce (default: ${flavor})
  --platform <docker-platform>      Docker platform for the build container
                                    (default: ${platform})
  --container <name>                Docker container name (default: ${container_name})
  --jobs <count>                    Parallel build jobs inside Docker (default: ${jobs})
  --help                            Show this message

Defaults:
  - The default platform is linux/amd64 (portable Docker path for macOS +
    other hosts that cannot execute linux/arm/v7 containers locally).
  - linux/amd64 uses the validated ARM cross-build flow and still produces
    a real armhf MiSTer binary.
  - linux/arm/v7 is supported when the host has binfmt_misc/QEMU support;
    Phase 0 does not recommend it due to macOS Docker Desktop perf.

Environment:
  EXTRA_CMAKE_ARGS                  Space-separated extra -D... flags forwarded
                                    verbatim to the inner cmake configure
                                    (e.g. 'EXTRA_CMAKE_ARGS="-DRETRO_MOD_LOADER=OFF"').
                                    Values with embedded whitespace or shell
                                    quoting are not supported; pass each
                                    \`-Dkey=value\` as a separate whitespace-
                                    delimited token.

Outputs:
  telemetry -> build/mister-telemetry-install, build/mister-telemetry-package
  clean     -> build/mister-clean-install, build/mister-clean-package
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --flavor)
        flavor="$2"
        shift 2
        ;;
    --platform)
        platform="$2"
        shift 2
        ;;
    --container)
        container_name="$2"
        shift 2
        ;;
    --jobs)
        jobs="$2"
        shift 2
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done

case "${flavor}" in
telemetry|clean|both)
    ;;
*)
    echo "--flavor must be one of telemetry, clean, or both" >&2
    exit 2
    ;;
esac

if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || [ "${jobs}" -le 0 ]; then
    echo "--jobs must be a positive integer" >&2
    exit 2
fi

require_cmd docker

"${SETUP_CONTAINER_SCRIPT}" --container "${container_name}" --platform "${platform}"

# EXTRA_CMAKE_ARGS is smuggled into the single-quoted heredoc as a positional.
docker exec -i "${container_name}" bash -s -- \
    "${platform}" "${flavor}" "${jobs}" "${EXTRA_CMAKE_ARGS:-}" <<'EOF'
set -euo pipefail

platform="$1"
flavor="$2"
jobs="$3"
extra_cmake_args="$4"
llvm_version="${MISTER_LLVM_VERSION:-20}"
workdir="/work-mister"

cross_build=0
if [ "${platform}" != "linux/arm/v7" ]; then
    cross_build=1
fi

mkdir -p "${workdir}"
# Rsync host tree into a container-local workdir so the build stays off the
# bind mount (avoids the tar --same-owner ownership errors documented in
# 3sx-mister's runbook). --delete keeps it idempotent across reruns.
rsync -a --delete \
    --exclude='.git/' \
    --exclude='build/' \
    /src/ "${workdir}/"
cd "${workdir}"

export CC="clang-${llvm_version}"
export CXX="clang++-${llvm_version}"

cmake_target_args=()
if [ "${cross_build}" -eq 1 ]; then
    export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
    export CFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include"
    export CXXFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include"
    export LDFLAGS="--target=arm-linux-gnueabihf --gcc-toolchain=/usr"
    cmake_target_args=(
        -DCMAKE_C_COMPILER_TARGET=arm-linux-gnueabihf
        -DCMAKE_CXX_COMPILER_TARGET=arm-linux-gnueabihf
    )
fi

build_one() {
    local flavor_name="$1"
    local telemetry_flag="$2"
    local build_dir="build/mister-${flavor_name}"
    local install_dir="build/mister-${flavor_name}-install"
    local package_dir="build/mister-${flavor_name}-package"
    local binary_path="${install_dir}/bin/RSDKv5U"

    local extra_args=()
    if [ -n "${extra_cmake_args}" ]; then
        read -ra extra_args <<< "${extra_cmake_args}"
    fi

    echo "cmake (final invocation): cmake -S . -B ${build_dir} -DCMAKE_BUILD_TYPE=Release -DPORT_MISTER=ON -DGAME_STATIC=ON -DRETRO_SUBSYSTEM=SDL2 -DUSE_SDL_AUDIO=ON -DRETRO_DISABLE_PLUS=ON -DENABLE_PERF_TELEMETRY=${telemetry_flag} ${cmake_target_args[*]-} ${extra_args[*]-}"

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

    # Post-build verification: the binary must be ARM and carry VFP tags.
    # Use arm-linux-gnueabihf-readelf when available (it's strictly more
    # informative than the host readelf on amd64, but both accept ARM ELF).
    if command -v arm-linux-gnueabihf-readelf >/dev/null 2>&1; then
        arm-linux-gnueabihf-readelf -h "${binary_path}" | grep -q "Machine:.*ARM"
        arm-linux-gnueabihf-readelf -A "${binary_path}" | grep -q "Tag_ABI_VFP_args"
    else
        readelf -h "${binary_path}" | grep -q "Machine:.*ARM"
        readelf -A "${binary_path}" | grep -q "Tag_ABI_VFP_args"
    fi
}

case "${flavor}" in
telemetry)
    build_one telemetry ON
    ;;
clean)
    build_one clean OFF
    ;;
both)
    build_one telemetry ON
    build_one clean OFF
    ;;
esac
EOF

mkdir -p "${ROOT_DIR}/build"

copy_out_dir() {
    local container_src="$1"
    local host_dst_parent="${ROOT_DIR}/build"
    local host_dst_name

    host_dst_name="$(basename "${container_src}")"
    rm -rf "${host_dst_parent}/${host_dst_name}"
    docker cp "${container_name}:${container_src}" "${host_dst_parent}/"
}

case "${flavor}" in
telemetry)
    copy_out_dir /work-mister/build/mister-telemetry-install
    copy_out_dir /work-mister/build/mister-telemetry-package
    ;;
clean)
    copy_out_dir /work-mister/build/mister-clean-install
    copy_out_dir /work-mister/build/mister-clean-package
    ;;
both)
    copy_out_dir /work-mister/build/mister-telemetry-install
    copy_out_dir /work-mister/build/mister-telemetry-package
    copy_out_dir /work-mister/build/mister-clean-install
    copy_out_dir /work-mister/build/mister-clean-package
    ;;
esac

echo "container=${container_name}"
echo "platform=${platform}"
echo "flavor=${flavor}"
if [ "${platform}" = "linux/arm/v7" ]; then
    echo "mode=native-arm-container"
else
    echo "mode=arm-cross-build"
fi

case "${flavor}" in
telemetry)
    echo "install_prefix=${ROOT_DIR}/build/mister-telemetry-install"
    echo "package_dir=${ROOT_DIR}/build/mister-telemetry-package"
    ;;
clean)
    echo "install_prefix=${ROOT_DIR}/build/mister-clean-install"
    echo "package_dir=${ROOT_DIR}/build/mister-clean-package"
    ;;
both)
    echo "install_prefix_telemetry=${ROOT_DIR}/build/mister-telemetry-install"
    echo "package_dir_telemetry=${ROOT_DIR}/build/mister-telemetry-package"
    echo "install_prefix_clean=${ROOT_DIR}/build/mister-clean-install"
    echo "package_dir_clean=${ROOT_DIR}/build/mister-clean-package"
    ;;
esac
