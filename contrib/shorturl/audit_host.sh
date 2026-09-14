#!/bin/bash
# Read-only discovery before wiring ShortURL into the existing HTTPS vhost.

set -Eeuo pipefail

export PATH='/usr/sbin:/usr/bin:/sbin:/bin'

echo '===== HOST ====='
hostname --fqdn 2>/dev/null || hostname
sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -1
id
sudo -n true

echo
echo '===== MEDIABOT SOURCE ====='
if [ -d /home/mediabot/mediabot_v3/.git ]; then
  git -C /home/mediabot/mediabot_v3 rev-parse HEAD
  git -C /home/mediabot/mediabot_v3 status --short
else
  echo 'NO_GIT=/home/mediabot/mediabot_v3'
fi

echo
echo '===== RUNTIME ====='
python3 --version
python3 -B -c '
import importlib.metadata, sqlite3
print("SQLITE_VERSION=" + sqlite3.sqlite_version)
try:
    print("WAITRESS_VERSION=" + importlib.metadata.version("waitress"))
except importlib.metadata.PackageNotFoundError:
    print("WAITRESS_VERSION=MISSING")
'
systemctl --version | head -1

echo
echo '===== PORT 8766 ====='
sudo -n ss -ltnp 'sport = :8766' || true

echo
echo '===== EXISTING SERVICE ====='
sudo -n systemctl --no-pager --full status mediabot-shorturl.service || true
for path in /opt/mediabot-shorturl /var/lib/mediabot-shorturl; do
  if sudo -n test -e "$path"; then
    sudo -n stat -c 'MODE=%a OWNER=%U:%G TYPE=%F PATH=%n' "$path"
  else
    echo "ABSENT=$path"
  fi
done

echo
echo '===== APACHE VHOSTS ====='
sudo -n apache2ctl -S

echo
echo '===== APACHE MODULES ====='
sudo -n apache2ctl -M 2>/dev/null |
  sed -n -E '/(headers|proxy|proxy_http|rewrite|ssl)_module/p'

echo
echo '===== RELEVANT ENABLED VHOST DIRECTIVES ====='
sudo -n grep -RnsE --include='*.conf' \
  '^\s*(<VirtualHost|</VirtualHost|ServerName|ServerAlias|ProxyPass|ProxyPassReverse|Include|IncludeOptional|RewriteRule|RewriteCond)\b' \
  /etc/apache2/sites-enabled 2>/dev/null || true

echo
echo '===== CURRENT PUBLIC ROUTE ====='
curl --silent --show-error --output /dev/null \
  --max-time 8 --connect-timeout 4 \
  --write-out 'HTTPS_STATUS=%{http_code}\nHTTPS_REMOTE_IP=%{remote_ip}\n' \
  'https://teuk.org/shorturl/mb736probe' || true
