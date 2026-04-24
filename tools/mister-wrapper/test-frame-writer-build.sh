#!/usr/bin/env bash
# Cross-compile the Sonic Mania test-frame writer (Phase 4 Step 5) for armhf.
# Reuses the HPS-wrapper Docker image's gcc-arm-10.2 toolchain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/build/mister-wrapper-hps}"
DOCKER_IMAGE="${MISTER_WRAPPER_HPS_IMAGE:-sonic-mania-mister-wrapper-hps}"
DOCKER_PLATFORM="${MISTER_WRAPPER_HPS_DOCKER_PLATFORM:-linux/amd64}"
TOOLCHAIN_PREFIX="${MISTER_TOOLCHAIN_PREFIX:-arm-none-linux-gnueabihf}"
CC_BIN="${TOOLCHAIN_PREFIX}-gcc"

SRC="${SCRIPT_DIR}/test-frame-writer.c"
OUT="${OUTPUT_DIR}/test-frame-writer"

mkdir -p "${OUTPUT_DIR}"

if command -v "${CC_BIN}" >/dev/null 2>&1; then
    "${CC_BIN}" -O2 -Wall -Wextra -static -o "${OUT}" "${SRC}"
elif command -v docker >/dev/null 2>&1; then
    docker run --rm \
        --platform "${DOCKER_PLATFORM}" \
        -u "$(id -u):$(id -g)" \
        -v "${ROOT_DIR}:/work" \
        -w /work \
        "${DOCKER_IMAGE}" \
        bash -lc "TOOLCHAIN_BIN=\$(echo /usr/local/bin/gcc-arm-*/bin); export PATH=\$PATH:\$TOOLCHAIN_BIN; ${CC_BIN} -O2 -Wall -Wextra -static -o build/mister-wrapper-hps/test-frame-writer tools/mister-wrapper/test-frame-writer.c"
else
    echo "no local ${CC_BIN} and no docker: cannot cross-compile" >&2
    exit 1
fi

file "${OUT}" 2>&1 | head -1
echo "built_output=${OUT}"
