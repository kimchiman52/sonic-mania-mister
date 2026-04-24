#!/usr/bin/env bash
# Phase 7 Step 3: assemble a player-installable release tree (and ZIP) for
# the Sonic Mania MiSTer port.
#
# Inputs (default paths shown; each is overridable by env or CLI flag):
#   RUNTIME_INSTALL_PREFIX  build/mister-clean-install   (cmake --install tree)
#   HPS_BINARY              build/mister-wrapper-hps/MiSTer_SonicMania
#   CORE_RBF                build/mister-wrapper-core/Sonic_Mania.rbf
#                           (REQUIRED — Quartus build is upstream of this script;
#                            do NOT auto-build, refuse if missing)
#   WORK_DIR                build/mister-release
#
# Outputs:
#   ${WORK_DIR}/stage/...                           (FAT-rooted staging tree)
#   ${WORK_DIR}/sonic-mania-mister-<DATE>/...       (dated copy for direct inspection)
#   ${WORK_DIR}/sonic-mania-mister-<DATE>.zip       (release ZIP)
#   ${WORK_DIR}/sonic-mania-mister-<DATE>.zip.sha256
#
# Per project-release-naming.md, the date stamp uses ISO-8601 (YYYY-MM-DD).
# No version number anywhere in the artifact name.
#
# Per feedback-always-telemetry.md, the default flavor is `clean` (player
# release). Dev iteration with telemetry binaries works by overriding
# RUNTIME_INSTALL_PREFIX:
#
#   RUNTIME_INSTALL_PREFIX=build/mister-telemetry-install \
#       bash tools/mister-wrapper/build-release.sh
#
# Per feedback-releases-are-ours.md, this script does NOT push, tag, or
# call gh. It only builds the artifact. Publishing is a separate manual
# step against the user's own repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

INSTALL_README_TEMPLATE="${ROOT_DIR}/tools/mister/release-readme.txt"
LICENSE_FILE="${ROOT_DIR}/LICENSE.md"
BUILD_GAME_SCRIPT="${ROOT_DIR}/tools/mister/build-game.sh"

RUNTIME_INSTALL_PREFIX="${RUNTIME_INSTALL_PREFIX:-${ROOT_DIR}/build/mister-clean-install}"
RUNTIME_PACKAGE="${RUNTIME_PACKAGE:-${ROOT_DIR}/build/mister-clean-package}"
HPS_BINARY="${HPS_BINARY:-${ROOT_DIR}/build/mister-wrapper-hps/MiSTer_SonicMania}"
CORE_RBF="${CORE_RBF:-${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania.rbf}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build/mister-release}"
STAGE_DIR="${STAGE_DIR:-${WORK_DIR}/stage}"
RELEASE_DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
RELEASE_NAME="sonic-mania-mister-${RELEASE_DATE}"
DATED_DIR="${DATED_DIR:-${WORK_DIR}/${RELEASE_NAME}}"
OUTPUT_ZIP="${OUTPUT_ZIP:-${WORK_DIR}/${RELEASE_NAME}.zip}"
README_BASENAME="README.txt"
LICENSE_BASENAME="LICENSE.md"

usage() {
    cat <<EOF
Usage:
  tools/mister-wrapper/build-release.sh --check
  tools/mister-wrapper/build-release.sh [options]

Options:
  --runtime-install-prefix <dir>  cmake --install tree to package (default: clean flavor)
  --hps-binary <file>             MiSTer_SonicMania wrapper to include
  --core-rbf <file>               Sonic_Mania.rbf to include (REQUIRED, never auto-built)
  --work-dir <dir>                Working dir for stage / dated tree / zip
  --stage-dir <dir>               FAT-rooted staging directory
  --output-zip <file>             Final FAT-rooted release zip path
  --skip-zip                      Stop after producing the dated tree (no zip)
  --help                          Show this help

Defaults:
  runtime_install_prefix=${RUNTIME_INSTALL_PREFIX}
  hps_binary=${HPS_BINARY}
  core_rbf=${CORE_RBF}
  work_dir=${WORK_DIR}
  stage_dir=${STAGE_DIR}
  dated_dir=${DATED_DIR}
  output_zip=${OUTPUT_ZIP}

Notes:
  - Default flavor is clean (ENABLE_PERF_TELEMETRY=OFF). For dev iteration
    with telemetry binaries, run with:
      RUNTIME_INSTALL_PREFIX=build/mister-telemetry-install bash $0
  - Quartus RBF is NEVER auto-built. If --core-rbf is missing, the script
    exits with a specific error.
  - Releases use ISO-8601 dates only (no version numbers).
EOF
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required command not found: $1" >&2
        exit 1
    }
}

