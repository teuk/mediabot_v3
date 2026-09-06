#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION=""
REF=""

usage() {
  cat <<'USAGE'
Usage:
  tools/rehearse_release_artifacts.sh --version X.Y --ref REF

Builds the same non-publishable release rehearsal twice, compares every
artifact byte for byte, verifies both checksum manifests and inspects the two
archive roots. The source repository is never modified.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { echo "ERROR: --version requires X.Y" >&2; exit 2; }
      VERSION="$2"
      shift
      ;;
    --ref)
      [ "$#" -ge 2 ] || { echo "ERROR: --ref requires a Git ref" >&2; exit 2; }
      REF="$2"
      shift
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
  shift
done

[ -n "$VERSION" ] || { echo "ERROR: --version X.Y is required" >&2; exit 2; }
[ -n "$REF" ] || { echo "ERROR: --ref REF is required" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a Git repository" >&2
  exit 1
}
cd "$REPO_ROOT"

BUILDER="$REPO_ROOT/tools/build_release_artifacts.sh"
[ -x "$BUILDER" ] || { echo "ERROR: release builder is not executable" >&2; exit 1; }

# Two Pensieve views must preserve the exact same memory, byte for byte.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mediabot-release-rehearsal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIRST="$WORK/first"
SECOND="$WORK/second"
mkdir -p "$FIRST" "$SECOND"

"$BUILDER" --version "$VERSION" --ref "$REF" --dest "$FIRST" --rehearsal
"$BUILDER" --version "$VERSION" --ref "$REF" --dest "$SECOND" --rehearsal

mapfile -t FIRST_NAMES < <(find "$FIRST" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
mapfile -t SECOND_NAMES < <(find "$SECOND" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
[ "${#FIRST_NAMES[@]}" -eq 6 ] || {
  echo "ERROR: expected six rehearsal artifacts, found ${#FIRST_NAMES[@]}" >&2
  exit 1
}
[ "${FIRST_NAMES[*]}" = "${SECOND_NAMES[*]}" ] || {
  echo "ERROR: rehearsal artifact sets differ" >&2
  exit 1
}

for artifact in "${FIRST_NAMES[@]}"; do
  cmp --silent "$FIRST/$artifact" "$SECOND/$artifact" || {
    echo "ERROR: non-reproducible artifact: $artifact" >&2
    exit 1
  }
done

BASE="mediabot_v3-${VERSION}-rehearsal-$(git rev-parse --short=12 "${REF}^{commit}")"
for output in "$FIRST" "$SECOND"; do
  (
    cd "$output"
    sha256sum --quiet -c "${BASE}-SHA256SUMS"
    sha512sum --quiet -c "${BASE}-SHA512SUMS"
    gzip -t "${BASE}.tar.gz"
    xz -t "${BASE}.tar.xz"
    tar -tzf "${BASE}.tar.gz" >/dev/null
    tar -tJf "${BASE}.tar.xz" >/dev/null
    grep -Fxq "${BASE}/VERSION" "${BASE}-FILES.txt"
    grep -Fq 'Rehearsal: yes (not publishable)' "${BASE}-RELEASE.txt"
  )
done

printf 'RELEASE_REHEARSAL=OK version=%s ref=%s commit=%s artifacts=6\n' \
  "$VERSION" "$REF" "$(git rev-parse "${REF}^{commit}")"
