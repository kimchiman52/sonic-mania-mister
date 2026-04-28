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
#   ${WORK_DIR}/stage/...                              (FAT-rooted staging tree)
#   ${WORK_DIR}/sonic-mania-mister-<VERSION>/...       (versioned copy for direct inspection)
#   ${WORK_DIR}/sonic-mania-mister-<VERSION>.zip       (release ZIP)
#   ${WORK_DIR}/sonic-mania-mister-<VERSION>.zip.sha256
#
# Release artifacts are versioned (semver-ish, no leading "v"). Override
# the version with RELEASE_VERSION=… or --version <x.y.z>. Default tracks
# the current in-progress release; bump it when shipping.
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
# Phase 10c dual-aspect: ship both RBFs (16:9 default + 4:3 named).
# These default to the unsuffixed symlinks that build-core.sh maintains
# pointing at the latest dated build (Sonic_Mania_YYYYMMDD.rbf and
# Sonic_Mania_43_YYYYMMDD.rbf). The stager resolves them via readlink -f
# so the dated basename ends up in _Other/ on the SD card.
CORE_RBF_169="${CORE_RBF_169:-${CORE_RBF:-${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania.rbf}}"
CORE_RBF_43="${CORE_RBF_43:-${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania_43.rbf}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build/mister-release}"
STAGE_DIR="${STAGE_DIR:-${WORK_DIR}/stage}"
RELEASE_VERSION="${RELEASE_VERSION:-0.1.0}"
RELEASE_NAME="sonic-mania-mister-${RELEASE_VERSION}"
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
  --core-rbf-169 <file>           16:9 RBF to include (default Sonic_Mania.rbf symlink)
  --core-rbf-43  <file>           4:3 RBF to include (default Sonic_Mania_43.rbf symlink)
  --core-rbf <file>               Alias for --core-rbf-169 (legacy)
  --work-dir <dir>                Working dir for stage / dated tree / zip
  --stage-dir <dir>               FAT-rooted staging directory
  --output-zip <file>             Final FAT-rooted release zip path
  --version <x.y.z>               Release version stamped into artifact name (default ${RELEASE_VERSION})
  --skip-zip                      Stop after producing the versioned tree (no zip)
  --help                          Show this help

Defaults:
  runtime_install_prefix=${RUNTIME_INSTALL_PREFIX}
  hps_binary=${HPS_BINARY}
  core_rbf_169=${CORE_RBF_169}
  core_rbf_43=${CORE_RBF_43}
  work_dir=${WORK_DIR}
  stage_dir=${STAGE_DIR}
  dated_dir=${DATED_DIR}
  output_zip=${OUTPUT_ZIP}
  release_version=${RELEASE_VERSION}

