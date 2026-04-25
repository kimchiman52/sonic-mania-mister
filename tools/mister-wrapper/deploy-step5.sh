#!/usr/bin/env bash
# Sonic Mania MiSTer Phase 4 Step 5 deploy helper.
#
# Copies the HPS wrapper, the Sonic Mania RBF (if present), and the
# test-frame-writer to the MiSTer. Adds [Sonic Mania] section to MiSTer.ini
# if missing. Does NOT touch any user game data.
#
# Credentials default to host 192.168.1.188 and MISTER_PASSWORD=1 (see
# memory reference-mister-credentials.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MISTER_HOST="${MISTER_HOST:-192.168.1.188}"
MISTER_USER="${MISTER_USER:-root}"
MISTER_PASSWORD="${MISTER_PASSWORD:-1}"

WRAPPER_BIN="${ROOT_DIR}/build/mister-wrapper-hps/MiSTer_SonicMania"
TEST_FRAME_WRITER="${ROOT_DIR}/build/mister-wrapper-hps/test-frame-writer"
RBF_LOCAL="${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania.rbf"
# Phase 10: optional 16:9 widescreen RBF (built via build-core.sh --aspect 16:9).
# Filename suffix "_169" is the canonical aspect marker; the wrapper detects
# it from argv[1] at core-load time and emits SONIC_MANIA_ASPECT=widescreen.
RBF_LOCAL_169="${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania_169.rbf"

have_sshpass() { command -v sshpass >/dev/null 2>&1; }

ssh_remote() {
    if have_sshpass; then
        sshpass -p "${MISTER_PASSWORD}" ssh -o StrictHostKeyChecking=no "${MISTER_USER}@${MISTER_HOST}" "$@"
    else
        echo "sshpass not available; install via 'brew install hudochenkov/sshpass/sshpass'" >&2
        return 1
    fi
}

scp_remote() {
    local src=$1 dst=$2
    if have_sshpass; then
        sshpass -p "${MISTER_PASSWORD}" scp -o StrictHostKeyChecking=no "${src}" "${MISTER_USER}@${MISTER_HOST}:${dst}"
    else
        echo "sshpass not available" >&2
        return 1
    fi
}

echo "== Sonic Mania MiSTer deploy (Phase 4 Step 5) =="
echo "host=${MISTER_USER}@${MISTER_HOST}"

# Wrapper
if [ -f "${WRAPPER_BIN}" ]; then
    echo "-> copy wrapper ${WRAPPER_BIN} -> /media/fat/MiSTer_SonicMania"
    scp_remote "${WRAPPER_BIN}" "/media/fat/MiSTer_SonicMania"
else
    echo "!! no wrapper binary at ${WRAPPER_BIN}; run tools/mister-wrapper/build-hps.sh first"
fi

# RBF (4:3, default aspect)
if [ -f "${RBF_LOCAL}" ]; then
    echo "-> copy RBF ${RBF_LOCAL} -> /media/fat/_Other/Sonic Mania.rbf"
    scp_remote "${RBF_LOCAL}" "/media/fat/_Other/Sonic Mania.rbf"
else
    echo "!! no 4:3 RBF at ${RBF_LOCAL}"
    echo "   (not a deploy blocker; Quartus build runs separately on colima quartus2 VM)"
fi

# Phase 10: 16:9 widescreen RBF (optional). Shipped under a filename that
# preserves the "_169" marker so the wrapper's detect_aspect_from_rbf()
# resolves SONIC_MANIA_ASPECT=widescreen at core-load time.
if [ -f "${RBF_LOCAL_169}" ]; then
    echo "-> copy 16:9 RBF ${RBF_LOCAL_169} -> /media/fat/_Other/Sonic Mania_169.rbf"
    scp_remote "${RBF_LOCAL_169}" "/media/fat/_Other/Sonic Mania_169.rbf"
else
    echo "(no 16:9 RBF at ${RBF_LOCAL_169}; Phase 10 widescreen not deployed this run)"
fi

# Test frame writer -- place under /media/fat/games/sonic-mania/.
# Phase 7 Step 4: also pre-create saves/ and resources/ so the engine's
# MiSTer InitUserDirectory() arm has a stable home for SGame.bin etc.
ssh_remote "mkdir -p /media/fat/games/sonic-mania/logs /media/fat/games/sonic-mania/bin /media/fat/games/sonic-mania/lib /media/fat/games/sonic-mania/saves /media/fat/games/sonic-mania/resources"
if [ -f "${TEST_FRAME_WRITER}" ]; then
    echo "-> copy test-frame-writer -> /media/fat/games/sonic-mania/test-frame-writer"
    scp_remote "${TEST_FRAME_WRITER}" "/media/fat/games/sonic-mania/test-frame-writer"
    ssh_remote "chmod +x /media/fat/games/sonic-mania/test-frame-writer"
else
    echo "!! no test-frame-writer at ${TEST_FRAME_WRITER}"
fi

# Inject [Sonic Mania] and [Sonic Mania (16:9)] sections into MiSTer.ini.
#
# Both sections route through the same wrapper binary (main=MiSTer_SonicMania)
# and both disable the HDMI scaler (vga_scaler=0) so native_video reaches the
# CRT. The wrapper differentiates the two cores at runtime by inspecting the
# RBF filename it was loaded with (Sonic_Mania.rbf vs Sonic_Mania_169.rbf).
ssh_remote 'bash -s' <<'REMOTE_INI'
INI=/media/fat/MiSTer.ini
if ! grep -qi '^\[Sonic Mania\]' "$INI" 2>/dev/null && ! grep -qi '^\[SonicMania\]' "$INI" 2>/dev/null; then
    cat >> "$INI" << EOF

[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0
EOF
    echo "MiSTer.ini: added [Sonic Mania] section"
else
    echo "MiSTer.ini: [Sonic Mania] already present (not modified)"
fi

# Phase 10: per-RBF section for the 16:9 widescreen variant. MiSTer matches
# the section header against the core name shown in its menu, which for the
# Sonic_Mania_169.rbf comes from the CONF_STR header "Sonic Mania (16:9);..."
# patched into menu.sv at build time.
if ! grep -qi '^\[Sonic Mania (16:9)\]' "$INI" 2>/dev/null; then
    cat >> "$INI" << EOF

[Sonic Mania (16:9)]
main=MiSTer_SonicMania
vga_scaler=0
EOF
    echo "MiSTer.ini: added [Sonic Mania (16:9)] section"
else
    echo "MiSTer.ini: [Sonic Mania (16:9)] already present (not modified)"
fi
REMOTE_INI

echo "== deploy complete =="
echo "Next: boot 'Sonic Mania' from MiSTer _Other/ menu. Then SSH in and run:"
echo "    /media/fat/games/sonic-mania/test-frame-writer bars &"
