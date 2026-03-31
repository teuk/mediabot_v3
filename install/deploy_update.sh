#!/usr/bin/env bash
set -euo pipefail

# Resolve script, project, and parent directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(readlink -f "${SCRIPT_DIR}/..")"
PARENT_DIR="$(readlink -f "${PROJECT_DIR}/..")"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
TARGET_REAL="$PROJECT_DIR"

CURRENT_HOST="$(hostname -f 2>/dev/null || hostname)"
CURRENT_USER="$(id -un)"

# +-------------------------------------------------------------------------+
# | [0] Safety check: refuse to run on teuk.org production instance        |
# +-------------------------------------------------------------------------+
if [ "$CURRENT_USER" = "mediabot" ] &&    echo "$CURRENT_HOST" | grep -qi "teuk\.org" &&    [ "$TARGET_REAL" = "/home/mediabot/mediabot_v3" ]; then
    echo "🚫 Refusing to update the production instance on teuk.org."
    echo "   Use the IRC command or a manual procedure on this server."
    exit 1
fi

TMP_CLONE_DIR=""
BOT_PID=""
ROLLED_BACK=0

cleanup() {
    if [ -n "${TMP_CLONE_DIR}" ] && [ -d "${TMP_CLONE_DIR}" ]; then
        rm -rf "${TMP_CLONE_DIR}"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "==> Host: ${CURRENT_HOST}"
echo "==> User: ${CURRENT_USER}"
echo "==> Script directory: ${SCRIPT_DIR}"
echo "==> Project directory: ${PROJECT_DIR}"
echo "==> Parent directory: ${PARENT_DIR}"
echo

# Safety checks
[ "${PROJECT_NAME}" = "mediabot_v3" ] || fail "project directory name is '${PROJECT_NAME}', expected 'mediabot_v3'"
[ -f "${PROJECT_DIR}/mediabot.pl" ] || fail "${PROJECT_DIR}/mediabot.pl not found"
[ -d "${PARENT_DIR}" ] || fail "parent directory ${PARENT_DIR} does not exist"

# +-------------------------------------------------------------------------+
# | [1] Determine the next version number                                   |
# +-------------------------------------------------------------------------+
LAST_VER="$(
    find "$PARENT_DIR" -maxdepth 1 -type d -name 'mediabot_v3.*' -printf '%f\n' 2>/dev/null \
    | sed -n 's/^mediabot_v3\.\([0-9][0-9]*\)$/\1/p' \
    | sort -n \
    | tail -1 \
    || true
)"
NEXT_VER=$(( ${LAST_VER:-0} + 1 ))
BACKUP_DIR="${PARENT_DIR}/mediabot_v3.${NEXT_VER}"

echo "==> Next archive version: ${NEXT_VER}"
echo "==> Backup directory will be: ${BACKUP_DIR}"
echo

