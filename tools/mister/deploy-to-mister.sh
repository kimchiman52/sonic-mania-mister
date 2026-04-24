#!/usr/bin/env bash
# Phase 0 deploy helper. Minimal, opinionated: copies the packaged armhf
# binary + launcher under a whitelisted MiSTer path.
#
# Safety rails:
#   - NEVER uses rsync --delete. Memory feedback-no-rsync-delete.md: deleting
#     arbitrary files under /media/fat would destroy user game data.
#   - Remote base is whitelist-checked against a single allowed path to
#     catch typos before they touch the device.
#   - Defaults read credentials from env (MISTER_PASSWORD is the stock MiSTer
#     root password). Don't hardcode `1` in shell history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

flavor="${MANIA_FLAVOR:-telemetry}"
mister_host="${MISTER_HOST:-192.168.1.188}"
mister_user="${MISTER_USER:-root}"
mister_password="${MISTER_PASSWORD:-1}"
remote_base="${MISTER_REMOTE_BASE:-/media/fat/games/SonicMania}"
src_dir="${ROOT_DIR}/build/mister-${flavor}-package"

usage() {
    cat <<EOF
Usage:
  tools/mister/deploy-to-mister.sh

Environment:
  MANIA_FLAVOR       Which flavor package to deploy (default: telemetry)
  MISTER_HOST        MiSTer IP or hostname (default: 192.168.1.188)
  MISTER_USER        MiSTer SSH user (default: root)
  MISTER_PASSWORD    MiSTer SSH password (default: 1)
  MISTER_REMOTE_BASE Remote install dir (whitelisted; default: /media/fat/games/SonicMania)

Outputs:
  Copies \${src_dir} -> \${mister_user}@\${mister_host}:\${remote_base}/
  (no --delete; existing Data.rsdk and save state are preserved)
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ ! -d "${src_dir}" ]; then
    echo "No packaged build at ${src_dir}." >&2
    echo "Run 'tools/mister/build-game.sh --flavor ${flavor}' first." >&2
    exit 2
fi

if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not found. On macOS: brew install hudochenkov/sshpass/sshpass" >&2
    exit 2
fi

# Whitelist guard: refuse to deploy outside the canonical games/SonicMania
# directory. Phase 0 picks the space-free name per phase-0-plan.md Open
# Question 1; Phase 4 may rename to 'Sonic Mania' if/when we align with the
# FPGA core's RBF filename.
case "${remote_base}" in
    /media/fat/games/SonicMania|/media/fat/games/SonicMania/) ;;
    *)
        echo "refusing to deploy to non-whitelisted remote base: ${remote_base}" >&2
        echo "(whitelist: /media/fat/games/SonicMania)" >&2
        exit 3
        ;;
esac

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "ensuring remote directory exists: ${remote_base}"
sshpass -p "${mister_password}" ssh "${ssh_opts[@]}" \
    "${mister_user}@${mister_host}" "mkdir -p '${remote_base}'"

echo "copying ${src_dir}/ -> ${mister_user}@${mister_host}:${remote_base}/"
sshpass -p "${mister_password}" rsync -av --no-owner --no-group --no-perms \
    -e "ssh ${ssh_opts[*]}" \
    "${src_dir}/" \
    "${mister_user}@${mister_host}:${remote_base}/"

echo "deployed ${src_dir} -> ${mister_user}@${mister_host}:${remote_base}"
echo ""
echo "smoke test (runs for up to 10s then SIGTERMs):"
echo "  sshpass -p \"\${MISTER_PASSWORD}\" ssh ${ssh_opts[*]} ${mister_user}@${mister_host} \\"
echo "      'timeout -s TERM 10 ${remote_base}/scripts/run-mania.sh' 2>&1 | tee /tmp/mania-smoke.log"
