#!/usr/bin/env bash
# Sonic Mania FPGA core build driver.
#
# Forked from 3sx-mister/tools/mister-wrapper/build-core.sh. Differences:
#   - PROJECT_NAME defaults to "Sonic_Mania" (underscore; Quartus
#     PROJECT_REVISION does not accept spaces). The shipped RBF is
#     renamed to "Sonic Mania.rbf" (with space) at deploy time.
#   - Default seed is "menu" (unchanged — the Menu_MiSTer-derived fork is
#     the project template).
#   - CONF_STR replacement produces `"Sonic Mania;;"` in the patched .sv
#     (the space version is what the MiSTer menu displays to users).
#
# Phase 10: --aspect {4:3|16:9} selects which static aspect-ratio variant
# to build. One source tree, two RBFs, picked at the MiSTer menu.
#
#   --aspect 4:3  (default) -> ${OUTPUT_DIR}/Sonic_Mania.rbf
#                              (320x240 active, 27.000 MHz CLK_VIDEO,
#                               M=81/N=5/C=30, NTSC-exact)
#   --aspect 16:9           -> ${OUTPUT_DIR}/Sonic_Mania_169.rbf
#                              (424x240 active, 34.8276 MHz CLK_VIDEO,
#                               M=101/N=5/C=29; fallback M=89/N=5/C=25
#                               -> 35.6 MHz if Quartus rejects M=101)
#
# The 16:9 variant is produced by patching four prepared-source files with
# the per-aspect numeric literals (PLL coefficients, modeline totals/porches,
# DDR3 BUF1/LINE_BURST/LINE_STRIDE, CONF_STR header). The 4:3 variant uses
# the source tree as-is (canonical Phase 9c values).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ASPECT_VARIANT="${MISTER_WRAPPER_CORE_ASPECT:-4:3}"
case "${ASPECT_VARIANT}" in
    4:3|16:9) ;;
    *)
        echo "unsupported aspect variant: ${ASPECT_VARIANT} (must be 4:3 or 16:9)" >&2
        exit 1
        ;;
esac
case "${ASPECT_VARIANT}" in
    4:3)  ASPECT_PROJECT_SUFFIX="" ;;
    16:9) ASPECT_PROJECT_SUFFIX="_169" ;;
esac
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/build/mister-wrapper-core}"
BUILD_SRC_DIR="${OUTPUT_DIR}/src${ASPECT_PROJECT_SUFFIX}"
PROJECT_NAME_BASE="${MISTER_WRAPPER_CORE_NAME:-Sonic_Mania}"
PROJECT_NAME="${PROJECT_NAME_BASE}${ASPECT_PROJECT_SUFFIX}"
case "${ASPECT_VARIANT}" in
    4:3)  PROJECT_DISPLAY_NAME="${MISTER_WRAPPER_CORE_DISPLAY_NAME:-Sonic Mania}" ;;
    16:9) PROJECT_DISPLAY_NAME="${MISTER_WRAPPER_CORE_DISPLAY_NAME:-Sonic Mania (16:9)}" ;;
esac
CORE_SEED="${MISTER_WRAPPER_CORE_SEED:-menu}"
DOCKER_IMAGE="${MISTER_WRAPPER_CORE_IMAGE:-sonic-mania-mister-wrapper-quartus17}"
DOCKER_PLATFORM="${MISTER_WRAPPER_CORE_DOCKER_PLATFORM:-linux/amd64}"
DOCKER_BUILD_SCRIPT="${ROOT_DIR}/tools/mister-wrapper/build-quartus-image.sh"
CONTAINER_ROOT="${MISTER_WRAPPER_CORE_CONTAINER_ROOT:-/workspaces/sonic-mania-mister}"
CONTAINER_BUILD_SRC_DIR="${CONTAINER_ROOT}/build/mister-wrapper-core/src"
MISTER_QUARTUS_INSTALLER_DIR="${MISTER_QUARTUS_INSTALLER_DIR:-}"
QUARTUS_LICENSE_SPEC="${MISTER_QUARTUS_LICENSE_FILE:-${LM_LICENSE_FILE:-}}"
SOURCE_DIR=""
UPSTREAM_FILE=""
TEMPLATE_BASENAME=""
CONF_STR_TOKEN=""

