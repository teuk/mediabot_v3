#!/usr/bin/env bash
#
# Mediabot v3 systemd installer
#
# Installs the published multi-instance template and one instance environment
# file without starting, restarting, or enabling the service implicitly.
# Existing divergent files are preserved unless replacement is explicit.
#

set -euo pipefail
umask 022

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_SOURCE="${APP_DIR}/tools/systemd/mediabot@.service.example"
TARGET_ROOT="/"
INSTANCE=""
BOT_DIR=""
BOT_BIN=""
BOT_CONF=""
REPLACE_TEMPLATE=0
REPLACE_INSTANCE=0
TEMPLATE_ONLY=0

usage() {
    cat >&2 <<EOF_USAGE
Usage:
  $0 --instance NAME --bot-dir DIR [options]
  $0 --template-only [--replace-template] [--root DIR]

Required for an instance install:
  --instance NAME          systemd instance name (for mediabot@NAME.service)
  --bot-dir DIR            absolute Mediabot project directory

Optional:
  --bot-bin FILE           bot executable path (default: DIR/mediabot.pl)
  --bot-conf FILE          config path (default: DIR/mediabot.conf)
  --root DIR               alternate filesystem root for image/CI installation
                           (default: /)
  --replace-template       replace an existing divergent mediabot@.service
  --replace-instance       replace an existing divergent /etc/default file
  --template-only          install/check only mediabot@.service; do not touch an instance file
  -h, --help               show this help

Safety:
  - existing matching files are left untouched (idempotent)
  - divergent files are never overwritten without the matching --replace flag
  - symlink targets are refused
  - no service is started, restarted, stopped, or enabled
  - systemctl daemon-reload runs only for a real-root installation when files changed
EOF_USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --instance)
            [ "$#" -ge 2 ] || fail "--instance requires a value"
            INSTANCE="$2"
            shift 2
            ;;
        --bot-dir)
            [ "$#" -ge 2 ] || fail "--bot-dir requires a path"
            BOT_DIR="$2"
            shift 2
            ;;
        --bot-bin)
            [ "$#" -ge 2 ] || fail "--bot-bin requires a path"
            BOT_BIN="$2"
            shift 2
            ;;
        --bot-conf)
            [ "$#" -ge 2 ] || fail "--bot-conf requires a path"
            BOT_CONF="$2"
            shift 2
            ;;
        --root)
            [ "$#" -ge 2 ] || fail "--root requires a directory"
            TARGET_ROOT="$2"
            shift 2
            ;;
        --replace-template)
            REPLACE_TEMPLATE=1
            shift
            ;;
        --replace-instance)
            REPLACE_INSTANCE=1
            shift
            ;;
        --template-only)
            TEMPLATE_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    [ -n "$INSTANCE" ] || { usage; fail "--instance is required"; }
    [ -n "$BOT_DIR" ] || { usage; fail "--bot-dir is required"; }
    [[ "$INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || fail "invalid instance name '$INSTANCE'"
else
    [ -z "$INSTANCE" ] || fail "--template-only cannot be combined with --instance"
    [ -z "$BOT_DIR" ] || fail "--template-only cannot be combined with --bot-dir"
    [ -z "$BOT_BIN" ] || fail "--template-only cannot be combined with --bot-bin"
    [ -z "$BOT_CONF" ] || fail "--template-only cannot be combined with --bot-conf"
    [ "$REPLACE_INSTANCE" -eq 0 ] || fail "--template-only cannot be combined with --replace-instance"
fi

safe_absolute_path() {
    local value="$1"
    [[ "$value" == /* ]] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    [[ "$value" =~ ^/[A-Za-z0-9_./+:-]+$ ]] || return 1
    [[ "$value" != *"/../"* && "$value" != */.. && "$value" != *"/./"* ]]
}

if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    safe_absolute_path "$BOT_DIR" || fail "unsafe or non-absolute --bot-dir: $BOT_DIR"
    BOT_BIN="${BOT_BIN:-${BOT_DIR%/}/mediabot.pl}"
    BOT_CONF="${BOT_CONF:-${BOT_DIR%/}/mediabot.conf}"
    safe_absolute_path "$BOT_BIN" || fail "unsafe or non-absolute --bot-bin: $BOT_BIN"
    safe_absolute_path "$BOT_CONF" || fail "unsafe or non-absolute --bot-conf: $BOT_CONF"
fi

[ -f "$TEMPLATE_SOURCE" ] || fail "published systemd template not found: $TEMPLATE_SOURCE"

# Refuse accidentally installing an obsolete template even if the helper and
# repository somehow drift apart.
for required in \
    'ExitType=cgroup' \
    'Environment=MEDIABOT_SYSTEMD_UPDATE_SAFE=1' \
    'Restart=always' \
    'SuccessExitStatus=75' \
    'RestartPreventExitStatus=75'
do
    grep -Fxq "$required" "$TEMPLATE_SOURCE" \
        || fail "published template is missing required lifecycle contract: $required"
done

if [ "$TARGET_ROOT" != "/" ]; then
    [ -d "$TARGET_ROOT" ] || fail "--root does not exist: $TARGET_ROOT"
    TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd -P)"
fi

rooted_path() {
    local p="$1"
    if [ "$TARGET_ROOT" = "/" ]; then
        printf '%s' "$p"
    else
        printf '%s%s' "$TARGET_ROOT" "$p"
    fi
}

if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    BOT_DIR_CHECK="$(rooted_path "$BOT_DIR")"
    BOT_BIN_CHECK="$(rooted_path "$BOT_BIN")"
    BOT_CONF_CHECK="$(rooted_path "$BOT_CONF")"

    [ -d "$BOT_DIR_CHECK" ] || fail "bot directory not found: $BOT_DIR"
    [ -f "$BOT_BIN_CHECK" ] || fail "bot executable not found: $BOT_BIN"
    [ -f "$BOT_CONF_CHECK" ] || fail "bot config not found: $BOT_CONF"
fi

if [ "$TARGET_ROOT" = "/" ]; then
    [ "$(id -u)" -eq 0 ] || fail "real systemd installation requires root"
    command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"
    SYSTEMD_VERSION="$(systemctl --version | awk 'NR == 1 { print $2 }')"
    [[ "$SYSTEMD_VERSION" =~ ^[0-9]+$ ]] || fail "cannot determine systemd version"
    [ "$SYSTEMD_VERSION" -ge 250 ] \
        || fail "current Mediabot template requires systemd >= 250 (found $SYSTEMD_VERSION)"
fi

SYSTEMD_DIR="$(rooted_path /etc/systemd/system)"
DEFAULT_DIR="$(rooted_path /etc/default)"
TEMPLATE_TARGET="${SYSTEMD_DIR}/mediabot@.service"
install -d -m 0755 "$SYSTEMD_DIR" "$DEFAULT_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    INSTANCE_TARGET="${DEFAULT_DIR}/mediabot-${INSTANCE}"
    INSTANCE_CANDIDATE="${TMP_DIR}/mediabot-${INSTANCE}"
    cat >"$INSTANCE_CANDIDATE" <<EOF_INSTANCE
# Managed by Mediabot install/systemd_install.sh
# Instance: mediabot@${INSTANCE}.service
BOT_DIR=${BOT_DIR}
BOT_BIN=${BOT_BIN}
BOT_CONF=${BOT_CONF}
EOF_INSTANCE
    chmod 0644 "$INSTANCE_CANDIDATE"
fi

CHANGED=0

install_file_safely() {
    local source="$1"
    local target="$2"
    local replace="$3"
    local label="$4"

    if [ -L "$target" ]; then
        fail "$label target is a symlink; refusing: $target"
    fi
    if [ -e "$target" ] && [ ! -f "$target" ]; then
        fail "$label target is not a regular file; refusing: $target"
    fi

    if [ -f "$target" ]; then
        if cmp -s "$source" "$target"; then
            chmod 0644 "$target"
            echo "OK: $label already matches: $target"
            return 0
        fi
        if [ "$replace" -ne 1 ]; then
            fail "$label already exists and differs: $target (use the explicit replace option after review)"
        fi
        cp -p "$target" "${target}.before-mediabot-install.$(date +%Y%m%d_%H%M%S).$$.bak"
    fi

    install -m 0644 "$source" "$target"
    CHANGED=1
    echo "INSTALLED: $label -> $target"
}

install_file_safely "$TEMPLATE_SOURCE" "$TEMPLATE_TARGET" "$REPLACE_TEMPLATE" "systemd template"
if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    install_file_safely "$INSTANCE_CANDIDATE" "$INSTANCE_TARGET" "$REPLACE_INSTANCE" "instance environment"
fi

if [ "$TARGET_ROOT" = "/" ] && [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload
    echo "OK: systemctl daemon-reload"
fi

echo
echo "Mediabot systemd installation is ready."
echo "Template : /etc/systemd/system/mediabot@.service"
if [ "$TEMPLATE_ONLY" -eq 0 ]; then
    echo "Instance : /etc/default/mediabot-${INSTANCE}"
    echo "Unit     : mediabot@${INSTANCE}.service"
    echo "Started  : no"
    echo "Enabled  : no"
    echo
    echo "Review, then enable/start explicitly when desired:"
    echo "  systemctl enable mediabot@${INSTANCE}.service"
    echo "  systemctl start mediabot@${INSTANCE}.service"
else
    echo "Instance : unchanged (--template-only)"
    echo "Services : not restarted or enabled"
fi
