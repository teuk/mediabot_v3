#!/bin/bash
set -u

# mb381-B1: CPAN runs under sudo from a configure process using umask 077.
# Force conventional public read/traverse permissions for installed Perl
# modules while keeping the installer logs private.
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_HELPER="$SCRIPT_DIR/install_perl_module.sh"
SCRIPT_LOGFILE="$SCRIPT_DIR/cpan_install.log"
CPAN_LOGFILE="$SCRIPT_DIR/cpan_install_details.log"
VERIFY_ONLY=0

case "${1:-}" in
    "") ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)
        cat <<'USAGE'
Usage:
  ./cpan_install.sh               Install and verify required Perl modules (root).
  ./cpan_install.sh --verify-only Verify required modules as the current user.
USAGE
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
esac

cd "$SCRIPT_DIR" || {
    echo "Unable to enter installer directory: $SCRIPT_DIR" >&2
    exit 1
}

PERL_MODULES=(
  "Getopt::Long"
  "File::Basename"
  "IO::Async::Loop"
  "IO::Async::Timer::Periodic"
  "Net::Async::IRC"
  "Data::Dumper"
  "Config::Simple"
  "Date::Parse"
  "DBI"
  "DBD::MariaDB"
  "Switch"
  "Memory::Usage"
  "String::IRC"
  "DateTime"
  "DateTime::TimeZone"
  "HTML::Tree"
  "HTML::Entities"
  "URL::Encode"
  "Time::HiRes"
  "Moose"
  "Hailo"
  "JSON::MaybeXS"
  "List::Util"
  "File::Temp"
  "HTTP::Tiny"
  "IO::Socket::SSL"
  "Try::Tiny"
  "Crypt::Bcrypt"
  "URI::Escape"
  "Date::Format"
  "JSON"
  "File::Slurp"
)