usage() {
    cat <<EOF
Usage:
  tools/mister-wrapper/build-core.sh [--seed menu] [--aspect 4:3|16:9] --check-env
  tools/mister-wrapper/build-core.sh [--seed menu] [--aspect 4:3|16:9] --prepare-source
  tools/mister-wrapper/build-core.sh [--seed menu] [--aspect 4:3|16:9] --build-image
  tools/mister-wrapper/build-core.sh [--seed menu] [--aspect 4:3|16:9]

Purpose:
  Build the Sonic Mania FPGA core RBF (${PROJECT_NAME}.rbf) from the vendored
  Menu_MiSTer seed with Sonic Mania native-video parameters applied.

Planned output (depends on --aspect):
  ${OUTPUT_DIR}/${PROJECT_NAME_BASE}.rbf      (--aspect 4:3, default)
  ${OUTPUT_DIR}/${PROJECT_NAME_BASE}_169.rbf  (--aspect 16:9)

Default seed:
  ${CORE_SEED}

Default aspect:
  ${ASPECT_VARIANT}

Note: Quartus license is single-instance. Do not run --aspect 4:3 and
      --aspect 16:9 builds simultaneously; sequence them.
EOF
}

configure_seed() {
    case "${CORE_SEED}" in
        menu)
            SOURCE_DIR="${ROOT_DIR}/vendor/Menu_MiSTer"
            UPSTREAM_FILE="${ROOT_DIR}/vendor/Menu_MiSTer.UPSTREAM.md"
            TEMPLATE_BASENAME="menu"
            CONF_STR_TOKEN="MENU;UART31250,MIDI;"
            ;;
        *)
            echo "unsupported core seed: ${CORE_SEED}" >&2
            return 1
            ;;
    esac
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

require_base_tools() {
    have_command rsync || { echo "missing required command: rsync" >&2; return 1; }
    have_command ruby || { echo "missing required command: ruby" >&2; return 1; }
    configure_seed || return 1
    [ -d "${SOURCE_DIR}" ] || { echo "missing pinned wrapper-core source (${CORE_SEED}): ${SOURCE_DIR}" >&2; return 1; }
}

quartus_available_locally() {
    have_command quartus_sh && have_command quartus_cpf
}

docker_available() {
    have_command docker && [ -f "${DOCKER_BUILD_SCRIPT}" ]
}

docker_image_exists() {
    docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1
}

quartus_edition() {
    quartus_sh --version 2>/dev/null | awk '
        /Standard Edition/ { print "standard"; found=1; exit }
        /Lite Edition/ { print "lite"; found=1; exit }
        END { if (!found) print "unknown" }
    '
}

docker_build_possible() {
    [ -n "${MISTER_QUARTUS_INSTALLER_DIR}" ]
}

selected_build_mode() {
    if quartus_available_locally; then
        echo "local"
        return 0
    fi

    if docker_available && (docker_image_exists || docker_build_possible); then
        echo "docker"
        return 0
    fi

    echo "missing"
    return 1
}

