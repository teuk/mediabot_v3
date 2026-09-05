#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

readonly APP_DIR='/opt/mbweb/app'
readonly STATE_DIR='/var/lib/mbweb-deploy'
readonly STAGE_PREFIX='/run/mbweb-deploy-stage'
readonly SERVICE='mbweb.service'
readonly UNIT_DEST='/etc/systemd/system/mbweb.service'

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift
SOURCE=''
UNIT_FILE=''
HEALTH_URL=''
BACKUP=''
STAGE=''
ACTIVE_BACKUP=''
MUTATED=0

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  mbweb_deploy.sh deploy   --source DIR --unit FILE --health-url URL
  mbweb_deploy.sh verify   --source DIR --unit FILE --health-url URL
  mbweb_deploy.sh rollback --backup DIR --health-url URL
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     [[ $# -ge 2 ]] || usage; SOURCE=$2; shift 2 ;;
    --unit)       [[ $# -ge 2 ]] || usage; UNIT_FILE=$2; shift 2 ;;
    --health-url) [[ $# -ge 2 ]] || usage; HEALTH_URL=$2; shift 2 ;;
    --backup)     [[ $# -ge 2 ]] || usage; BACKUP=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ $EUID -eq 0 ]] || fail 'run as root'
[[ "$ACTION" == deploy || "$ACTION" == verify || "$ACTION" == rollback ]] || usage
[[ "$APP_DIR" == /* && "$APP_DIR" != / && "$APP_DIR" != /opt ]] \
  || fail "unsafe APP_DIR: $APP_DIR"
[[ "$STATE_DIR" == /* && "$STATE_DIR" != / && "$STATE_DIR" != /var ]] \
  || fail "unsafe STATE_DIR: $STATE_DIR"
[[ "$STAGE_PREFIX" == /run/* && "$STAGE_PREFIX" != /run/ ]] \
  || fail "unsafe STAGE_PREFIX: $STAGE_PREFIX"
[[ "$SERVICE" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || fail "unsafe service name: $SERVICE"
[[ "$UNIT_DEST" == /etc/systemd/system/*.service ]] || fail "unsafe unit destination: $UNIT_DEST"
[[ "$HEALTH_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/[A-Za-z0-9._~/%:@+-]*/health$ ]] \
  || fail 'health URL must be an explicit loopback /health endpoint'

for command in flock rsync npm node curl sha256sum systemctl systemd-analyze install \
  stat find awk sed grep mktemp cmp chown chmod sleep rm runuser journalctl; do
  command -v "$command" >/dev/null 2>&1 || fail "required command missing: $command"
done

if [[ "$ACTION" == verify ]]; then
  if [[ -f "$STATE_DIR/deploy.lock" && ! -L "$STATE_DIR/deploy.lock" ]]; then
    exec 9<"$STATE_DIR/deploy.lock"
    flock -s -n 9 || fail 'an mbweb deployment is currently running'
  fi
else
  install -d -m 0700 -o root -g root "$STATE_DIR" "$STATE_DIR/backups" "$STATE_DIR/logs"
  exec 9>"$STATE_DIR/deploy.lock"
  flock -n 9 || fail 'another mbweb deployment is already running'
fi

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 && $MUTATED -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
    echo "ERROR: deployment failed; restoring $ACTIVE_BACKUP" >&2
    restore_backup "$ACTIVE_BACKUP" || echo 'ERROR: automatic rollback failed' >&2
  fi
  if [[ -n "$STAGE" && "$STAGE" == "$STAGE_PREFIX".* && -d "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_source() {
  [[ -d "$SOURCE" && ! -L "$SOURCE" ]] || fail "source directory missing or symbolic: $SOURCE"
  SOURCE="$(cd -- "$SOURCE" && pwd -P)"
  [[ "$SOURCE" != / ]] || fail 'source cannot be filesystem root'
  [[ -f "$SOURCE/package.json" && -f "$SOURCE/package-lock.json" && -f "$SOURCE/app.js" ]] \
    || fail 'source lacks package.json, package-lock.json or app.js'
  if find "$SOURCE" -type l -print -quit | grep -q .; then
    fail 'symbolic links are forbidden in canonical mbweb source'
  fi
  if find "$SOURCE" \
      \( -name '.env' -o \( -name '.env.*' ! -name '.env.sample' \) \
         -o -name 'node_modules' -o -name '.git' -o -name '.cache' \
         -o -name '*.log' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' \) \
      -print -quit | grep -q .; then
    fail 'canonical source contains a private or generated path'
  fi
}

validate_unit() {
  [[ -f "$UNIT_FILE" && ! -L "$UNIT_FILE" ]] || fail "unit file missing or symbolic: $UNIT_FILE"
  UNIT_FILE="$(cd -- "$(dirname -- "$UNIT_FILE")" && pwd -P)/$(basename -- "$UNIT_FILE")"
  grep -Fqx 'User=mediabot' "$UNIT_FILE" || fail 'unit must run as mediabot'
  grep -Fqx 'Group=mediabot' "$UNIT_FILE" || fail 'unit group must be mediabot'
  grep -Fqx "WorkingDirectory=$APP_DIR" "$UNIT_FILE" || fail 'unit WorkingDirectory mismatch'
  grep -Fqx "EnvironmentFile=$APP_DIR/.env" "$UNIT_FILE" || fail 'unit EnvironmentFile mismatch'
  grep -Fqx "ReadOnlyPaths=$APP_DIR" "$UNIT_FILE" || fail 'unit must make the application tree read-only'
  systemd-analyze verify "$UNIT_FILE" >/dev/null
}

runtime_diff() {
  rsync -ani --delete --checksum --omit-dir-times \
    --no-perms --no-owner --no-group \
    --include='.env.sample' \
    --exclude='.env' --exclude='.env.*' --exclude='node_modules/' \
    --exclude='.git/' --exclude='.cache/' --exclude='coverage/' \
    --exclude='tmp/' --exclude='run/' --exclude='sessions/' --exclude='backups/' \
    --exclude='*.log' --exclude='*.tar.gz' --exclude='*.tgz' --exclude='*.zip' \
    "$SOURCE/" "$APP_DIR/"
}

wait_for_health() {
  local attempt
  for ((attempt = 1; attempt <= 12; attempt++)); do
    if systemctl is-active --quiet "$SERVICE" \
        && curl --fail --silent --show-error --connect-timeout 1 --max-time 3 \
          "$HEALTH_URL" >/dev/null; then
      return 0
    fi
    ((attempt == 12)) || sleep 1
  done
  echo "ERROR: $SERVICE activation diagnostics follow" >&2
  systemctl status "$SERVICE" --no-pager --full >&2 || true
  journalctl -u "$SERVICE" -n 40 --no-pager -o short-iso-precise >&2 || true
  return 1
}

normalize_candidate_permissions() {
  local candidate=$1
  [[ "$candidate" == "$STAGE_PREFIX".* && -d "$candidate" && ! -L "$candidate" ]] \
    || fail "unsafe candidate directory: $candidate"
  chmod -R u=rwX,go=rX "$candidate"
}

validate_dependencies_as_service_user() {
  local candidate=$1
  [[ "$candidate" == "$STAGE_PREFIX".* || "$candidate" == "$APP_DIR" ]] \
    || fail "unsafe dependency validation path: $candidate"
  runuser -u mediabot -- /usr/bin/node - "$candidate" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

const root = process.argv[2];
const packagePath = path.join(root, 'package.json');
const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const appRequire = createRequire(path.join(root, 'app.js'));

for (const dependency of Object.keys(packageJson.dependencies || {})) {
  appRequire(dependency);
}
NODE
}

validate_backup() {
  local candidate=$1 resolved state_resolved
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  resolved="$(cd -- "$candidate" && pwd -P)" || return 1
  state_resolved="$(cd -- "$STATE_DIR/backups" && pwd -P)" || return 1
  [[ "$resolved" == "$state_resolved"/mbweb-* ]] || return 1
  [[ -d "$resolved/runtime" && -f "$resolved/mbweb.service" \
      && -f "$resolved/METADATA" && -f "$resolved/READY" ]] || return 1
}

restore_backup() {
  local candidate=$1
  validate_backup "$candidate" || return 1
  systemctl stop "$SERVICE" || true
  rsync -a --delete "$candidate/runtime/" "$APP_DIR/" || return 1
  install -m 0644 -o root -g root "$candidate/mbweb.service" "$UNIT_DEST" || return 1
  systemctl daemon-reload || return 1
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
  systemctl start "$SERVICE" || return 1
  wait_for_health || return 1
  MUTATED=0
}

create_backup() {
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  ACTIVE_BACKUP="$(mktemp -d "$STATE_DIR/backups/mbweb-${stamp}.XXXXXX")"
  chmod 0700 "$ACTIVE_BACKUP"
  install -d -m 0700 -o root -g root "$ACTIVE_BACKUP/runtime"
  rsync -a --delete "$APP_DIR/" "$ACTIVE_BACKUP/runtime/"
  install -m 0600 -o root -g root "$UNIT_DEST" "$ACTIVE_BACKUP/mbweb.service"
  {
    echo "created=$(date -Is)"
    echo "service=$SERVICE"
    echo "app_dir=$APP_DIR"
    echo 'initial_state=active'
  } > "$ACTIVE_BACKUP/METADATA"
  chmod 0600 "$ACTIVE_BACKUP/METADATA"
  : > "$ACTIVE_BACKUP/READY"
  chmod 0600 "$ACTIVE_BACKUP/READY"
}

prepare_stage() {
  local audit_rc
  STAGE="$(mktemp -d "$STAGE_PREFIX.XXXXXX")"
  chmod 0755 "$STAGE"
  rsync -a --delete --delete-excluded \
    --include='.env.sample' \
    --exclude='.env' --exclude='.env.*' --exclude='node_modules/' \
    --exclude='.git/' --exclude='.cache/' --exclude='coverage/' \
    --exclude='tmp/' --exclude='run/' --exclude='sessions/' --exclude='backups/' \
    --exclude='*.log' --exclude='*.tar.gz' --exclude='*.tgz' --exclude='*.zip' \
    "$SOURCE/" "$STAGE/"
  npm_config_cache="$STATE_DIR/npm-cache" \
    npm --prefix "$STAGE" ci --omit=dev --ignore-scripts --no-audit --no-fund
  AUDIT_PATH="$STATE_DIR/logs/npm-audit-$(date +%Y%m%d_%H%M%S)-$$.json"
  set +e
  npm_config_cache="$STATE_DIR/npm-cache" \
    npm --prefix "$STAGE" audit --omit=dev --audit-level=high --json > "$AUDIT_PATH"
  audit_rc=$?
  set -e
  chmod 0600 "$AUDIT_PATH"
  [[ $audit_rc -eq 0 ]] || fail "npm audit rejected the candidate (rc=$audit_rc; $AUDIT_PATH)"
  npm --prefix "$STAGE" ls --omit=dev --depth=0 >/dev/null
  node --check "$STAGE/app.js"
  normalize_candidate_permissions "$STAGE"
  validate_dependencies_as_service_user "$STAGE"
}

deploy() {
  local diff source_sha
  validate_source
  validate_unit
  [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] || fail "runtime missing or symbolic: $APP_DIR"
  [[ -f "$APP_DIR/.env" && ! -L "$APP_DIR/.env" ]] || fail 'private runtime .env missing or symbolic'
  [[ -f "$UNIT_DEST" && ! -L "$UNIT_DEST" ]] || fail "installed unit missing or symbolic: $UNIT_DEST"
  systemctl is-active --quiet "$SERVICE" || fail "$SERVICE must be active before deployment"
  prepare_stage
  create_backup
  MUTATED=1
  systemctl stop "$SERVICE"
  rsync -a --delete --exclude='.env' "$STAGE/" "$APP_DIR/"
  install -m 0644 -o root -g root "$UNIT_FILE" "$UNIT_DEST"
  chown -R root:root "$APP_DIR"
  chown mediabot:mediabot "$APP_DIR/.env"
  chmod 0600 "$APP_DIR/.env"
  find "$APP_DIR" -type d -exec chmod go-w {} +
  find "$APP_DIR" -type f ! -name '.env' -exec chmod go-w {} +
  validate_dependencies_as_service_user "$APP_DIR"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
  systemctl start "$SERVICE"
  wait_for_health || fail "$SERVICE did not become healthy"
  diff="$(runtime_diff)"
  [[ -z "$diff" ]] || fail "runtime differs from canonical source: $diff"
  cmp --silent "$UNIT_FILE" "$UNIT_DEST" || fail 'installed unit differs from canonical unit'
  npm --prefix "$APP_DIR" ls --omit=dev --depth=0 >/dev/null
  source_sha="$(sha256sum "$SOURCE/package-lock.json" | awk '{print $1}')"
  {
    echo "deployed=$(date -Is)"
    echo "package_lock_sha256=$source_sha"
    echo "audit=$AUDIT_PATH"
  } >> "$ACTIVE_BACKUP/METADATA"
  MUTATED=0
  echo "MBWEB_BACKUP=$ACTIVE_BACKUP"
  echo "MBWEB_AUDIT=$AUDIT_PATH"
  echo "MBWEB_PACKAGE_LOCK_SHA256=$source_sha"
}

verify() {
  local diff
  validate_source
  validate_unit
  systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
  cmp --silent "$UNIT_FILE" "$UNIT_DEST" || fail 'installed unit differs from canonical unit'
  diff="$(runtime_diff)"
  [[ -z "$diff" ]] || fail "runtime differs from canonical source: $diff"
  validate_dependencies_as_service_user "$APP_DIR"
  npm --prefix "$APP_DIR" ls --omit=dev --depth=0 >/dev/null
  wait_for_health || fail "$SERVICE is not healthy"
  echo 'MBWEB_VERIFY=OK'
}

case "$ACTION" in
  deploy)
    [[ -n "$SOURCE" && -n "$UNIT_FILE" && -z "$BACKUP" ]] || usage
    deploy
    ;;
  verify)
    [[ -n "$SOURCE" && -n "$UNIT_FILE" && -z "$BACKUP" ]] || usage
    verify
    ;;
  rollback)
    [[ -n "$BACKUP" && -z "$SOURCE" && -z "$UNIT_FILE" ]] || usage
    restore_backup "$BACKUP" || fail "rollback failed: $BACKUP"
    echo "MBWEB_ROLLBACK=OK"
    ;;
esac
