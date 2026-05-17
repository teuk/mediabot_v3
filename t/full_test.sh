#!/usr/bin/env bash
set -uo pipefail

APP_DIR="/home/mediabot/mediabot_v3"
DEFAULT_LOG_DIR="/tmp/mediabot_tests"
LOG_DIR="$DEFAULT_LOG_DIR"
LIVE_SERVER="localhost"
LIVE_CHANNEL="#testchan"

usage() {
  cat <<USAGE
Usage:
  $0 [options]

Options:
  -d <dir>      Directory where test logs will be written
                Default: ${DEFAULT_LOG_DIR}

  -s <server>   IRC server for live tests
                Default: ${LIVE_SERVER}

  -c <channel>  IRC channel for live tests
                Default: ${LIVE_CHANNEL}

  -h            Show this help

Examples:
  $0

  $0 -d /tmp/mediabot_tests

  $0 -d /tmp/mediabot_tests -s localhost -c '#testchan'
USAGE
}

while getopts ":d:s:c:h" opt; do
  case "$opt" in
    d)
      LOG_DIR="$OPTARG"
      ;;
    s)
      LIVE_SERVER="$OPTARG"
      ;;
    c)
      LIVE_CHANNEL="$OPTARG"
      ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "ERROR: option -$OPTARG requires an argument" >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "ERROR: unknown option -$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done

shift $((OPTIND - 1))

if [ "$#" -ne 0 ]; then
  echo "ERROR: unexpected argument(s): $*" >&2
  usage >&2
  exit 2
fi

cd "$APP_DIR" || {
  echo "ERROR: cannot cd to $APP_DIR" >&2
  exit 1
}

if [ -z "$LOG_DIR" ]; then
  echo "ERROR: empty log directory" >&2
  exit 2
fi

mkdir -p "$LOG_DIR" || {
  echo "ERROR: cannot create log directory: $LOG_DIR" >&2
  exit 3
}

if [ ! -d "$LOG_DIR" ]; then
  echo "ERROR: log path is not a directory: $LOG_DIR" >&2
  exit 3
fi

if [ ! -w "$LOG_DIR" ]; then
  echo "ERROR: log directory is not writable by $(whoami): $LOG_DIR" >&2
  exit 3
fi

TS="$(date +%Y%m%d_%H%M%S)"
STATIC_LOG="${LOG_DIR}/mediabot_test_commands_verbose_${TS}.log"
LIVE_LOG="${LOG_DIR}/mediabot_test_live_verbose_${TS}.log"

echo "===== Mediabot full test run ====="
echo "App dir      : $APP_DIR"
echo "Log dir      : $LOG_DIR"
echo "Live server  : $LIVE_SERVER"
echo "Live channel : $LIVE_CHANNEL"
echo "Timestamp    : $TS"
echo

echo "===== Full static test suite verbose ====="
perl t/test_commands.pl --verbose 2>&1 | tee "$STATIC_LOG"
STATIC_PIPESTATUS=("${PIPESTATUS[@]}")
STATIC_RC="${STATIC_PIPESTATUS[0]:-255}"
STATIC_TEE_RC="${STATIC_PIPESTATUS[1]:-255}"

echo
echo "===== Static test_commands.pl exit code: ${STATIC_RC} ====="
echo "===== Static tee exit code: ${STATIC_TEE_RC} ====="
echo "Static log: $STATIC_LOG"
echo

echo "===== Full live test suite verbose ====="
perl t/test_live.pl --server "$LIVE_SERVER" --channel "$LIVE_CHANNEL" --verbose 2>&1 | tee "$LIVE_LOG"
LIVE_PIPESTATUS=("${PIPESTATUS[@]}")
LIVE_RC="${LIVE_PIPESTATUS[0]:-255}"
LIVE_TEE_RC="${LIVE_PIPESTATUS[1]:-255}"

echo
echo "===== Live test_live.pl exit code: ${LIVE_RC} ====="
echo "===== Live tee exit code: ${LIVE_TEE_RC} ====="
echo "Live log: $LIVE_LOG"
echo

echo "===== Log file checks ====="

if [ -f "$STATIC_LOG" ]; then
  ls -lh "$STATIC_LOG"
else
  echo "ERROR: static log was not created: $STATIC_LOG" >&2
  STATIC_TEE_RC=255
fi

if [ -f "$LIVE_LOG" ]; then
  ls -lh "$LIVE_LOG"
else
  echo "ERROR: live log was not created: $LIVE_LOG" >&2
  LIVE_TEE_RC=255
fi

echo
echo "===== Final verdict ====="

if [ "$STATIC_RC" -eq 0 ]; then
  echo "OK: static tests passed"
else
  echo "FAIL: static tests failed with exit code $STATIC_RC"
fi

if [ "$LIVE_RC" -eq 0 ]; then
  echo "OK: live tests passed"
else
  echo "FAIL: live tests failed with exit code $LIVE_RC"
fi

if [ "$STATIC_TEE_RC" -eq 0 ] && [ "$LIVE_TEE_RC" -eq 0 ]; then
  echo "OK: logs written successfully"
else
  echo "FAIL: at least one tee/log write failed"
fi

echo
echo "Logs:"
echo "  $STATIC_LOG"
echo "  $LIVE_LOG"

if [ "$STATIC_RC" -ne 0 ] || [ "$LIVE_RC" -ne 0 ] || [ "$STATIC_TEE_RC" -ne 0 ] || [ "$LIVE_TEE_RC" -ne 0 ]; then
  exit 1
fi

exit 0