prepare_source() {
    mkdir -p "${OUTPUT_DIR}"
    rm -rf "${BUILD_SRC_DIR}"
    rsync -a --delete --exclude='.git' "${SOURCE_DIR}/" "${BUILD_SRC_DIR}/"

    mv "${BUILD_SRC_DIR}/${TEMPLATE_BASENAME}.qpf" "${BUILD_SRC_DIR}/${PROJECT_NAME}.qpf"
    mv "${BUILD_SRC_DIR}/${TEMPLATE_BASENAME}.qsf" "${BUILD_SRC_DIR}/${PROJECT_NAME}.qsf"
    mv "${BUILD_SRC_DIR}/${TEMPLATE_BASENAME}.sv" "${BUILD_SRC_DIR}/${PROJECT_NAME}.sv"

    if [ -f "${BUILD_SRC_DIR}/${TEMPLATE_BASENAME}.sdc" ]; then
        mv "${BUILD_SRC_DIR}/${TEMPLATE_BASENAME}.sdc" "${BUILD_SRC_DIR}/${PROJECT_NAME}.sdc"
    fi


    ruby -e '
project = ARGV[4]
display = ARGV[5]
template = ARGV[6]
conf_str_token = ARGV[7]

qpf_path = ARGV[0]
qpf = File.read(qpf_path)
qpf.sub!(/PROJECT_REVISION = ".*?"/, %{PROJECT_REVISION = "#{project}"}) or
  abort("failed to patch PROJECT_REVISION in #{qpf_path}")
File.write(qpf_path, qpf)

qip_path = ARGV[1]
qip = File.read(qip_path)
qip.gsub!("#{template}.sdc", "#{project}.sdc")
qip.gsub!("#{template}.sv", "#{project}.sv") or
  abort("failed to patch #{template}.sv reference in #{qip_path}")
File.write(qip_path, qip)

sv_path = ARGV[2]
sv = File.read(sv_path)
# Phase 10: idempotent CONF_STR header rewrite. The canonical seed has been
# updated through Phase 9c so the header literal may already be
# "Sonic Mania;UART31250,MIDI;" rather than the original placeholder
# "MENU;UART31250,MIDI;". We accept either and rewrite to "<display>;UART31250,MIDI;".
# This lets --aspect 16:9 retarget "Sonic Mania" -> "Sonic Mania (16:9)"
# while leaving the trailing core options ("UART31250,MIDI") intact.
header_re = /"(?:MENU|Sonic Mania(?:\s*\(16:9\))?);UART31250,MIDI;"/
unless sv.sub!(header_re, %("#{display};UART31250,MIDI;"))
  abort("failed to patch CONF_STR header (display=#{display.inspect}) in #{sv_path}")
end
File.write(sv_path, sv)

current_project_path = ARGV[3]
if File.exist?(current_project_path)
  File.write(current_project_path, "#{project}\n")
end
' "${BUILD_SRC_DIR}/${PROJECT_NAME}.qpf" \
   "${BUILD_SRC_DIR}/files.qip" \
   "${BUILD_SRC_DIR}/${PROJECT_NAME}.sv" \
   "${BUILD_SRC_DIR}/CURRENT_PROJECT" \
   "${PROJECT_NAME}" \
   "${PROJECT_DISPLAY_NAME}" \
   "${TEMPLATE_BASENAME}" \
   "${CONF_STR_TOKEN}"

    if [ "${ASPECT_VARIANT}" = "16:9" ]; then
        apply_169_patches
    fi
}