skip_zip=0
check_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --check) check_only=1; shift ;;
    --runtime-install-prefix) RUNTIME_INSTALL_PREFIX="$2"; shift 2 ;;
    --hps-binary) HPS_BINARY="$2"; shift 2 ;;
    --core-rbf) CORE_RBF="$2"; shift 2 ;;
    --work-dir)
        WORK_DIR="$2"
        STAGE_DIR="${WORK_DIR}/stage"
        DATED_DIR="${WORK_DIR}/${RELEASE_NAME}"
        OUTPUT_ZIP="${WORK_DIR}/${RELEASE_NAME}.zip"
        shift 2 ;;
    --stage-dir) STAGE_DIR="$2"; shift 2 ;;
    --output-zip) OUTPUT_ZIP="$2"; shift 2 ;;
    --skip-zip) skip_zip=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Each missing-input branch exits with a specific, actionable error string.
require_inputs() {
    if [ ! -f "${INSTALL_README_TEMPLATE}" ]; then
        echo "install README template not found: ${INSTALL_README_TEMPLATE}" >&2
        echo "  (Step 3 deliverable; should be tracked in git)" >&2
        return 1
    fi

    if [ ! -f "${LICENSE_FILE}" ]; then
        echo "LICENSE.md not found at repo root: ${LICENSE_FILE}" >&2
        return 1
    fi

    if [ ! -d "${RUNTIME_INSTALL_PREFIX}" ]; then
        echo "runtime install prefix not found: ${RUNTIME_INSTALL_PREFIX}" >&2
        echo "  (run: bash tools/mister/build-game.sh --flavor clean)" >&2
        return 1
    fi

    if [ ! -f "${RUNTIME_INSTALL_PREFIX}/bin/RSDKv5U" ]; then
        echo "engine binary not found: ${RUNTIME_INSTALL_PREFIX}/bin/RSDKv5U" >&2
        return 1
    fi

    if [ ! -f "${HPS_BINARY}" ]; then
        echo "HPS wrapper binary not found: ${HPS_BINARY}" >&2
        echo "  (run: bash tools/mister-wrapper/build-hps.sh)" >&2
        return 1
    fi

    if [ ! -f "${CORE_RBF}" ]; then
        echo "wrapper core RBF not found: ${CORE_RBF}" >&2
        echo "  (Quartus build is upstream of this script; build on the colima quartus2" >&2
        echo "   VM via tools/mister-wrapper/build-core.sh and copy the RBF here.)" >&2
        return 1
    fi
}

forbid_in_stage() {
    local path="$1"
    if [ -e "${path}" ]; then
        echo "forbidden release content present: ${path}" >&2
        echo "  (player releases must not ship logs, save data, or copyrighted assets)" >&2
        return 1
    fi
}

stage_release() {
    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}/_Other" \
             "${STAGE_DIR}/games/sonic-mania/bin" \
             "${STAGE_DIR}/games/sonic-mania/lib" \
             "${STAGE_DIR}/games/sonic-mania/scripts" \
             "${STAGE_DIR}/games/sonic-mania/saves" \
             "${STAGE_DIR}/games/sonic-mania/logs"

    # Wrapper binary at FAT root
    cp "${HPS_BINARY}" "${STAGE_DIR}/MiSTer_SonicMania"
    chmod +x "${STAGE_DIR}/MiSTer_SonicMania"

    # FPGA core under _Other (the OSD enumerates this directory)
    cp "${CORE_RBF}" "${STAGE_DIR}/_Other/Sonic Mania.rbf"

    # Engine binary, libs, launcher
    cp "${RUNTIME_INSTALL_PREFIX}/bin/RSDKv5U" "${STAGE_DIR}/games/sonic-mania/bin/RSDKv5U"
    chmod +x "${STAGE_DIR}/games/sonic-mania/bin/RSDKv5U"

    if [ -d "${RUNTIME_INSTALL_PREFIX}/lib" ]; then
        cp -a "${RUNTIME_INSTALL_PREFIX}/lib/." "${STAGE_DIR}/games/sonic-mania/lib/"
    elif [ -d "${RUNTIME_PACKAGE}/lib" ]; then
        # Fallback: package.sh stages libtheora into a sibling -package dir
        cp -a "${RUNTIME_PACKAGE}/lib/." "${STAGE_DIR}/games/sonic-mania/lib/"
    fi

    # Both lib/ source paths are optional individually, but at least one
    # must have produced libtheora.so.0 — the MiSTer rootfs lacks it and
    # the engine will fail to dlopen at launch otherwise.
    if [ ! -f "${STAGE_DIR}/games/sonic-mania/lib/libtheora.so.0" ]; then
        echo "ERR: libtheora.so.0 missing from stage; aborting" >&2
        echo "  (checked: ${RUNTIME_INSTALL_PREFIX}/lib and ${RUNTIME_PACKAGE}/lib)" >&2
        echo "  (run: bash tools/mister/build-libtheora.sh)" >&2
        exit 1
    fi

    if [ -f "${RUNTIME_PACKAGE}/scripts/run-mania.sh" ]; then
        cp "${RUNTIME_PACKAGE}/scripts/run-mania.sh" "${STAGE_DIR}/games/sonic-mania/scripts/run-mania.sh"
        chmod +x "${STAGE_DIR}/games/sonic-mania/scripts/run-mania.sh"
    fi

    # First-run onboarding placeholder so users know exactly where Data.rsdk
    # belongs. The wrapper / engine are responsible for the actual missing-
    # file error path; this is a fallback breadcrumb when the user looks at
    # the SD card directly.
    cat > "${STAGE_DIR}/games/sonic-mania/Data.rsdk.MISSING.txt" <<'PLACEHOLDER'
