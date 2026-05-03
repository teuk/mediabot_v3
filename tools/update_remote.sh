#!/bin/bash
# =============================================================================
# tools/update_remote.sh — Automated update procedure for nbot.soyou.rocks
# =============================================================================
# Automates:
#   1. Ask the bot to die (via IRC raw command or partyline)
#   2. Rotate the installation folder
#   3. Copy Hailo brain data from previous install
#   4. Restore config file
#   5. Restart the bot
#
# Usage:
#   bash tools/update_remote.sh [options]
#
# Options:
#   --host   <host>   Remote host (default: nbot.soyou.rocks)
#   --user   <user>   SSH user    (default: current user)
#   --port   <port>   SSH port    (default: 22)
#   --dir    <dir>    Remote bot directory (default: ~/mediabot_v3)
#   --no-restart      Skip bot restart after update
#   --dry-run         Print commands without executing them
#   --help
#
# Requirements: ssh, rsync, git (on remote)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
REMOTE_HOST="${REMOTE_HOST:-nbot.soyou.rocks}"
REMOTE_USER="${REMOTE_USER:-${USER}}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-~/mediabot_v3}"
NO_RESTART=0
DRY_RUN=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       REMOTE_HOST="$2"; shift 2 ;;
        --user)       REMOTE_USER="$2"; shift 2 ;;
        --port)       REMOTE_PORT="$2"; shift 2 ;;
        --dir)        REMOTE_DIR="$2";  shift 2 ;;
        --no-restart) NO_RESTART=1;     shift   ;;
        --dry-run)    DRY_RUN=1;        shift   ;;
        --help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

SSH="ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${REMOTE_DIR%/}_backup_${DATE}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
run()  {
    log "RUN: $*"
    if [[ $DRY_RUN -eq 0 ]]; then
        eval "$@"
    else
        log "(dry-run — skipped)"
    fi
}
rsh()  {
    local cmd="$*"
    run "$SSH" "\"$cmd\""
}

# ── Step 1: Signal the bot to shut down ──────────────────────────────────────
log "=== Step 1: Stopping bot on ${REMOTE_HOST} ==="

# Try partyline first (telnet localhost port), fall back to kill
PARTYLINE_PORT=$(rsh "grep -oP 'PARTYLINE_PORT\\s*=\\s*\\K\\d+' ${REMOTE_DIR}/mediabot.conf 2>/dev/null || echo 23456" || echo 23456)

rsh "
  if command -v telnet >/dev/null 2>&1; then
    echo -e 'brb\\n.die update in progress\\n' | telnet 127.0.0.1 ${PARTYLINE_PORT} 2>/dev/null || true
  fi
  sleep 2
  pkill -f 'perl.*mediabot.pl' || true
  sleep 2
"

log "Bot stopped."

# ── Step 2: Backup current installation ──────────────────────────────────────
log "=== Step 2: Rotating installation (backup to ${BACKUP_DIR}) ==="
rsh "cp -a ${REMOTE_DIR} ${BACKUP_DIR}"
log "Backup created: ${BACKUP_DIR}"

# ── Step 3: Pull latest code ─────────────────────────────────────────────────
log "=== Step 3: Pulling latest code ==="
rsh "cd ${REMOTE_DIR} && git pull --ff-only"

# ── Step 4: Restore config ───────────────────────────────────────────────────
log "=== Step 4: Restoring config ==="
CONFIG_FILES=(
    "mediabot.conf"
    "mediabot.sample.conf"
)
for f in "${CONFIG_FILES[@]}"; do
    if rsh "test -f ${BACKUP_DIR}/${f}"; then
        rsh "cp ${BACKUP_DIR}/${f} ${REMOTE_DIR}/${f}"
        log "  Restored: $f"
    fi
done

# ── Step 5: Restore Hailo brain data ─────────────────────────────────────────
log "=== Step 5: Restoring Hailo brain ==="
HAILO_DIRS=("hailo" "data/hailo" "brain")
for d in "${HAILO_DIRS[@]}"; do
    if rsh "test -d ${BACKUP_DIR}/${d}"; then
        rsh "rsync -a --delete ${BACKUP_DIR}/${d}/ ${REMOTE_DIR}/${d}/"
        log "  Restored Hailo dir: $d"
        break
    fi
done

# ── Step 6: Check schema drift ───────────────────────────────────────────────
log "=== Step 6: Schema drift check ==="
if rsh "test -f ${REMOTE_DIR}/tools/check_schema_drift.pl"; then
    rsh "cd ${REMOTE_DIR} && perl -I. tools/check_schema_drift.pl \
        --db \$(grep -oP 'MAIN_PROG_DB\\s*=\\s*\\K\\S+' mediabot.conf | head -1) \
        --user \$(grep -oP 'MAIN_PROG_DB_USER\\s*=\\s*\\K\\S+' mediabot.conf | head -1) \
        --pass \$(grep -oP 'MAIN_PROG_DB_PASS\\s*=\\s*\\K\\S+' mediabot.conf | head -1) \
        2>/dev/null || echo 'Schema drift detected — check logs'" || true
fi

# ── Step 7: Restart ───────────────────────────────────────────────────────────
if [[ $NO_RESTART -eq 0 ]]; then
    log "=== Step 7: Restarting bot ==="
    rsh "cd ${REMOTE_DIR} && nohup ./start > /tmp/mediabot_restart.log 2>&1 &"
    sleep 3
    rsh "pgrep -f 'perl.*mediabot.pl' && echo 'Bot is running.' || echo 'WARNING: bot process not found!'"
else
    log "=== Step 7: Restart skipped (--no-restart) ==="
fi

log "=== Update complete ==="
log "  Remote  : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
log "  Backup  : ${BACKUP_DIR}"
log "  Dry-run : ${DRY_RUN}"
