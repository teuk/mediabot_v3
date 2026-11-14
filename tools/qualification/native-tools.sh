#!/usr/bin/env bash
# Native executables used by the suite, independent of Perl module availability.
set -Eeuo pipefail
missing=0
for tool in node tclsh pgrep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing suite prerequisite: %s\n' "$tool" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 3
node --version
printf 'puts [info patchlevel]\n' | tclsh
pgrep --version