# Phase 10: in-place patch of the prepared source tree to retarget every
# per-aspect numeric literal to 16:9 widescreen. Editing the prepared copy
# rather than ifdef'ing the canonical sources keeps the canonical tree
# clean and makes the 4:3 path identical to the Phase 9c shipping config.
#
# Patched files (in BUILD_SRC_DIR):
#   1. rtl/pll_video/pll_video_0002.v
#        27.000000 MHz (M=81/N=5/C=30)  ->  34.827600 MHz (M=101/N=5/C=29)
#        Fallback (manual swap if fitter rejects):
#          34.827600 MHz  ->  35.600000 MHz (M=89/N=5/C=25)
#
#   2. rtl/native_video_timing.sv
#        H_ACTIVE 320 -> 424
#        H_FP     26  -> 26   (kept; user can retune via OSD H Position)
#        H_SYNC   32  -> 32   (kept; standard NTSC sync width)
#        H_BP     51  -> 73   (424+26+32+73=555? recalc -> see below)
#        H_TOTAL  429 -> 545
#        V_FP     2   -> 4
#        V_SYNC   3   -> 3
#        V_BP     17  -> 19
#        V_TOTAL  262 -> 266
#        16:9 modeline math (paired with 8.7069 MHz pixel = CLK_VIDEO/4):
#          H_TOTAL = round(8,706,900 / 60.07 / 266) ... target is per
#          docs/phase-9-plan.md "16:9 widescreen" section (H_TOTAL=545,
#          V_TOTAL=266 -> refresh ~60.0 Hz).
#          H_FP+H_SYNC+H_BP = H_TOTAL - H_ACTIVE = 545-424 = 121
#          With H_FP=26, H_SYNC=32, H_BP = 121-26-32 = 63.
#        Vertical: V_FP+V_SYNC+V_BP = V_TOTAL-V_ACTIVE = 266-240 = 26.
#          V_FP=4, V_SYNC=3, V_BP=19.
#
#   3. rtl/native_video_reader.sv
#        Update doc-comment buffer-size table from 320x240 (153,600 B,
#        BUF1=0x25900) to 424x240 (203,520 B, BUF1=0x31C00).
#        Update LINE_BURST  80  -> 106  (424*2 = 848 B/line = 106 beats).
#        Update LINE_STRIDE 80  -> 106.
#        Update BUF1_ADDR   29'h07404B20 -> 29'h07406380
#               ( 0x3A031C00 >> 3  =  0x07406380; pairs with the engine's
#                 nv_buf1_offset_runtime = NV_BUF0_OFFSET + 424*240*2 ).
#
#   4. ${PROJECT_NAME}.sv  (renamed from menu.sv)
#        CONF_STR header:  "Sonic Mania;UART31250,MIDI;"
#                          -> "Sonic Mania (16:9);UART31250,MIDI;"
#        (already done by the main ruby pass via PROJECT_DISPLAY_NAME, which
#         is "Sonic Mania (16:9)" for the 16:9 variant. No additional patch
#         needed here.)
apply_169_patches() {
    local pll_file="${BUILD_SRC_DIR}/rtl/pll_video/pll_video_0002.v"
    local timing_file="${BUILD_SRC_DIR}/rtl/native_video_timing.sv"
    local reader_file="${BUILD_SRC_DIR}/rtl/native_video_reader.sv"

    [ -f "${pll_file}" ]    || { echo "missing PLL source for 16:9 patch: ${pll_file}" >&2; return 1; }
    [ -f "${timing_file}" ] || { echo "missing timing source for 16:9 patch: ${timing_file}" >&2; return 1; }
    [ -f "${reader_file}" ] || { echo "missing reader source for 16:9 patch: ${reader_file}" >&2; return 1; }

    ruby -e '
require "fileutils"

pll_path    = ARGV[0]
timing_path = ARGV[1]
reader_path = ARGV[2]

# ---- 1. PLL coefficients --------------------------------------------------
pll = File.read(pll_path)
pll.sub!(%(.output_clock_frequency0("25.600000 MHz")),
         %(.output_clock_frequency0("34.827600 MHz"))) or
  abort("16:9 patch: failed to retarget output_clock_frequency0 in #{pll_path}")
# Comment header: leave the 4:3 prose intact but append a 16:9 note. We only
# rewrite the single line that names the aspect explicitly.
pll.sub!(/\/\/ Sonic Mania pll_video instance — 4:3 NTSC-exact mode\./,
         "// Sonic Mania pll_video instance — 16:9 widescreen mode (Phase 10).") or
  abort("16:9 patch: failed to rewrite header banner in #{pll_path}")
File.write(pll_path, pll)

# ---- 2. Modeline totals + porches ----------------------------------------
timing = File.read(timing_path)
# Phase 10b: 4:3 source has been retuned to 6.4 MHz pixel clock (was 6.75)
# with H_TOTAL=407, H_FP=24, H_SYNC=31, H_BP=32 to widen the visible image.
# 16:9 stays at its original 8.7069 MHz / H_TOTAL=545 modeline (not yet
# widened — separate decision). V_ACTIVE pinned at 224 in both aspects.
# 16:9 V_TOTAL=266 leaves 39 lines of vertical porch; distribute V_FP=11 /
# V_BP=28 (NTSC-typical).
{
  "H_ACTIVE = 10\x27d320" => "H_ACTIVE = 10\x27d424",
  "H_FP     = 10\x27d24"  => "H_FP     = 10\x27d26",
  "H_SYNC   = 6\x27d31"   => "H_SYNC   = 6\x27d32",
  "H_BP     = 10\x27d32"  => "H_BP     = 10\x27d63",
  "H_TOTAL  = 10\x27d407" => "H_TOTAL  = 10\x27d545",
  "V_FP     = 9\x27d10"   => "V_FP     = 9\x27d11",
  "V_BP     = 9\x27d25"   => "V_BP     = 9\x27d28",
  "V_TOTAL  = 9\x27d262"  => "V_TOTAL  = 9\x27d266",
}.each do |from, to|
  next if from == to
  unless timing.sub!(from, to)
    abort("16:9 patch: failed to rewrite #{from.inspect} in #{timing_path}")
  end
end
File.write(timing_path, timing)

# ---- 3. DDR3 reader buffer/burst/stride ----------------------------------
reader = File.read(reader_path)
# Phase 10b 224p: 4:3 BUF1_ADDR is now 0x07404620 (320*224*2 + 0x100, qword
# offset). 16:9 frame_bytes = 424*224*2 = 0x2E600; BUF1 byte = 0x100+0x2E600
# = 0x2E700; qword = >>3 = 0x5CE0; BUF1_ADDR = 0x07400000 + 0x5CE0 = 0x07405CE0.
{
  "localparam [28:0] BUF1_ADDR   = 29\x27h07404620;  // 0x3A023100 >> 3" =>
    "localparam [28:0] BUF1_ADDR   = 29\x27h07405CE0;  // 0x3A02E700 >> 3 (424*224*2 + 0x100)",
  "localparam [7:0]  LINE_BURST  = 8\x27d80"  =>
    "localparam [7:0]  LINE_BURST  = 8\x27d106",
  "localparam [28:0] LINE_STRIDE = 29\x27d80" =>
    "localparam [28:0] LINE_STRIDE = 29\x27d106",
}.each do |from, to|
  unless reader.sub!(from, to)
    abort("16:9 patch: failed to rewrite #{from.inspect} in #{reader_path}")
  end
end
File.write(reader_path, reader)
' "${pll_file}" "${timing_file}" "${reader_file}"
}

