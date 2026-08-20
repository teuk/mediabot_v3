#!/usr/bin/env bash
set -euo pipefail

# Resolve script, project, and parent directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(readlink -f "${SCRIPT_DIR}/..")"
PARENT_DIR="$(readlink -f "${PROJECT_DIR}/..")"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
TARGET_REAL="$PROJECT_DIR"

CURRENT_HOST="$(hostname -f 2>/dev/null || hostname)"
CURRENT_HOST_NORM="${CURRENT_HOST,,}"
CURRENT_HOST_NORM="${CURRENT_HOST_NORM%.}"
CURRENT_USER="$(id -un)"

# +-------------------------------------------------------------------------+
# | [0] Safety check: refuse ONLY the exact teuk.org production instance   |
# +-------------------------------------------------------------------------+
# mb634: hostname equality is exact (case-insensitive, optional final DNS dot).
# A host merely containing "teuk.org" — e.g. mediabot.teuk.org — is NOT
# teuk.org and must not be refused for the normal /home/mediabot path.
# The guard is about the path+host pair, not the Unix account used to launch it.
if [ "$CURRENT_HOST_NORM" = "teuk.org" ] && [ "$TARGET_REAL" = "/home/mediabot/mediabot_v3" ]; then
    echo "🚫 Refusing to update the production instance on teuk.org."
    echo "   The IRC 'update' command refuses this exact path+host pair too: update it manually."
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
# | [2] Clone the latest version into a temporary directory                 |
# +-------------------------------------------------------------------------+
TMP_CLONE_DIR="$(mktemp -d "${PARENT_DIR}/mediabot_v3.new.XXXXXX")"
echo "🌐 Cloning the latest version from GitHub into ${TMP_CLONE_DIR} ..."

git clone https://github.com/teuk/mediabot_v3 "${TMP_CLONE_DIR}"
[ -f "${TMP_CLONE_DIR}/mediabot.pl" ] || fail "clone completed but mediabot.pl is missing in ${TMP_CLONE_DIR}"
echo

# +-------------------------------------------------------------------------+
# | [3] Validate the staged release before switching                        |
# +-------------------------------------------------------------------------+
echo "🔍 Checking Perl syntax in the staged release ..."
(
    cd "${TMP_CLONE_DIR}"
    perl -c mediabot.pl
)
echo "✅ Staged release passed syntax validation."
echo

# A3 (mb469): startup integrity check on the STAGED tree, before switching.
# perl -c only proves the entry point parses; it does NOT catch a mediabot.pl
# calling a method absent from the modules, a missing dispatch handler, or a
# stale orphan .pm from a previous version (the 04/07 Undernet crash class).
# We generate a manifest from the freshly cloned candidate (its own tree is the
# reference) and verify the staged tree against it. Refuse to switch on failure.
if [ -f "${TMP_CLONE_DIR}/tools/startup_integrity_check.pl" ]; then
    echo "🧪 Running startup integrity check on the staged release ..."
    STAGED_MANIFEST="$(mktemp "${TMP_CLONE_DIR}/.manifest.XXXXXX")"
    (
        cd "${TMP_CLONE_DIR}"
        perl tools/startup_integrity_check.pl --gen-manifest "${STAGED_MANIFEST}" --quiet
        perl tools/startup_integrity_check.pl --manifest "${STAGED_MANIFEST}"
    ) || fail "startup integrity check failed on the staged release — NOT switching. The clone is inconsistent; investigate before retrying."
    rm -f "${STAGED_MANIFEST}" 2>/dev/null || true
    echo "✅ Staged release passed the integrity check."
    echo
else
    echo "⚠️  tools/startup_integrity_check.pl absent from the clone — skipping deep integrity check."
    echo "    (Older candidate? The syntax check above still applies.)"
    echo
fi

# +-------------------------------------------------------------------------+
# | [4] Find the running instance to stop                                   |
# +-------------------------------------------------------------------------+
# mb635: clone + staged validation happen BEFORE this stop. A failed GitHub
# fetch or bad candidate must never create downtime. With systemd RestartSec,
# the remaining critical section is now only: stop -> restore private state ->
# two local mv operations -> final syntax check, so restart sees the new tree.
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

# mb645: when the matching bot is owned by a systemd service, verify the
# lifecycle contract BEFORE sending SIGTERM.  The updater is a descendant of
# that service and remains in its cgroup despite setsid()/double-fork.  We need:
#   - ExitType=cgroup : keep the unit alive until this updater finishes;
#   - Restart=always  : restart even when an older bot handles SIGTERM as exit 0.
#
# Without both, a successful deployment could leave the bot down or systemd
# could restart it in the middle of the directory swap.  Fail closed.
SYSTEMD_UNIT=""
SYSTEMD_RESTART=""
SYSTEMD_EXIT_TYPE=""

if [ -n "$BOT_PID" ] && [ -r "/proc/${BOT_PID}/cgroup" ]; then
    SYSTEMD_UNIT="$(
        awk -F: '{ print $3 }' "/proc/${BOT_PID}/cgroup" 2>/dev/null \
        | sed -n 's#^.*/\([^/]*\.service\)$#\1#p' \
        | head -1
    )"
fi

