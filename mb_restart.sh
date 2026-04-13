#!/bin/bash
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PIDFILE="$SCRIPT_DIR/mediabot.pid"

has_daemon=0
for arg in "$@"; do
    if [ "$arg" = "--daemon" ]; then
        has_daemon=1
        break
    fi
done

if [ "$has_daemon" -ne 1 ]; then
    echo "This script is for internal use and expects --daemon in arguments." >&2
    exit 1
fi

wait_for_old_bot() {
    if [ ! -f "$PIDFILE" ]; then
        return 0
    fi

    old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -z "${old_pid:-}" ]; then
        rm -f "$PIDFILE"
        return 0
    fi

    if kill -0 "$old_pid" 2>/dev/null; then
        echo "[mb_restart.sh] Waiting for old bot process $old_pid to exit..."
        i=0
        while kill -0 "$old_pid" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
            if [ "$i" -ge 30 ]; then
                echo "[mb_restart.sh] Timeout while waiting for PID $old_pid to exit." >&2
                exit 1
            fi
        done
    fi

    rm -f "$PIDFILE"
}

wait_for_old_bot

cd "$SCRIPT_DIR"
exec ./mediabot.pl "$@"