build_project() {
    (
        cd "${BUILD_SRC_DIR}"
        quartus_sh --flow compile "${PROJECT_NAME}" -c "${PROJECT_NAME}"
    )

    local staged_rbf="${BUILD_SRC_DIR}/output_files/${PROJECT_NAME}.rbf"
    local staged_sof="${BUILD_SRC_DIR}/output_files/${PROJECT_NAME}.sof"

    if [ ! -f "${staged_rbf}" ] && [ -f "${staged_sof}" ]; then
        have_command quartus_cpf || { echo "missing required command: quartus_cpf" >&2; return 1; }
        quartus_cpf -c "${staged_sof}" "${staged_rbf}"
    fi

    [ -f "${staged_rbf}" ] || { echo "missing built RBF: ${staged_rbf}" >&2; return 1; }
    cp "${staged_rbf}" "${OUTPUT_DIR}/${PROJECT_NAME}.rbf"
}

build_docker_image() {
    docker_available || { echo "docker build path unavailable" >&2; return 1; }
    [ -n "${MISTER_QUARTUS_INSTALLER_DIR}" ] || { echo "missing MISTER_QUARTUS_INSTALLER_DIR for Quartus image build" >&2; return 1; }
    "${DOCKER_BUILD_SCRIPT}" --installer-dir "${MISTER_QUARTUS_INSTALLER_DIR}"
}

build_project_in_docker() {
    local docker_license_args=()

    docker_image_exists || build_docker_image

    if [ -n "${QUARTUS_LICENSE_SPEC}" ]; then
        if [ -f "${QUARTUS_LICENSE_SPEC}" ]; then
            local container_license_path="/tmp/quartus-license/$(basename "${QUARTUS_LICENSE_SPEC}")"
            docker_license_args+=(-v "${QUARTUS_LICENSE_SPEC}:${container_license_path}:ro")
            docker_license_args+=(-e "LM_LICENSE_FILE=${container_license_path}")
        else
            docker_license_args+=(-e "LM_LICENSE_FILE=${QUARTUS_LICENSE_SPEC}")
        fi
    fi

    docker run --rm \
        --platform "${DOCKER_PLATFORM}" \
        -u "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        "${docker_license_args[@]}" \
        -v "${ROOT_DIR}:${CONTAINER_ROOT}" \
        -w "${CONTAINER_BUILD_SRC_DIR}" \
        "${DOCKER_IMAGE}" \
        bash -lc "quartus_sh --flow compile '${PROJECT_NAME}' -c '${PROJECT_NAME}' && if [ ! -f output_files/${PROJECT_NAME}.rbf ] && [ -f output_files/${PROJECT_NAME}.sof ]; then quartus_cpf -c output_files/${PROJECT_NAME}.sof output_files/${PROJECT_NAME}.rbf; fi"

    local staged_rbf="${BUILD_SRC_DIR}/output_files/${PROJECT_NAME}.rbf"
    [ -f "${staged_rbf}" ] || { echo "missing built RBF after Docker compile: ${staged_rbf}" >&2; return 1; }
    cp "${staged_rbf}" "${OUTPUT_DIR}/${PROJECT_NAME}.rbf"
}

