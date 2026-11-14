#!/usr/bin/env bash
# Run in a disposable Debian environment whose native prerequisites are installed.
set -Eeuo pipefail
umask 077
if [ "$#" -ne 1 ]; then
  echo 'Usage: fresh.sh NEW_EVIDENCE_DIRECTORY' >&2
  exit 64
fi
if [ "$(id -u)" -eq 0 ]; then
  echo 'Run qualification as an ordinary user after preparing native prerequisites.' >&2
  exit 3
fi
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mkdir -m 700 -- "$1"
output="$(cd -- "$1" && pwd -P)"
cd "$repo"
{
  printf 'SOURCE_COMMIT='
  git rev-parse HEAD
  printf 'UTC='
  date -u +%Y-%m-%dT%H:%M:%SZ
  id
  cat /etc/os-release
  uname -m
  perl -V
  cpanm --version
  dpkg-query -W -f='${Package}\t${Version}\n'
} >"$output/platform.txt" 2>&1
# pipefail preserves unavailable/test failure codes while retaining visible output.
python3 tools/qualification/run.py --provision --lane full --timeout 3600 \
  --output "$output/result" 2>&1 | tee "$output/qualification.log"
