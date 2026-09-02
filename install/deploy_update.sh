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

INSTANCE_CONF="${MEDIABOT_UPDATE_CONF:-mediabot.conf}"

usage() {
    cat <<'EOF'
Usage:
  install/deploy_update.sh [--conf=<file>]
  install/deploy_update.sh [--conf <file>]

Options:
  --conf <file>   Private instance config to preserve across the update.
                  Relative paths are resolved inside the current project.
                  Default: mediabot.conf
  -h, --help      Show this help and exit.

The updater always clones the current repository's origin, validates the
candidate before shutdown, preserves instance-local state, rotates the current
directory to <project>.<N>, and activates the new clone at the same path.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --conf=*)
            INSTANCE_CONF="${1#--conf=}"
            shift
            ;;
        --conf)
            [ "$#" -ge 2 ] || { echo "ERROR: --conf requires a file" >&2; exit 2; }
            INSTANCE_CONF="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

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

# mb680: durable updater state lives BESIDE the rotating release tree.
# Keeping it under PROJECT_DIR/var would archive the truth with the old release
# during the very operation we are trying to observe.
STATUS_FILE="${PARENT_DIR}/.${PROJECT_NAME}.update-status.json"
STATUS_STARTED_AT="$(date +%s)"
STATUS_OLD_VERSION=""
STATUS_TARGET_VERSION=""
STATUS_INSTALLED_VERSION=""
STATUS_PHASE="preflight"
STATUS_DETAIL=""
STATUS_STARTED=0
STATUS_FINALIZED=0

