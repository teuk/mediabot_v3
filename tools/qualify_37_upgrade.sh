#!/usr/bin/env bash
# MB787: qualify the non-publishable 3.7 rehearsal against the released 3.5 schema.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: tools/qualify_37_upgrade.sh --repo ROOT --candidate ROOT [--lineage-only]

The candidate must be an unpacked 3.7 rehearsal (VERSION remains 3.6dev).
--lineage-only checks the immutable 3.5 migration history and exact published
order without starting MariaDB. The database trial runs only in disposable CI.
USAGE
}

REPO=''
CANDIDATE=''
LINEAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--candidate)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      if [ "$1" = --repo ]; then REPO="$2"; else CANDIDATE="$2"; fi
      shift 2 ;;
    --lineage-only) LINEAGE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$CANDIDATE" ] || { usage >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"
CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"
[ "$REPO" != "$CANDIDATE" ] || { echo 'ERROR: candidate must be an extracted archive' >&2; exit 1; }
[ ! -e "$CANDIDATE/.git" ] || { echo 'ERROR: candidate contains Git metadata' >&2; exit 1; }
[ -f "$CANDIDATE/install/mediabot.sql" ] || { echo 'ERROR: candidate schema missing' >&2; exit 1; }
[ -d "$CANDIDATE/install/migrations" ] || { echo 'ERROR: candidate migrations missing' >&2; exit 1; }
[ "$(git -C "$REPO" rev-parse --show-toplevel)" = "$REPO" ] || {
  echo 'ERROR: repository root required' >&2; exit 1;
}
[ "$(git -C "$REPO" cat-file -t 3.5)" = tag ] || {
  echo 'ERROR: stable 3.5 must be an annotated Git tag' >&2; exit 1;
}
[ "$(git -C "$REPO" show 3.5:VERSION | tr -d '\r\n')" = 3.5 ] || {
  echo 'ERROR: stable tag does not contain VERSION=3.5' >&2; exit 1;
}
SOURCE_VERSION="$(tr -d '\r\n' <"$CANDIDATE/VERSION")"
case "$SOURCE_VERSION" in
  3.6dev|3.6dev-*) ;;
  *) echo "ERROR: expected an unpacked 3.6dev candidate, got $SOURCE_VERSION" >&2; exit 1 ;;
esac
[ "$SOURCE_VERSION" = "$(git -C "$REPO" show HEAD:VERSION | tr -d '\r\n')" ] || {
  echo 'ERROR: candidate VERSION differs from checked-out commit' >&2; exit 1;
}
if [ -n "${GITHUB_SHA:-}" ]; then
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$GITHUB_SHA" ] || {
    echo 'ERROR: checkout differs from selected CI candidate' >&2; exit 1;
  }
fi

WORK="$(mktemp -d /tmp/mediabot-37-upgrade.XXXXXX)"
DB_PID=''
DB_LOG=''
cleanup() {
  if [ -n "$DB_PID" ] && kill -0 "$DB_PID" 2>/dev/null; then
    kill "$DB_PID" 2>/dev/null || true
    wait "$DB_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
  [ -z "$DB_LOG" ] || rm -f "$DB_LOG"
}
trap cleanup EXIT

STABLE_ROOT="$WORK/stable"
mkdir -p "$STABLE_ROOT"
git -C "$REPO" archive --format=tar 3.5 -- install/mediabot.sql install/migrations \
  | tar -xf - -C "$STABLE_ROOT"
test -s "$STABLE_ROOT/install/mediabot.sql"

find "$STABLE_ROOT/install/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
  | LC_ALL=C sort >"$WORK/stable-files"
find "$CANDIDATE/install/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
  | LC_ALL=C sort >"$WORK/candidate-files"
test -s "$WORK/stable-files"
if [ -s <(comm -23 "$WORK/stable-files" "$WORK/candidate-files") ]; then
  echo 'ERROR: a released 3.5 migration is missing' >&2
  comm -23 "$WORK/stable-files" "$WORK/candidate-files" >&2
  exit 1
fi
while IFS= read -r name; do
  cmp --silent "$STABLE_ROOT/install/migrations/$name" \
    "$CANDIDATE/install/migrations/$name" || {
    echo "ERROR: released 3.5 migration changed: $name" >&2
    exit 1
  }
done <"$WORK/stable-files"

# The fenced public order is an exact permutation of the candidate SQL files.
# The diff rejects missing entries, duplicates, phantom names and extra SQL.
awk '
  /^## Current migration order$/ { section=1; next }
  section && /^```text$/ { fenced=1; next }
  fenced && /^```$/ { exit }
  fenced && /^[A-Za-z0-9_]+\.sql$/ { print }
' "$CANDIDATE/install/migrations/README.md" >"$WORK/ordered-all"
test -s "$WORK/ordered-all" || { echo 'ERROR: no public migration order' >&2; exit 1; }
LC_ALL=C sort "$WORK/ordered-all" >"$WORK/ordered-sorted"
cmp --silent "$WORK/ordered-sorted" "$WORK/candidate-files" || {
  echo 'ERROR: published migration order is not the exact SQL inventory' >&2
  exit 1
}
comm -13 "$WORK/stable-files" "$WORK/candidate-files" >"$WORK/new-files"
while IFS= read -r name; do
  if grep -Fxq "$name" "$WORK/new-files"; then printf '%s\n' "$name"; fi