verify_modules_for_current_user() {
    local perl_module
    local failed=0

    printf '[%s] Verify Perl modules as user %s\n' \
        "$(date +'%d/%m/%Y %H:%M:%S')" "$(id -un 2>/dev/null || printf unknown)"

    for perl_module in strict warnings "${PERL_MODULES[@]}"; do
        printf '[%s] Checking %s ' "$(date +'%d/%m/%Y %H:%M:%S')" "$perl_module"
        if perl -M"$perl_module" -e 'exit 0;' >/dev/null 2>&1; then
            printf 'OK\n'
        else
            printf 'FAILED\n' >&2
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo "One or more Perl modules are unavailable or unreadable for the current user." >&2
        return 1
    fi

    printf '[%s] Perl modules are readable by the current user\n' "$(date +'%d/%m/%Y %H:%M:%S')"
    return 0
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify_modules_for_current_user
    exit $?
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root user"
    exit 1
fi

if [ ! -x "$INSTALL_HELPER" ]; then
    echo "Missing executable Perl installer helper: $INSTALL_HELPER" >&2
    exit 1
fi

if ! command -v cpan >/dev/null 2>&1; then
    echo "The CPAN client is required but was not found in PATH." >&2
    exit 1
fi

# MB393: the runtime DSN is DBI:MariaDB, so a fresh CPAN-only installation
# must be able to build DBD::MariaDB instead of silently relying on a Debian
# Perl package.  The module needs the MariaDB/MySQL client development tool.
if ! perl -MDBD::MariaDB -e 'exit 0;' >/dev/null 2>&1; then
    if ! command -v mariadb_config >/dev/null 2>&1 \
        && ! command -v mysql_config >/dev/null 2>&1; then
        cat >&2 <<'EOF'
DBD::MariaDB is required by the Mediabot runtime but is not installed.
CPAN needs MariaDB/MySQL client development headers to build it.
On Debian, install the non-Perl build dependency libmariadb-dev, then rerun configure.
Do not install libdbd-mariadb-perl as a replacement for the CPAN phase.
EOF
        exit 1
    fi
fi

# Keep build logs private even though module installation itself uses umask 022.
touch "$SCRIPT_LOGFILE" "$CPAN_LOGFILE" || {
    echo "Unable to create CPAN installer logs under $SCRIPT_DIR" >&2
    exit 1
}
chmod 0600 "$SCRIPT_LOGFILE" "$CPAN_LOGFILE" || {
    echo "Unable to protect CPAN installer logs under $SCRIPT_DIR" >&2
    exit 1
}
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "$SCRIPT_LOGFILE" "$CPAN_LOGFILE" || {
        echo "Unable to return CPAN installer logs to the invoking user" >&2
        exit 1
    }
fi

# +-------------------------------------------------------------------------+
# | Functions                                                               |
# +-------------------------------------------------------------------------+
function messageln {
    if [ ! -z "${1:-}" ]; then
        echo "[$(date +'%d/%m/%Y %H:%M:%S')] $*" | tee -a "$SCRIPT_LOGFILE"
    fi
}

function message {
    if [ ! -z "${1:-}" ]; then
        echo -n "[$(date +'%d/%m/%Y %H:%M:%S')] $* " | tee -a "$SCRIPT_LOGFILE"
    fi
}

function ok_failed {
    if [ ! -z "${1:-}" ] && [ "$1" -eq 0 ]; then
        echo "OK" | tee -a "$SCRIPT_LOGFILE"
    else
        RETVALUE="${1:-1}"
        echo -e " Failed. "
        if [ ! -z "${2:-}" ]; then
            shift
            echo "$*"
        fi
        echo -e "Summary log: $SCRIPT_LOGFILE" | tee -a "$SCRIPT_LOGFILE"
        echo -e "Detailed CPAN log: $CPAN_LOGFILE" | tee -a "$SCRIPT_LOGFILE"
        exit "$RETVALUE"
    fi
}

function wait_for_cmd {
    "$@" >>"${CPAN_LOGFILE}" 2>&1 &
    WAIT_PID=$!

    while kill -0 "$WAIT_PID" 2>/dev/null; do
        echo -n "."
        sleep 5
    done

    echo -n " "
    wait "$WAIT_PID"
}

function ensure_module {
    local perl_module="$1"

    message "Checking $perl_module "
    perl -M"$perl_module" -e "exit 0;" &>/dev/null
    if [ $? -ne 0 ]; then
        echo -n "Not found. Installing via cpan "
        wait_for_cmd "$INSTALL_HELPER" "$perl_module"
        local rc=$?

        if [ "$rc" -ne 0 ]; then
            if [ "$perl_module" = "Hailo" ]; then
                echo "Failed. Will try manual Hailo installation later." | tee -a "$SCRIPT_LOGFILE"
            else
                ok_failed "$rc"
            fi
        else
            echo "OK"
        fi
    else
        echo "OK"
    fi
}

# mb380-B1: anchor all helper/log/fallback paths to this script directory.
# +-------------------------------------------------------------------------+
# | CPAN MODULES INSTALL                                                    |
# +-------------------------------------------------------------------------+
message "Autoconfigure cpan"
bash -c "(echo y; echo o conf prerequisites_policy follow; echo o conf commit) | cpan" >>"$CPAN_LOGFILE" 2>&1
ok_failed $?

messageln "Install perl module Module::Build"
ensure_module "Module::Build"

messageln "Install perl modules"
for perl_module in "${PERL_MODULES[@]}"; do
    ensure_module "$perl_module"
done

if ! perl -MHailo -e "exit 0;" &>/dev/null; then
    messageln "Installing Hailo manually as fallback after CPAN attempt"
    wget https://cpan.metacpan.org/authors/id/A/AV/AVAR/Hailo-0.75.tar.gz
    tar xzf Hailo-0.75.tar.gz
    chown -R mediabot: Hailo-0.75
    cd Hailo-0.75 || exit 1
    perl Makefile.PL >>"$CPAN_LOGFILE" 2>&1
    ok_failed $?
    make >>"$CPAN_LOGFILE" 2>&1
    ok_failed $?
    make install >>"$CPAN_LOGFILE" 2>&1
    ok_failed $?
    cd "$SCRIPT_DIR" || exit 1
else
    messageln "Hailo already available, skipping manual fallback installation"
fi

# +-------------------------------------------------------------------------+
# | CPAN VERIFY MODULES                                                     |
# +-------------------------------------------------------------------------+
messageln "Verify perl modules installation as root"

for perl_module in "${PERL_MODULES[@]}"; do
    message "Checking $perl_module"
    perl -M"$perl_module" -e "exit 0;"
    ok_failed $?
done

messageln "Perl modules successfully installed"
