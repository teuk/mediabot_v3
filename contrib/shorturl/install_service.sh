#!/bin/bash
# Install/update the loopback ShortURL service. Apache is configured separately.

set -Eeuo pipefail

export PATH='/usr/sbin:/usr/bin:/sbin:/bin'

if [ "$(id -u)" -ne 0 ]; then
  echo '[KO] Run this installer with sudo.' >&2
  exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
runtime_root='/opt/mediabot-shorturl'
release_root="$runtime_root/releases"
state_root='/var/lib/mediabot-shorturl'
unit_path='/etc/systemd/system/mediabot-shorturl.service'
credential_path='/home/mediabot/shorturl-dev.token'

for source_file in \
  shorturl_service.py shorturl_admin.py mediabot-shorturl.service.example; do
  test -f "$script_dir/$source_file" || {
    echo "[KO] Missing source file: $script_dir/$source_file" >&2
    exit 1
  }
done

id mediabot >/dev/null 2>&1 || {
  echo '[KO] Unix account mediabot does not exist.' >&2
  exit 1
}

for target in "$runtime_root" "$release_root" "$state_root" "$unit_path"; do
  if [ -L "$target" ]; then
    echo "[KO] Refusing symlink target: $target" >&2
    exit 1
  fi
done

if [ ! -f "$state_root/control/service.json" ] && {
  [ -e "$credential_path" ] || [ -L "$credential_path" ];
}; then
  echo "[KO] Refusing to overwrite initial credential: $credential_path" >&2
  exit 1
fi

/usr/bin/python3 -B -c 'import sqlite3, waitress' 2>/dev/null || {
  echo '[KO] Missing runtime dependency. Install: sudo apt-get install python3 python3-waitress' >&2
  exit 1
}

/usr/bin/python3 -B "$script_dir/test_shorturl_service.py"

install -d -m 0755 -o root -g root "$runtime_root" "$release_root"
release_id="mb736-$(date -u +%Y%m%dT%H%M%SZ)-$$"
release_dir="$release_root/$release_id"
install -d -m 0755 -o root -g root "$release_dir"
install -m 0755 -o root -g root \
  "$script_dir/shorturl_service.py" "$release_dir/shorturl_service.py"
install -m 0755 -o root -g root \
  "$script_dir/shorturl_admin.py" "$release_dir/shorturl_admin.py"

ln -s "releases/$release_id" "$runtime_root/app.next"
mv -Tf "$runtime_root/app.next" "$runtime_root/app"

install -d -m 0700 -o mediabot -g mediabot "$state_root"
if [ ! -f "$state_root/control/service.json" ]; then
  runuser -u mediabot -- /usr/bin/python3 -B \
    "$runtime_root/app/shorturl_admin.py" init \
    --public-base 'https://teuk.org/shorturl/' \
    --identity dev \
    --credential-output "$credential_path"
else
  runuser -u mediabot -- /usr/bin/python3 -B \
    "$runtime_root/app/shorturl_admin.py" list >/dev/null
  echo '[OK] Existing service state and token hashes preserved.'
fi

if [ -f "$unit_path" ] && [ ! -e "$unit_path.pre-mb736" ]; then
  install -m 0644 -o root -g root "$unit_path" "$unit_path.pre-mb736"
fi
install -m 0644 -o root -g root \
  "$script_dir/mediabot-shorturl.service.example" "$unit_path"

systemd-analyze verify "$unit_path"
systemctl daemon-reload
systemctl enable mediabot-shorturl.service
systemctl restart mediabot-shorturl.service
systemctl is-active --quiet mediabot-shorturl.service || {
  systemctl --no-pager --full status mediabot-shorturl.service
  exit 1
}

health=''
health_ok=0
for attempt in $(seq 1 20); do
  if health="$({ curl --fail --silent --show-error \
    'http://127.0.0.1:8766/healthz'; } 2>&1)"; then
    health_ok=1
    break
  fi
  systemctl is-active --quiet mediabot-shorturl.service || break
  sleep 1
done
if [ "$health_ok" -ne 1 ]; then
  echo "$health" >&2
  journalctl -u mediabot-shorturl.service -n 30 --no-pager >&2
  exit 1
fi
/usr/bin/python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value.get("ok") is True and value.get("protocol") == 1
' <<<"$health"

echo '[OK] mediabot-shorturl.service is active on 127.0.0.1:8766.'
if [ -f "$credential_path" ]; then
  echo "[NEXT] Copy the token from $credential_path into [shorturl] API_KEY; do not display it in logs."
fi
echo '[NEXT] Add the reviewed ProxyPass directives to the teuk.org HTTPS vhost.'