done <"$WORK/ordered-all" >"$WORK/ordered-new"
test -s "$WORK/ordered-new" || {
  echo 'ERROR: no migration after stable 3.5; upgrade proof would be empty' >&2
  exit 1
}
printf 'MB787_LINEAGE=OK stable=3.5 candidate=%s migrations=%s\n' \
  "$SOURCE_VERSION" "$(wc -l <"$WORK/ordered-new" | tr -d ' ')"
cat "$WORK/ordered-new"
[ "$LINEAGE_ONLY" -eq 0 ] || exit 0

[ "${GITHUB_ACTIONS:-}" = true ] && [ "${CI:-}" = true ] || {
  echo 'ERROR: database trial is restricted to disposable GitHub Actions CI' >&2
  exit 1
}
[ -n "${GITHUB_SHA:-}" ] && [ -n "${GITHUB_WORKSPACE:-}" ] || {
  echo 'ERROR: exact GitHub candidate identity is required' >&2; exit 1
}
[ "$REPO" = "$(cd "$GITHUB_WORKSPACE" && pwd -P)" ] || {
  echo 'ERROR: repository differs from the CI checkout' >&2; exit 1
}
EXPECTED_ROOT="/opt/mediabot-candidate/mediabot_v3-3.7-rehearsal-${GITHUB_SHA:0:12}"
[ "$CANDIDATE" = "$EXPECTED_ROOT" ] || {
  echo 'ERROR: database trial requires the exact unpacked CI rehearsal' >&2; exit 1
}
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 13 ] || {
  echo 'ERROR: database trial requires disposable Debian 13' >&2; exit 1
}
command -v mariadbd >/dev/null
command -v mariadb-dump >/dev/null
command -v mysqladmin >/dev/null
test "$(id -u)" -eq 0

UPGRADE_DB=mediabot_rc37_upgrade
SOCKET=/run/mysqld/mysqld.sock
install -d -m 0755 -o mysql -g mysql /run/mysqld
DB_LOG="$(mktemp /tmp/mediabot-37-mariadb.XXXXXX.log)"
chown mysql:mysql "$DB_LOG"
mariadbd --user=mysql --datadir=/var/lib/mysql \
  --socket="$SOCKET" --pid-file=/run/mysqld/mysqld.pid \
  --bind-address=127.0.0.1 --log-error="$DB_LOG" &
DB_PID=$!
ready=0
for _ in $(seq 1 60); do
  if mysqladmin --protocol=socket --socket="$SOCKET" -uroot ping --silent; then
    ready=1; break
  fi
  if ! kill -0 "$DB_PID" 2>/dev/null; then cat "$DB_LOG" >&2; exit 1; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { cat "$DB_LOG" >&2; exit 1; }

cat >"$WORK/root.cnf" <<EOF_CNF
[client]
user=root
socket=$SOCKET
default-character-set=utf8mb4
EOF_CNF
chmod 0600 "$WORK/root.cnf"
db() { mysql --defaults-extra-file="$WORK/root.cnf" "$@"; }
dump_db() {
  mariadb-dump --defaults-extra-file="$WORK/root.cnf" \
    --single-transaction --skip-comments --order-by-primary \
    --skip-extended-insert "$UPGRADE_DB" >"$1"
}
drift() {
  MEDIABOT_DB="$UPGRADE_DB" MEDIABOT_DB_USER=root MEDIABOT_DB_PASS='' \
    MEDIABOT_DB_SOCKET="$SOCKET" \
    perl "$CANDIDATE/tools/check_schema_drift.pl" --strict --types --indexes "$@"
}
recreate_db() {
  db --execute="DROP DATABASE IF EXISTS ${UPGRADE_DB}; CREATE DATABASE ${UPGRADE_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}
apply_new() {
  while IFS= read -r name; do
    echo "Applying post-3.5 migration: $name"
    bash "$CANDIDATE/install/db_migrate.sh" \
      --defaults-extra-file "$WORK/root.cnf" "$UPGRADE_DB" \
      "$CANDIDATE/install/migrations/$name"
  done <"$WORK/ordered-new"
}
assert_expected_drift() {
  local rc
  if drift --quiet; then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || {
    echo "ERROR: pre-upgrade drift must be 1, got $rc" >&2; exit 1;
  }
}

recreate_db
db "$UPGRADE_DB" <"$STABLE_ROOT/install/mediabot.sql"
assert_expected_drift
dump_db "$WORK/pre.sql"
apply_new
drift
dump_db "$WORK/migrated.sql"

recreate_db
db "$UPGRADE_DB" <"$WORK/pre.sql"
dump_db "$WORK/rollback.sql"
cmp --silent "$WORK/pre.sql" "$WORK/rollback.sql" || {
  echo 'ERROR: logical rollback differs from stable 3.5' >&2; exit 1;
}
assert_expected_drift
echo 'MB787_ROLLBACK=OK'

apply_new
drift
dump_db "$WORK/reapplied.sql"
cmp --silent "$WORK/migrated.sql" "$WORK/reapplied.sql" || {
  echo 'ERROR: post-3.5 reapplication is not deterministic' >&2; exit 1;
}
echo 'MB787_REAPPLY=OK'
