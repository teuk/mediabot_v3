# Libera: a fourth observatory stream (MB831)

Target: **mediabot.teuk.org**, user **mediabot**, directory
`/home/mediabot/mediabot_v3`, config `mediabot.conf`, dashboard
**https://teuk.org/libera**. The observed Perl process does not establish its
systemd service name. Never assume it uses the dev, EpikNet or Undernet unit.

| Stream | Bot host | Absolute snapshot | Dashboard |
| --- | --- | --- | --- |
| mbdev / TeuK dev | teuk.org | /home/mediabot/mediabot_v3/var/network-stats.json | teuk.org/mbdev |
| undernet | teuk.org | /home/mediabot/mediabot3/var/network-stats.json | teuk.org/undernet |
| epiknet | nbot.soyou.rocks | /home/mediabot/mediabot_v3/var/network-stats.json | teuk.org/epiknet |
| libera | mediabot.teuk.org | /home/mediabot/mediabot_v3/var/network-stats.json | teuk.org/libera |

No ubot or WitchHunter deployment is part of this change.

## 1. Upgrade the existing web application on teuk.org

Apply and validate the source packet first. As mediabot on **teuk.org**:

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  test "$(hostname -f)" = teuk.org
  cd /home/mediabot/mediabot_v3
  sudo -n python3 -B contrib/network-stats/upgrade.py \
    --apache-vhost /etc/apache2/sites-enabled/default-ssl.conf
)
```

Repeat with `--apply`. Only the reviewed Python hub and three static assets
under `/opt/mediabot-network-stats` are installed. Every configured stream is
discovered from the existing config and checked through public HTTPS. Only the
hub service restarts. Credentials, configuration, routes, SQLite databases,
IRC bots and publisher timers are retained. A private backup/scoped rollback
protects the old code. Rerunning identical code does not restart anything.
Custom installed code is refused for review.

Do not rerun `setup.py hub` with its default two-stream profile to upgrade an
existing three/four-stream installation.

## 2. Add Libera on the web host

On **teuk.org**, preview:

```bash
sudo -n python3 -B contrib/network-stats/add_remote.py \
  --instance libera --label Libera \
  --publisher-host mediabot.teuk.org \
  --snapshot /home/mediabot/mediabot_v3/var/network-stats.json \
  --apache-vhost /etc/apache2/sites-enabled/default-ssl.conf
```

Repeat with `--apply`. Only the new stream/hash, route and private transfer file
are added. The hub/Apache briefly reload, and all old/new public routes are
checked. Existing tokens, outboxes and history stay in place. The new page
initially has no measurements. No Libera publisher is installed on teuk.org.

The random token is in `/home/mediabot/network-stats-libera.private.json`, mode
0600, owned by mediabot. The hub stores only its hash. Matching reruns preserve
that token. Conflicting binding or missing original private credentials stop
the helper; restore the original private file rather than rotate by accident.
UI upgrades, local and remote additions share the same provisioning lock.

## 3. Transfer the private configuration

From **teuk.org**, as mediabot, through the existing authorized SSH route:

```bash
scp -p /home/mediabot/network-stats-libera.private.json \
  mediabot@mediabot.teuk.org:/home/mediabot/network-stats-libera.private.json
```

Never put it in Git, chat, a ZIP or the public document root. Keep SSH host
verification enabled. Its `publisher_host` is checked by the remote installer.

## 4. Update Libera and install the outgoing publisher

Publish the validated source through `commit.sh`, explicitly including the new
files from the packet README. Bring the Libera checkout to that version using
its verified existing update procedure. Do not assume an `!update now` policy
or service name that has not been established for that instance. Updating the
checkout does not itself activate the exporter or install the publisher.

On **mediabot.teuk.org**, as mediabot:

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  test "$(hostname -f)" = mediabot.teuk.org
  cd /home/mediabot/mediabot_v3
  test -f contrib/network-stats/activate_export.py
  test -f Mediabot/NetworkStats.pm
  sudo -n python3 -B contrib/network-stats/setup.py publisher \
    --instance libera \
    --publisher-config /home/mediabot/network-stats-libera.private.json
)
```

Repeat with `--apply`. It installs `mediabot-network-publish-libera.timer` and
its oneshot service/private config/SQLite outbox. Only outgoing verified HTTPS
is needed; no incoming port, shared SQL account or runtime SSH key.

## 5. Audit and activate the actual exporter

On **mediabot.teuk.org**, as mediabot:

```bash
python3 -B contrib/network-stats/activate_export.py \
  --instance libera --network Libera --expected-host mediabot.teuk.org \
  --bot-dir /home/mediabot/mediabot_v3 \
  --bot-conf /home/mediabot/mediabot_v3/mediabot.conf
```

Default is read-only. It verifies account/host, native config network (`Libera`
or `Libera.Chat`), exact process/cwd/config, publisher binding and active timer.
The service is discovered from the process cgroup; its `MainPID` and `User`
must match that exact bot. If cgroups are unavailable, `--unit
REAL_VERIFIED_UNIT.service` can identify an already verified system service,
with the same PID/user checks. A shell/cron/user-unit/other-supervisor launch
stops the audit without changes until its actual start/stop method is known.

Repeat with `--apply` after a successful audit. Only that unit stops. Its
private config is backed up **after stop**, then `Mediabot::Conf` writes and
rereads exactly three settings:

```ini
network_stats.ENABLED=1
network_stats.OUTPUT_FILE=/home/mediabot/mediabot_v3/var/network-stats.json
main.LUSERS_REFRESH=300
```

All other parsed settings must compare identically, including AI/keys. Only the
matched unit restarts. On failure any replacement process is stopped before
config restoration and another start request. Incomplete recovery is reported
with the private backup path; private values are never printed.

## 6. Verify the real end-to-end path

After reconnection, allow a normal five-minute LUSERS cycle and 30-second
publisher cycle. On the Libera host:

```bash
stat -c '%U:%G %a %n' /home/mediabot/mediabot_v3/var/network-stats.json
systemctl --no-pager status mediabot-network-publish-libera.timer
sudo -n journalctl -u mediabot-network-publish-libera.service -n 15 --no-pager
```

Compare https://teuk.org/libera with an actual Libera `/LUSERS` reply. Confirm
increasing sample timestamps and independent growing history. Missing numerics
mean unknown, not zero. A working page/timer alone is not live acceptance.
Existing mbdev/undernet/epiknet keep their original streams and history.
