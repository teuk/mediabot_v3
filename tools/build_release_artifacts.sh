#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="3.3"
REF="3.3"
DEST_DIR="dist"
FORCE=0

usage() {
  cat <<'USAGE'
Usage:
  tools/build_release_artifacts.sh [options]

Options:
  --version X.Y   Stable version to package (default: 3.3)
  --ref REF       Git tag/ref to archive (default: same as version)
  --dest DIR      Destination directory (default: ./dist)
  --force         Replace existing artifacts in the destination
  -h, --help      Show this help

The builder archives only files exported by Git from the selected ref. It
requires the ref to point at HEAD, VERSION to match the requested stable
version, and the tracked worktree/index to be clean. Untracked local files do
not affect the archive.
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
    --dest)
      [ "$#" -ge 2 ] || { echo "ERROR: --dest requires a directory" >&2; exit 2; }
      DEST_DIR="$2"
      shift
      ;;
    --force)
      FORCE=1
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

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: stable version must use X.Y, got: $VERSION" >&2
  exit 2
}

command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar not found" >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "ERROR: gzip not found" >&2; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "ERROR: xz not found" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum not found" >&2; exit 1; }
command -v sha512sum >/dev/null 2>&1 || { echo "ERROR: sha512sum not found" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a Git repository" >&2
  exit 1
}
cd "$REPO_ROOT"

if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
  echo "ERROR: tracked worktree/index changes remain; package only the committed release" >&2
  git status --short >&2
  exit 1
fi

git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null || {
  echo "ERROR: Git ref not found: $REF" >&2
  exit 1
}

HEAD_COMMIT="$(git rev-parse HEAD)"
REF_COMMIT="$(git rev-parse "${REF}^{commit}")"
if [ "$HEAD_COMMIT" != "$REF_COMMIT" ]; then
  echo "ERROR: $REF does not point at HEAD" >&2
  echo "  HEAD: $HEAD_COMMIT" >&2
  echo "  $REF: $REF_COMMIT" >&2
  exit 1
fi

REF_VERSION="$(git show "${REF}:VERSION" 2>/dev/null | tr -d '\r\n')"
if [ "$REF_VERSION" != "$VERSION" ]; then
  echo "ERROR: VERSION at $REF is '$REF_VERSION', expected '$VERSION'" >&2
  exit 1
fi

REF_CHANGELOG="$(git show "${REF}:CHANGELOG.md" 2>/dev/null || true)"
if ! grep -Eq "^##[[:space:]]*\[${VERSION//./\\.}\][[:space:]]+—[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}" <<<"$REF_CHANGELOG"; then
  echo "ERROR: CHANGELOG.md does not contain a dated [$VERSION] release heading" >&2
  exit 1
fi
if grep -Eiq "^##[[:space:]]*\[${VERSION//./\\.}\].*(unreleased|target)" <<<"$REF_CHANGELOG"; then
  echo "ERROR: CHANGELOG.md still marks $VERSION as unreleased/target" >&2
  exit 1
fi

for required in Mediabot contrib docs install plugins t tools; do
  git cat-file -e "${REF}:${required}" 2>/dev/null || {
    echo "ERROR: required release directory missing from $REF: $required" >&2
    exit 1
  }
done
for required in CHANGELOG.md LICENSE.md README.md VERSION configure mediabot.pl mediabot.sample.conf; do
  git cat-file -e "${REF}:${required}" 2>/dev/null || {
    echo "ERROR: required release file missing from $REF: $required" >&2
    exit 1
  }
done

BASE="mediabot_v3-${VERSION}"
PREFIX="${BASE}/"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mediabot-release-${VERSION}.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RAW_TAR="$WORK/${BASE}.tar"
GZ="$WORK/${BASE}.tar.gz"
XZ="$WORK/${BASE}.tar.xz"
FILES="$WORK/${BASE}-FILES.txt"
INFO="$WORK/${BASE}-RELEASE.txt"
SHA256="$WORK/${BASE}-SHA256SUMS"
SHA512="$WORK/${BASE}-SHA512SUMS"
EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"

git archive --format=tar --prefix="$PREFIX" "$REF" >"$RAW_TAR"
tar -tf "$RAW_TAR" | LC_ALL=C sort >"$FILES"

require_archive_path() {
  local path="$1"
  grep -Fxq "${PREFIX}${path}" "$FILES" || {
    echo "ERROR: required archive path missing: ${PREFIX}${path}" >&2
    exit 1
  }
}

require_archive_prefix() {
  local path="$1"
  grep -Fq "${PREFIX}${path}/" "$FILES" || {
    echo "ERROR: required archive directory missing/empty: ${PREFIX}${path}/" >&2
    exit 1
  }
}

for path in CHANGELOG.md LICENSE.md README.md VERSION configure mediabot.pl mediabot.sample.conf; do
  require_archive_path "$path"
done
for path in Mediabot contrib docs install plugins t tools; do
  require_archive_prefix "$path"
done