Notes:
  - Default flavor is clean (ENABLE_PERF_TELEMETRY=OFF). For dev iteration
    with telemetry binaries, run with:
      RUNTIME_INSTALL_PREFIX=build/mister-telemetry-install bash $0
  - Quartus RBF is NEVER auto-built. If --core-rbf-169 / --core-rbf-43 is
    missing, the script exits with a specific error.
  - Releases use semver-ish version numbers (no leading "v"). Bump
    RELEASE_VERSION (or pass --version) when shipping.
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
    --core-rbf|--core-rbf-169) CORE_RBF_169="$2"; shift 2 ;;
    --core-rbf-43) CORE_RBF_43="$2"; shift 2 ;;
    --version)
        RELEASE_VERSION="$2"
        RELEASE_NAME="sonic-mania-mister-${RELEASE_VERSION}"
        DATED_DIR="${WORK_DIR}/${RELEASE_NAME}"
        OUTPUT_ZIP="${WORK_DIR}/${RELEASE_NAME}.zip"
        shift 2 ;;
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

    if [ ! -f "${CORE_RBF_169}" ]; then
        echo "16:9 RBF not found: ${CORE_RBF_169}" >&2
        echo "  (Quartus build is upstream of this script; build on the colima quartus2" >&2
        echo "   VM via tools/mister-wrapper/build-core.sh --aspect 16:9 and copy the RBF here.)" >&2
        return 1
    fi

    if [ ! -f "${CORE_RBF_43}" ]; then
        echo "4:3 RBF not found: ${CORE_RBF_43}" >&2
        echo "  (Quartus build is upstream of this script; build on the colima quartus2" >&2
        echo "   VM via tools/mister-wrapper/build-core.sh --aspect 4:3 and copy the RBF here.)" >&2
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

    # FPGA cores under _Other (the OSD enumerates this directory). Resolve
    # the input symlinks to their dated targets so the SD card ends up
    # with Sonic_Mania_YYYYMMDD.rbf / Sonic_Mania_43_YYYYMMDD.rbf — the
    # MiSTer firmware auto-picks the newest dated file when multiple
    # variants of the same prefix exist.
    local rbf_169_dated rbf_43_dated
    rbf_169_dated="$(basename "$(readlink -f "${CORE_RBF_169}")")"
    rbf_43_dated="$(basename "$(readlink -f "${CORE_RBF_43}")")"
    cp "${CORE_RBF_169}" "${STAGE_DIR}/_Other/${rbf_169_dated}"
    cp "${CORE_RBF_43}"  "${STAGE_DIR}/_Other/${rbf_43_dated}"

    # Engine binary, libs, launcher
    cp "${RUNTIME_INSTALL_PREFIX}/bin/RSDKv5U" "${STAGE_DIR}/games/sonic-mania/bin/RSDKv5U"
    chmod +x "${STAGE_DIR}/games/sonic-mania/bin/RSDKv5U"

    # Ship libtheora + libtheoradec under their SONAME basenames as REGULAR
    # FILES (not symlinks), so the resulting ZIP doesn't contain symlink
    # entries — Windows extractors like 7-Zip refuse to materialize symlinks
    # without admin privileges and fail with "A required privilege is not
    # held by the client". The dynamic linker on the MiSTer finds these by
    # SONAME via LD_LIBRARY_PATH=${APP_DIR}/lib in run-mania.sh; the file
    # basename matching the SONAME is the canonical Linux convention.
    ship_lib() {
        local soname="$1"
        local target="${STAGE_DIR}/games/sonic-mania/lib/${soname}"
        local src_dir
        for src_dir in "${RUNTIME_INSTALL_PREFIX}/lib" "${RUNTIME_PACKAGE}/lib"; do
            [ -d "${src_dir}" ] || continue
            # cp -L follows the soname symlink (if present in cmake install
            # tree) to its target's content. Falls through to the
            # version-named regular file if no symlink exists.
            if [ -e "${src_dir}/${soname}" ]; then
                cp -L "${src_dir}/${soname}" "${target}"
                return 0
            fi
            # Fallback: pick the most-recent versioned variant
            # (libtheora.so.0.3.10, libtheoradec.so.1.1.4, etc.).
            local found
            found=$(ls -1 "${src_dir}/${soname}".* 2>/dev/null | sort | tail -n 1)
            if [ -n "${found}" ]; then
                cp "${found}" "${target}"
                return 0
            fi
        done
        echo "ERR: ${soname} not found in lib/ source dirs" >&2
        echo "  (checked: ${RUNTIME_INSTALL_PREFIX}/lib and ${RUNTIME_PACKAGE}/lib)" >&2
        echo "  (run: bash tools/mister/build-libtheora.sh)" >&2
        return 1
    }
    ship_lib libtheora.so.0    || exit 1
    ship_lib libtheoradec.so.1 || exit 1

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
        # No -y: we want zip to dereference any stray symlink rather than
        #   record a symlink entry. Windows extractors (7-Zip, Explorer) refuse
        #   to materialize symlinks without admin and abort with "A required
        #   privilege is not held by the client". stage_release ships libs
        #   under their SONAME basenames as regular files, so this is
        #   belt-and-suspenders. -X strips extended attrs / uid/gid for
        #   reproducibility.
        TZ=UTC zip -rqX "${OUTPUT_ZIP}" \
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
    echo "core_rbf_169=${CORE_RBF_169}"
    echo "core_rbf_43=${CORE_RBF_43}"
    echo "stage_dir=${STAGE_DIR}"
    echo "release_dir=${DATED_DIR}"
    echo "output_zip=${OUTPUT_ZIP}"
    echo "release_version=${RELEASE_VERSION}"
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
echo "release_version=${RELEASE_VERSION}"