if [ -n "$SYSTEMD_UNIT" ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        fail "PID ${BOT_PID} belongs to ${SYSTEMD_UNIT}, but systemctl is unavailable"
    fi

    SYSTEMD_RESTART="$(systemctl show "$SYSTEMD_UNIT" --property=Restart --value 2>/dev/null || true)"
    SYSTEMD_EXIT_TYPE="$(systemctl show "$SYSTEMD_UNIT" --property=ExitType --value 2>/dev/null || true)"

    echo "🧭 systemd instance: ${SYSTEMD_UNIT} (Restart=${SYSTEMD_RESTART:-unknown}, ExitType=${SYSTEMD_EXIT_TYPE:-unknown})"

    if [ "$SYSTEMD_RESTART" != "always" ] || [ "$SYSTEMD_EXIT_TYPE" != "cgroup" ]; then
        fail "systemd unit ${SYSTEMD_UNIT} is not update-safe: expected Restart=always and ExitType=cgroup. Install the current tools/systemd/mediabot@.service.example, run systemctl daemon-reload, restart the instance, then retry."
    fi
fi

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
# | [5] Restore config and Hailo brain into the temporary clone             |
# +-------------------------------------------------------------------------+
echo "⚙️  Restoring config and Hailo brain into the staged release ..."

if [ -f "${PROJECT_DIR}/mediabot.conf" ]; then
    cp -pfv "${PROJECT_DIR}/mediabot.conf" "${TMP_CLONE_DIR}/"
else
    echo "⚠️  Warning: mediabot.conf was not found in ${PROJECT_DIR}."
fi

# mb646: transitional safety only. Achievements are DB-backed after migration,
# but an older instance may still have its last durable state in JSON. Preserve
# that file across the directory swap so the new release can import it once.
if [ -f "${PROJECT_DIR}/var/achievements.json" ]; then
    mkdir -p "${TMP_CLONE_DIR}/var"
    cp -pfv "${PROJECT_DIR}/var/achievements.json"         "${TMP_CLONE_DIR}/var/achievements.json"
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

# +-------------------------------------------------------------------------+
# | [8] Persist the IRC completion notice for the NEW process                |
# +-------------------------------------------------------------------------+
# mb673: the old process cannot report success because it is intentionally
# stopped before the directory swap. The detached updater is the only actor
# that knows the deployment really completed. Write the marker only AFTER the
# live-path validation above; rollback/failure therefore never emits success.
if [ -n "${MEDIABOT_UPDATE_NOTIFY_KIND:-}" ] && [ -n "${MEDIABOT_UPDATE_NOTIFY_TARGET:-}" ]; then
    LIVE_VERSION="$(head -n 1 "${PROJECT_DIR}/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$LIVE_VERSION" ]; then
        NOTICE_FILE="${PROJECT_DIR}/var/update.completed.json"
        NOTICE_TMP="${NOTICE_FILE}.tmp.$$"

        if mkdir -p "${PROJECT_DIR}/var" \
           && MEDIABOT_UPDATE_NOTIFY_VERSION="$LIVE_VERSION" \
              MEDIABOT_UPDATE_NOTIFY_FILE="$NOTICE_TMP" \
              perl -MJSON::PP -e '
                    use strict;
                    use warnings;
                    my $kind   = $ENV{MEDIABOT_UPDATE_NOTIFY_KIND}    // q{};
                    my $target = $ENV{MEDIABOT_UPDATE_NOTIFY_TARGET}  // q{};
                    my $ver    = $ENV{MEDIABOT_UPDATE_NOTIFY_VERSION} // q{};
                    my $file   = $ENV{MEDIABOT_UPDATE_NOTIFY_FILE}    // q{};
                    die "invalid completion notice\n"
                        unless ($kind eq "channel" || $kind eq "notice")
                            && length($target) && $target !~ /[\x00\r\n]/
                            && length($ver) && $ver !~ /[\x00\r\n]/
                            && length($file);
                    umask 0077;
                    open my $fh, ">:raw", $file or die "$file: $!\n";
                    print {$fh} JSON::PP->new->utf8->canonical->encode({
                        schema       => 1,
                        kind         => $kind,
                        target       => $target,
                        version      => $ver,
                        completed_at => 0 + time(),
                    });
                    print {$fh} "\n";
                    close $fh or die "$file: $!\n";
                ' \
           && mv -f "$NOTICE_TMP" "$NOTICE_FILE"
        then
            echo "📣 IRC completion notice armed for ${MEDIABOT_UPDATE_NOTIFY_KIND}:${MEDIABOT_UPDATE_NOTIFY_TARGET} (version ${LIVE_VERSION})."
        else
            rm -f "$NOTICE_TMP" 2>/dev/null || true
            echo "⚠️  Warning: update succeeded, but the IRC completion notice could not be written."
        fi
    else
        echo "⚠️  Warning: update succeeded, but VERSION is unreadable; no IRC completion notice was armed."
    fi
fi

echo "✅ Deployment complete."
echo "Current live release: ${PROJECT_DIR}"
echo "Previous release archive: ${BACKUP_DIR}"
echo
echo "Start the bot in foreground with:"
echo "  cd ${PROJECT_DIR} && perl mediabot.pl --conf=mediabot.conf"
echo "Or with systemd (recommended for production):"
echo "  sudo systemctl restart mediabot@<instance>   # see tools/systemd/README.md"