if grep -Eq "^${PREFIX}(commit\.sh$|mediabot\.conf$|mp3/|node_modules/|.*?/node_modules/|\.git/|.*\.log($|\.)|.*\.bak($|\.)|.*\.pem$|.*\.key$|.*\.p12$|.*\.pfx$|.*\.zip$|.*\.tar($|\.)|.*snap_mediabot)" "$FILES"; then
  echo "ERROR: forbidden private/generated material is present in the archive" >&2
  grep -E "^${PREFIX}(commit\.sh$|mediabot\.conf$|mp3/|node_modules/|.*?/node_modules/|\.git/|.*\.log($|\.)|.*\.bak($|\.)|.*\.pem$|.*\.key$|.*\.p12$|.*\.pfx$|.*\.zip$|.*\.tar($|\.)|.*snap_mediabot)" "$FILES" >&2 || true
  exit 1
fi

tar -xf "$RAW_TAR" -C "$EXTRACT"
RELEASE_ROOT="$EXTRACT/$BASE"
[ "$(tr -d '\r\n' <"$RELEASE_ROOT/VERSION")" = "$VERSION" ] || {
  echo "ERROR: extracted VERSION mismatch" >&2
  exit 1
}

bash -n "$RELEASE_ROOT/configure"
bash -n "$RELEASE_ROOT/install/db_install.sh"
(
  cd "$RELEASE_ROOT"
  perl -c t/test_commands.pl >/dev/null
  perl tools/check_schema_drift.pl --help >/dev/null
)

gzip -n -9 -c "$RAW_TAR" >"$GZ"
xz -T1 -9e --check=crc64 -c "$RAW_TAR" >"$XZ"
gzip -t "$GZ"
xz -t "$XZ"

grep -Fc "${PREFIX}contrib/" "$FILES" | grep -Eq '^[1-9][0-9]*$' || {
  echo "ERROR: contrib directory exported without files" >&2
  exit 1
}
grep -Fc "${PREFIX}plugins/" "$FILES" | grep -Eq '^[1-9][0-9]*$' || {
  echo "ERROR: plugins directory exported without files" >&2
  exit 1
}

COMMIT_DATE="$(git show -s --format=%cI "$REF")"
FILE_COUNT="$(wc -l <"$FILES" | tr -d ' ')"
cat >"$INFO" <<EOF_INFO
Mediabot release: $VERSION
Git ref: $REF
Git commit: $REF_COMMIT
Commit date: $COMMIT_DATE
Archive root: $PREFIX
Archived paths: $FILE_COUNT

Artifacts:
  ${BASE}.tar.gz
  ${BASE}.tar.xz
  ${BASE}-FILES.txt
  ${BASE}-RELEASE.txt
  ${BASE}-SHA256SUMS
  ${BASE}-SHA512SUMS

Compression is deterministic for a fixed release commit:
  gzip: -n -9
  xz:   -T1 -9e --check=crc64
EOF_INFO

(
  cd "$WORK"
  sha256sum "${BASE}.tar.gz" "${BASE}.tar.xz" >"$(basename "$SHA256")"
  sha512sum "${BASE}.tar.gz" "${BASE}.tar.xz" >"$(basename "$SHA512")"
  sha256sum -c "$(basename "$SHA256")"
  sha512sum -c "$(basename "$SHA512")"
)

mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
ARTIFACTS=(
  "${BASE}.tar.gz"
  "${BASE}.tar.xz"
  "${BASE}-FILES.txt"
  "${BASE}-RELEASE.txt"
  "${BASE}-SHA256SUMS"
  "${BASE}-SHA512SUMS"
)

if [ "$FORCE" -ne 1 ]; then
  for artifact in "${ARTIFACTS[@]}"; do
    if [ -e "$DEST_DIR/$artifact" ]; then
      echo "ERROR: destination artifact already exists: $DEST_DIR/$artifact" >&2
      echo "Use --force only after verifying that replacement is intended." >&2
      exit 1
    fi
  done
fi

for artifact in "${ARTIFACTS[@]}"; do
  tmp_dest="$DEST_DIR/.${artifact}.tmp.$$"
  install -m 0644 "$WORK/$artifact" "$tmp_dest"
  mv -f "$tmp_dest" "$DEST_DIR/$artifact"
done

(
  cd "$DEST_DIR"
  sha256sum -c "${BASE}-SHA256SUMS"
  sha512sum -c "${BASE}-SHA512SUMS"
  gzip -t "${BASE}.tar.gz"
  xz -t "${BASE}.tar.xz"
)

printf '\nRelease artifacts created from %s (%s):\n' "$REF" "$REF_COMMIT"
ls -lh "$DEST_DIR/${BASE}.tar.gz" "$DEST_DIR/${BASE}.tar.xz" \
  "$DEST_DIR/${BASE}-FILES.txt" "$DEST_DIR/${BASE}-RELEASE.txt" \
  "$DEST_DIR/${BASE}-SHA256SUMS" "$DEST_DIR/${BASE}-SHA512SUMS"
printf '\nSHA-256:\n'
cat "$DEST_DIR/${BASE}-SHA256SUMS"
printf '\nSHA-512:\n'
cat "$DEST_DIR/${BASE}-SHA512SUMS"