COMMAND=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --seed)
            [ "$#" -ge 2 ] || { echo "missing value for --seed" >&2; exit 1; }
            CORE_SEED="$2"
            shift 2
            ;;
        --aspect)
            [ "$#" -ge 2 ] || { echo "missing value for --aspect" >&2; exit 1; }
            ASPECT_VARIANT="$2"
            case "${ASPECT_VARIANT}" in
                4:3)  ASPECT_PROJECT_SUFFIX="" ;;
                16:9) ASPECT_PROJECT_SUFFIX="_169" ;;
                *)
                    echo "unsupported --aspect: ${ASPECT_VARIANT} (must be 4:3 or 16:9)" >&2
                    exit 1
                    ;;
            esac
            BUILD_SRC_DIR="${OUTPUT_DIR}/src${ASPECT_PROJECT_SUFFIX}"
            PROJECT_NAME="${PROJECT_NAME_BASE}${ASPECT_PROJECT_SUFFIX}"
            case "${ASPECT_VARIANT}" in
                4:3)  PROJECT_DISPLAY_NAME="${MISTER_WRAPPER_CORE_DISPLAY_NAME:-Sonic Mania}" ;;
                16:9) PROJECT_DISPLAY_NAME="${MISTER_WRAPPER_CORE_DISPLAY_NAME:-Sonic Mania (16:9)}" ;;
            esac
            shift 2
            ;;
        --fast|--release)
            echo "note: $1 is no longer needed (fast settings are now the default)" >&2
            shift
            ;;
        --check-env|--prepare-source|--build-image)
            [ -z "${COMMAND}" ] || { echo "multiple commands specified" >&2; exit 1; }
            COMMAND="$1"
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ "${COMMAND}" = "--check-env" ]; then
    require_base_tools || exit 1
    mkdir -p "${OUTPUT_DIR}"
    echo "core_seed=${CORE_SEED}"
    echo "aspect=${ASPECT_VARIANT}"
    echo "source_dir=${SOURCE_DIR}"
    if [ -f "${UPSTREAM_FILE}" ]; then
        echo "upstream_metadata=${UPSTREAM_FILE}"
    fi
    echo "planned_project=${BUILD_SRC_DIR}/${PROJECT_NAME}.qpf"
    echo "planned_output=${OUTPUT_DIR}/${PROJECT_NAME}.rbf"
    mode="$(selected_build_mode || true)"
    if [ "${mode}" = "local" ]; then
        echo "build_mode=local"
        echo "quartus_sh=$(command -v quartus_sh)"
        echo "quartus_edition=$(quartus_edition)"
    elif [ "${mode}" = "docker" ]; then
        echo "build_mode=docker"
        echo "docker_image=${DOCKER_IMAGE}"
        echo "docker_platform=${DOCKER_PLATFORM}"
        if [ -n "${QUARTUS_LICENSE_SPEC}" ]; then
            if [ -f "${QUARTUS_LICENSE_SPEC}" ]; then
                echo "license_source=file:${QUARTUS_LICENSE_SPEC}"
            else
                echo "license_source=env:${QUARTUS_LICENSE_SPEC}"
            fi
        else
            echo "license_source=missing"
        fi
        if docker_image_exists; then
            echo "docker_image_present=1"
        else
            echo "docker_image_present=0"
            echo "installer_dir=${MISTER_QUARTUS_INSTALLER_DIR}"
        fi
    else
        echo "missing Quartus build environment: install Quartus Lite or Standard locally, or set MISTER_QUARTUS_INSTALLER_DIR for Docker image builds" >&2
        exit 1
    fi
    exit 0
fi

if [ "${COMMAND}" = "--build-image" ]; then
    require_base_tools || exit 1
    build_docker_image
    exit 0
fi

if [ "${COMMAND}" = "--prepare-source" ]; then
    require_base_tools || exit 1
    prepare_source
    echo "core_seed=${CORE_SEED}"
    echo "aspect=${ASPECT_VARIANT}"
    echo "prepared_source=${BUILD_SRC_DIR}"
    echo "prepared_project=${BUILD_SRC_DIR}/${PROJECT_NAME}.qpf"
    exit 0
fi

require_base_tools || exit 1

prepare_source
mode="$(selected_build_mode || true)"
if [ "${mode}" = "local" ]; then
    build_project
elif [ "${mode}" = "docker" ]; then
    build_project_in_docker
else
    echo "missing Quartus build environment: install Quartus Lite or Standard locally, or set MISTER_QUARTUS_INSTALLER_DIR for Docker image builds" >&2
    exit 1
fi

echo "built_output=${OUTPUT_DIR}/${PROJECT_NAME}.rbf"