Place your legally-owned Sonic Mania `Data.rsdk` file in this directory,
named exactly `Data.rsdk`, then delete this `Data.rsdk.MISSING.txt` file.

Source paths on retail installs:
  Steam:  steamapps/common/Sonic Mania/Data.rsdk
  GOG:    GOG Galaxy/Games/Sonic Mania/Data.rsdk

Without `Data.rsdk` present the core will exit immediately back to the
MiSTer menu and log "Data.rsdk not found" to the wrapper log at:
  /media/fat/games/sonic-mania/logs/osd-wrapper.log

(See also `scripts/run-mania.sh` for the runtime-time onboarding path
the launcher takes when this file is missing.)
PLACEHOLDER

    # Top-level docs the user lands on after extraction
    cp "${INSTALL_README_TEMPLATE}" "${STAGE_DIR}/${README_BASENAME}"
    cp "${LICENSE_FILE}" "${STAGE_DIR}/${LICENSE_BASENAME}"

    # Defensive sanity: never ship logs / saves / Data.rsdk in a release
    forbid_in_stage "${STAGE_DIR}/games/sonic-mania/Data.rsdk" || return 1
    forbid_in_stage "${STAGE_DIR}/games/sonic-mania/log.txt" || return 1
    forbid_in_stage "${STAGE_DIR}/games/sonic-mania/SGame.bin" || return 1
    forbid_in_stage "${STAGE_DIR}/games/sonic-mania/Settings.ini" || return 1
}

build_dated_tree() {
    rm -rf "${DATED_DIR}"
    mkdir -p "$(dirname "${DATED_DIR}")"
    cp -a "${STAGE_DIR}" "${DATED_DIR}"
}

build_zip() {
    local zip_parent
    zip_parent="$(dirname "${OUTPUT_ZIP}")"
    mkdir -p "${zip_parent}"
    rm -f "${OUTPUT_ZIP}" "${OUTPUT_ZIP}.sha256"

    (
        cd "${STAGE_DIR}"
        # -y preserves symlinks (libtheora.so.0 → libtheora.so.0.3.10) so the
        #   ZIP doesn't double the lib payload by inlining the target as a
        #   second file. -X strips extended attrs / uid/gid for reproducibility.
        TZ=UTC zip -rqyX "${OUTPUT_ZIP}" \
            "MiSTer_SonicMania" \
            "_Other" \
            "games" \
            "${README_BASENAME}" \
            "${LICENSE_BASENAME}"
    )

    if command -v shasum >/dev/null 2>&1; then
        ( cd "$(dirname "${OUTPUT_ZIP}")" && shasum -a 256 "$(basename "${OUTPUT_ZIP}")" > "${OUTPUT_ZIP}.sha256" )
    elif command -v sha256sum >/dev/null 2>&1; then
        ( cd "$(dirname "${OUTPUT_ZIP}")" && sha256sum "$(basename "${OUTPUT_ZIP}")" > "${OUTPUT_ZIP}.sha256" )
    else
        echo "warning: neither shasum nor sha256sum found; skipping .sha256 sidecar" >&2
    fi
}

require_cmd cp
require_inputs || exit 1

if [ "${check_only}" -eq 1 ]; then
    echo "runtime_install_prefix=${RUNTIME_INSTALL_PREFIX}"
    echo "hps_binary=${HPS_BINARY}"
    echo "core_rbf=${CORE_RBF}"
    echo "stage_dir=${STAGE_DIR}"
    echo "dated_dir=${DATED_DIR}"
    echo "output_zip=${OUTPUT_ZIP}"
    exit 0
fi

if [ "${skip_zip}" -eq 0 ]; then
    require_cmd zip
fi

stage_release
build_dated_tree

if [ "${skip_zip}" -eq 0 ]; then
    build_zip
    echo "release_zip=${OUTPUT_ZIP}"
    [ -f "${OUTPUT_ZIP}.sha256" ] && echo "release_sha256=${OUTPUT_ZIP}.sha256"
fi

echo "release_stage=${STAGE_DIR}"
echo "release_dir=${DATED_DIR}"
echo "release_date=${RELEASE_DATE}"