write_update_status() {
    local state="$1"
    local phase="$2"
    local detail="${3:-}"
    local finished_at="${4:-}"
    local tmp="${STATUS_FILE}.tmp.$$"

    if ! MEDIABOT_UPDATE_STATUS_FILE="$tmp" \
         MEDIABOT_UPDATE_STATUS_STATE="$state" \
         MEDIABOT_UPDATE_STATUS_PHASE="$phase" \
         MEDIABOT_UPDATE_STATUS_STARTED="$STATUS_STARTED_AT" \
         MEDIABOT_UPDATE_STATUS_FINISHED="$finished_at" \
         MEDIABOT_UPDATE_STATUS_PID="$$" \
         MEDIABOT_UPDATE_STATUS_OLD="$STATUS_OLD_VERSION" \
         MEDIABOT_UPDATE_STATUS_TARGET="$STATUS_TARGET_VERSION" \
         MEDIABOT_UPDATE_STATUS_INSTALLED="$STATUS_INSTALLED_VERSION" \
         MEDIABOT_UPDATE_STATUS_DETAIL="$detail" \
         perl -MJSON::PP -e '
            use strict;
            use warnings;
            my $file = $ENV{MEDIABOT_UPDATE_STATUS_FILE} // q{};
            die "missing update status path\n" unless length $file;

            my %data = (
                schema       => 1,
                state        => ($ENV{MEDIABOT_UPDATE_STATUS_STATE} // q{}),
                phase        => ($ENV{MEDIABOT_UPDATE_STATUS_PHASE} // q{}),
                started_at   => 0 + ($ENV{MEDIABOT_UPDATE_STATUS_STARTED} // 0),
                updater_pid  => 0 + ($ENV{MEDIABOT_UPDATE_STATUS_PID} // 0),
            );

            for my $pair (
                [ old_version       => "MEDIABOT_UPDATE_STATUS_OLD" ],
                [ target_version    => "MEDIABOT_UPDATE_STATUS_TARGET" ],
                [ installed_version => "MEDIABOT_UPDATE_STATUS_INSTALLED" ],
                [ detail            => "MEDIABOT_UPDATE_STATUS_DETAIL" ],
            ) {
                my ($key, $env) = @$pair;
                my $value = $ENV{$env} // q{};
                $data{$key} = $value if length $value;
            }

            my $finished = $ENV{MEDIABOT_UPDATE_STATUS_FINISHED} // q{};
            $data{finished_at} = 0 + $finished if $finished =~ /\A\d+\z/ && $finished > 0;

            umask 0077;
            open my $fh, ">:raw", $file or die "$file: $!\n";
            print {$fh} JSON::PP->new->utf8->canonical->encode(\%data), "\n";
            close $fh or die "$file: $!\n";
        '
    then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if ! mv -f "$tmp" "$STATUS_FILE"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

status_checkpoint() {
    STATUS_PHASE="$1"
    if ! write_update_status "running" "$STATUS_PHASE" ""; then
        echo "⚠️  Warning: could not refresh durable update status (${STATUS_PHASE})." >&2
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT

    if [ "$rc" -ne 0 ] && [ "$STATUS_STARTED" -eq 1 ] && [ "$STATUS_FINALIZED" -eq 0 ]; then
        local state="failed"
        [ "$ROLLED_BACK" -eq 1 ] && state="rolled_back"
        local detail="${STATUS_DETAIL:-updater exited with rc ${rc}}"
        write_update_status "$state" "$STATUS_PHASE" "$detail" "$(date +%s)" \
            || echo "⚠️  Warning: could not persist final update failure status." >&2
    fi

    if [ -n "${TMP_CLONE_DIR}" ] && [ -d "${TMP_CLONE_DIR}" ]; then
        rm -rf "${TMP_CLONE_DIR}"
    fi

    exit "$rc"
}
trap cleanup EXIT

fail() {
    STATUS_DETAIL="$*"
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
[[ "${PROJECT_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || fail "project directory name '${PROJECT_NAME}' is unsafe for release rotation"
[ -f "${PROJECT_DIR}/mediabot.pl" ] || fail "${PROJECT_DIR}/mediabot.pl not found"
[ -d "${PARENT_DIR}" ] || fail "parent directory ${PARENT_DIR} does not exist"
[ -d "${PROJECT_DIR}/.git" ] || fail "${PROJECT_DIR} is not a Git working tree"

ORIGIN_URL="$(git -C "${PROJECT_DIR}" remote get-url origin 2>/dev/null || true)"
[ -n "${ORIGIN_URL}" ] || fail "Git remote 'origin' is not configured"

if [[ "${INSTANCE_CONF}" = /* ]]; then
    INSTANCE_CONF_CANDIDATE="${INSTANCE_CONF}"
else
    INSTANCE_CONF_CANDIDATE="${PROJECT_DIR}/${INSTANCE_CONF}"
fi

INSTANCE_CONF_REAL="$(readlink -f "${INSTANCE_CONF_CANDIDATE}" 2>/dev/null || true)"
[ -n "${INSTANCE_CONF_REAL}" ] && [ -f "${INSTANCE_CONF_REAL}" ] \
    || fail "instance config not found: ${INSTANCE_CONF}"

INSTANCE_CONF_DIR="$(dirname "${INSTANCE_CONF_REAL}")"
[ "${INSTANCE_CONF_DIR}" = "${TARGET_REAL}" ] \
    || fail "instance config must live directly in ${PROJECT_DIR}: ${INSTANCE_CONF_REAL}"

INSTANCE_CONF_NAME="$(basename "${INSTANCE_CONF_REAL}")"
[[ "${INSTANCE_CONF_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || fail "instance config filename '${INSTANCE_CONF_NAME}' is unsafe"

echo "==> Instance config: ${INSTANCE_CONF_NAME}"
echo "==> Git origin: ${ORIGIN_URL}"
echo

STATUS_OLD_VERSION="$(head -n 1 "${PROJECT_DIR}/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
if ! write_update_status "running" "preflight" ""; then
    fail "cannot initialize durable update status at ${STATUS_FILE}"
fi
STATUS_STARTED=1

# +-------------------------------------------------------------------------+
# | [1] Determine the next version number                                   |
# +-------------------------------------------------------------------------+
LAST_VER="$(
    find "$PARENT_DIR" -maxdepth 1 -type d -name "${PROJECT_NAME}.*" -printf '%f\n' 2>/dev/null \
    | sed -n "s/^${PROJECT_NAME}\.\([0-9][0-9]*\)$/\1/p" \
    | sort -n \
    | tail -1 \
    || true
)"
NEXT_VER=$(( ${LAST_VER:-0} + 1 ))
BACKUP_DIR="${PARENT_DIR}/${PROJECT_NAME}.${NEXT_VER}"

echo "==> Next archive version: ${NEXT_VER}"
echo "==> Backup directory will be: ${BACKUP_DIR}"
echo

# +-------------------------------------------------------------------------+
# | [2] Clone the latest version into a temporary directory                 |
# +-------------------------------------------------------------------------+
TMP_CLONE_DIR="$(mktemp -d "${PARENT_DIR}/${PROJECT_NAME}.new.XXXXXX")"
echo "🌐 Cloning the latest version from origin into ${TMP_CLONE_DIR} ..."
status_checkpoint "clone"

git clone "${ORIGIN_URL}" "${TMP_CLONE_DIR}"
[ -f "${TMP_CLONE_DIR}/mediabot.pl" ] || fail "clone completed but mediabot.pl is missing in ${TMP_CLONE_DIR}"
STATUS_TARGET_VERSION="$(head -n 1 "${TMP_CLONE_DIR}/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
status_checkpoint "staged_validation"
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
status_checkpoint "pre_stop"
# mb635: clone + staged validation happen BEFORE this stop. A failed GitHub
# fetch or bad candidate must never create downtime. With systemd RestartSec,
# the remaining critical section is now only: stop -> restore private state ->
# two local mv operations -> final syntax check, so restart sees the new tree.
while IFS= read -r PID; do
    [ -z "$PID" ] && continue
    [ -r "/proc/${PID}/cmdline" ] || continue

    # Never parse a flattened shell command string here. A parent shell whose
    # `-c` payload merely CONTAINS "mediabot.pl --conf=..." is not the bot.
    # Read the kernel's real NUL-separated argv and require a genuine
    # mediabot.pl argv item plus the exact selected --conf argument.
    PROC_ARGV=()
    mapfile -d '' -t PROC_ARGV < "/proc/${PID}/cmdline" 2>/dev/null || continue
    [ "${#PROC_ARGV[@]}" -gt 0 ] || continue

    HAS_MEDIABOT_ARG=0
    CONF_ARG=""

    for arg in "${PROC_ARGV[@]}"; do
        case "$arg" in
            mediabot.pl|*/mediabot.pl)
                HAS_MEDIABOT_ARG=1
                ;;
            --conf=*)
                CONF_ARG="${arg#--conf=}"
                ;;
        esac
    done

    [ "$HAS_MEDIABOT_ARG" -eq 1 ] || continue
    [ -n "$CONF_ARG" ] || continue

    if [[ "$CONF_ARG" = /* ]]; then
        CONF_ABS="$CONF_ARG"
    else
        PROC_CWD="$(readlink -f "/proc/${PID}/cwd" 2>/dev/null || true)"
        [ -z "$PROC_CWD" ] && continue
        CONF_ABS="${PROC_CWD}/${CONF_ARG}"
    fi

    CONF_REAL="$(readlink -f "$CONF_ABS" 2>/dev/null || echo "$CONF_ABS")"

    if [ "$CONF_REAL" = "$INSTANCE_CONF_REAL" ]; then
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
    status_checkpoint "stopping"
    echo "🛑 Sending SIGTERM to PID ${BOT_PID} ..."
    kill -15 "$BOT_PID"

    WAIT=0
    while kill -0 "$BOT_PID" 2>/dev/null; do
        sleep 1
        WAIT=$((WAIT + 1))
        if [ "$WAIT" -ge 30 ]; then
            fail "bot PID ${BOT_PID} is still running after 30 seconds; refusing SIGKILL and leaving the live tree untouched"
        fi
    done

    echo "✅ Bot stopped."
else
    echo "ℹ️  No running mediabot instance found for ${PROJECT_DIR}."
fi
echo

# +-------------------------------------------------------------------------+
# | [5] Restore private instance state into the temporary clone             |
# +-------------------------------------------------------------------------+
status_checkpoint "preserve_state"
echo "⚙️  Restoring private instance state into the staged release ..."

cp -pfv "${INSTANCE_CONF_REAL}" "${TMP_CLONE_DIR}/${INSTANCE_CONF_NAME}"

# mb646: transitional safety only. Achievements are DB-backed after migration,
# but an older instance may still have its last durable state in JSON. Preserve
# that file across the directory swap so the new release can import it once.
if [ -f "${PROJECT_DIR}/var/achievements.json" ]; then
    mkdir -p "${TMP_CLONE_DIR}/var"
    cp -pfv "${PROJECT_DIR}/var/achievements.json" \
        "${TMP_CLONE_DIR}/var/achievements.json"
fi

# Hailo brain files are instance-local state. Preserve every root-level .brn
# from the current instance; never recover code from an archived release.
BRAIN_COUNT=0
while IFS= read -r -d '' BRAIN_FILE; do
    cp -pfv "${BRAIN_FILE}" "${TMP_CLONE_DIR}/"
    BRAIN_COUNT=$((BRAIN_COUNT + 1))
done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name '*.brn' -print0 2>/dev/null)

if [ "$BRAIN_COUNT" -eq 0 ]; then
    echo "⚠️  Warning: no root-level .brn brain file was found in the current instance."
fi

# MB720: per-channel Hailo brains live below var/hailo. Preserve the directory
# as opaque private state; never follow a symlink supplied in its place.
if [ -L "${PROJECT_DIR}/var/hailo" ]; then
    fail "refusing symbolic-link Hailo brain directory: ${PROJECT_DIR}/var/hailo"
fi
if [ -d "${PROJECT_DIR}/var/hailo" ]; then
    mkdir -p "${TMP_CLONE_DIR}/var"
    cp -a "${PROJECT_DIR}/var/hailo" "${TMP_CLONE_DIR}/var/"
fi

# Local media is runtime/private state and must never disappear during a code
# rotation. It is intentionally ignored by Git.
if [ -d "${PROJECT_DIR}/mp3" ]; then
    cp -a "${PROJECT_DIR}/mp3" "${TMP_CLONE_DIR}/"
fi
echo

# +-------------------------------------------------------------------------+
# | [6] Rotate current release and activate the new one                     |
# +-------------------------------------------------------------------------+
status_checkpoint "activating"
echo "📦 Archiving current release: ${PROJECT_DIR} → ${BACKUP_DIR}"
mv -v "${PROJECT_DIR}" "${BACKUP_DIR}"

echo "🚀 Activating new release: ${TMP_CLONE_DIR} → ${PROJECT_DIR}"
mv -v "${TMP_CLONE_DIR}" "${PROJECT_DIR}"
TMP_CLONE_DIR=""
echo

# +-------------------------------------------------------------------------+
# | [7] Final validation on the live path                                   |
# +-------------------------------------------------------------------------+
status_checkpoint "live_validation"
echo "🔍 Re-checking Perl syntax on the live path ..."
if ! (
    cd "${PROJECT_DIR}"
    perl -c mediabot.pl
); then
    echo "⚠️  Validation failed after activation. Attempting rollback ..."

    if [ -d "${PROJECT_DIR}" ] && [ -d "${BACKUP_DIR}" ]; then
        FAILED_DIR="${PARENT_DIR}/${PROJECT_NAME}.failed.$$"
        mv -v "${PROJECT_DIR}" "${FAILED_DIR}" &&         mv -v "${BACKUP_DIR}"  "${PROJECT_DIR}" &&         ROLLED_BACK=1 || true
        if [ "$ROLLED_BACK" -eq 1 ]; then
            STATUS_INSTALLED_VERSION="$STATUS_OLD_VERSION"
        fi
        rm -rf "${FAILED_DIR}" 2>/dev/null || true
    fi

    if [ "$ROLLED_BACK" -eq 1 ]; then
        fail "rollback completed successfully; previous release restored"
    else
        fail "rollback failed; manual intervention is required"
    fi
fi
STATUS_INSTALLED_VERSION="$(head -n 1 "${PROJECT_DIR}/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
status_checkpoint "completion_notice"
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

STATUS_PHASE="completed"
if write_update_status "success" "$STATUS_PHASE" "" "$(date +%s)"; then
    STATUS_FINALIZED=1
else
    echo "⚠️  Warning: deployment succeeded, but durable update status could not be finalized." >&2
fi

echo "✅ Deployment complete."
echo "Current live release: ${PROJECT_DIR}"
echo "Previous release archive: ${BACKUP_DIR}"
echo
echo "Start the bot in foreground with:"
echo "  cd ${PROJECT_DIR} && perl mediabot.pl --conf=${INSTANCE_CONF_NAME}"
echo "Or with systemd (recommended for production):"
echo "  sudo systemctl restart mediabot@<instance>   # see tools/systemd/README.md"