# +-------------------------------------------------------------------------+
# | [2] Find the running instance to stop                                   |
# +-------------------------------------------------------------------------+
while IFS= read -r PID; do
    [ -z "$PID" ] && continue

    CMDLINE="$(tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null || true)"
    [ -z "$CMDLINE" ] && continue

    CONF_ARG=""
    for arg in $CMDLINE; do
        case "$arg" in
            --conf=*)
                CONF_ARG="${arg#--conf=}"
                break
                ;;
        esac
    done
    [ -z "$CONF_ARG" ] && continue

    if [[ "$CONF_ARG" = /* ]]; then
        CONF_ABS="$CONF_ARG"
    else
        PROC_CWD="$(readlink -f "/proc/${PID}/cwd" 2>/dev/null || true)"
        [ -z "$PROC_CWD" ] && continue
        CONF_ABS="${PROC_CWD}/${CONF_ARG}"
    fi

    CONF_REAL="$(readlink -f "$CONF_ABS" 2>/dev/null || echo "$CONF_ABS")"
    CONF_DIR="$(dirname "$CONF_REAL")"

    if [ "$CONF_DIR" = "$TARGET_REAL" ]; then
        BOT_PID="$PID"
        echo "🔎 Found matching instance: PID=${PID} conf=${CONF_REAL}"
        break
    fi
done < <(pgrep -f 'mediabot\.pl' 2>/dev/null || true)

if [ -n "$BOT_PID" ]; then
    echo "🛑 Sending SIGTERM to PID ${BOT_PID} ..."
    kill -15 "$BOT_PID"

    WAIT=0
    while kill -0 "$BOT_PID" 2>/dev/null; do
        sleep 1
        WAIT=$((WAIT + 1))
        if [ "$WAIT" -ge 30 ]; then
            echo "⚠️  Still running after 30 seconds — sending SIGKILL ..."
            kill -9 "$BOT_PID" 2>/dev/null || true
            break
        fi
    done

    echo "✅ Bot stopped."
else
    echo "ℹ️  No running mediabot instance found for ${PROJECT_DIR}."
fi
echo

# +-------------------------------------------------------------------------+
# | [3] Clone the latest version into a temporary directory                 |
# +-------------------------------------------------------------------------+
TMP_CLONE_DIR="$(mktemp -d "${PARENT_DIR}/mediabot_v3.new.XXXXXX")"
echo "🌐 Cloning the latest version from GitHub into ${TMP_CLONE_DIR} ..."

git clone https://github.com/teuk/mediabot_v3 "${TMP_CLONE_DIR}"
[ -f "${TMP_CLONE_DIR}/mediabot.pl" ] || fail "clone completed but mediabot.pl is missing in ${TMP_CLONE_DIR}"
echo

# +-------------------------------------------------------------------------+
# | [4] Restore config and Hailo brain into the temporary clone             |
# +-------------------------------------------------------------------------+
echo "⚙️  Restoring config and Hailo brain into the staged release ..."

if [ -f "${PROJECT_DIR}/mediabot.conf" ]; then
    cp -pfv "${PROJECT_DIR}/mediabot.conf" "${TMP_CLONE_DIR}/"
else
    echo "⚠️  Warning: mediabot.conf was not found in ${PROJECT_DIR}."
fi

LATEST_BRAIN="$(
    find "$PARENT_DIR" -maxdepth 2 -type f \( -path '*/mediabot_v3/*.brn' -o -path '*/mediabot_v3.*/*.brn' \) -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2- \
    || true
)"
if [ -n "${LATEST_BRAIN}" ]; then
    cp -pfv "${LATEST_BRAIN}" "${TMP_CLONE_DIR}/"
else
    echo "⚠️  Warning: no .brn brain file was found in the current or archived releases."
fi
echo

# +-------------------------------------------------------------------------+
# | [5] Validate the staged release before switching                        |
# +-------------------------------------------------------------------------+
echo "🔍 Checking Perl syntax in the staged release ..."
(
    cd "${TMP_CLONE_DIR}"
    perl -c mediabot.pl
)
echo "✅ Staged release passed syntax validation."
echo

# +-------------------------------------------------------------------------+
# | [6] Rotate current release and activate the new one                     |
# +-------------------------------------------------------------------------+
echo "📦 Archiving current release: ${PROJECT_DIR} → ${BACKUP_DIR}"
mv -v "${PROJECT_DIR}" "${BACKUP_DIR}"

echo "🚀 Activating new release: ${TMP_CLONE_DIR} → ${PROJECT_DIR}"
mv -v "${TMP_CLONE_DIR}" "${PROJECT_DIR}"
TMP_CLONE_DIR=""
echo

# +-------------------------------------------------------------------------+
# | [7] Final validation on the live path                                   |
# +-------------------------------------------------------------------------+
echo "🔍 Re-checking Perl syntax on the live path ..."
if ! (
    cd "${PROJECT_DIR}"
    perl -c mediabot.pl
); then
    echo "⚠️  Validation failed after activation. Attempting rollback ..."

    if [ -d "${PROJECT_DIR}" ] && [ -d "${BACKUP_DIR}" ]; then
        FAILED_DIR="${PARENT_DIR}/mediabot_v3.failed.$$"
        mv -v "${PROJECT_DIR}" "${FAILED_DIR}" &&         mv -v "${BACKUP_DIR}"  "${PROJECT_DIR}" &&         ROLLED_BACK=1 || true
        rm -rf "${FAILED_DIR}" 2>/dev/null || true
    fi

    if [ "$ROLLED_BACK" -eq 1 ]; then
        fail "rollback completed successfully; previous release restored"
    else
        fail "rollback failed; manual intervention is required"
    fi
fi
echo

echo "✅ Deployment complete."
echo "Current live release: ${PROJECT_DIR}"
echo "Previous release archive: ${BACKUP_DIR}"
echo
echo "Start the bot in foreground with:"
echo "  cd ${PROJECT_DIR} && ./start"
echo "Or in background with:"
echo "  cd ${PROJECT_DIR} && ./daemon"

