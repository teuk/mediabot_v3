# Add the local Undernet network observatory (MB830)

This procedure adds `https://teuk.org/undernet` to the existing hub on teuk.org.
It retains `/mbdev`, `/epiknet`, their publishing credentials, SQLite history
and publisher outboxes. It does not configure ubot or WitchHunter.

| Component | Actual instance |
| --- | --- |
| Host / account | `teuk.org` / `mediabot` |
| Production bot | `/home/mediabot/mediabot3` |
| Private bot configuration | `/home/mediabot/mediabot3/mbundernet.conf` |
| Bot unit | `mediabot@undernet.service` |
| Aggregate snapshot | `/home/mediabot/mediabot3/var/network-stats.json` |
| Local publisher | `mediabot-network-publish-undernet.service` and `.timer` |
| Public dashboard | `https://teuk.org/undernet` |

The dev instance is a different checkout and configuration. Its declared network
is TeuK. Do not enable the Undernet export through the dev `mediabot.conf`.

## 1. Validate source and the existing installation

Install and validate the MB830 source package in the development repository.
It adds `contrib/network-stats/add_local.py`; it does not operate services.
The existing Undernet checkout must already contain `Mediabot/NetworkStats.pm`
and its core integration. On the reviewed installation it is already at
`3.6dev-20261017_184524` and the unit is active.

The systemd template declares `WorkingDirectory=/`, then explicitly changes
to `$BOT_DIR` in its shell wrapper. The verified environment is:

```text
BOT_DIR=/home/mediabot/mediabot3
BOT_BIN=/home/mediabot/mediabot3/mediabot.pl
BOT_CONF=/home/mediabot/mediabot3/mbundernet.conf
```

No systemd template change is needed. An absolute export path also keeps the
publisher independent of a caller's current directory.

As `mediabot` on teuk.org, preview the hub extension:

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  test "$(hostname -f)" = teuk.org
  cd /home/mediabot/mediabot_v3
  sudo -n python3 -B contrib/network-stats/add_local.py \
    --instance undernet --label Undernet \
    --snapshot /home/mediabot/mediabot3/var/network-stats.json \
    --apache-vhost /etc/apache2/sites-enabled/default-ssl.conf
)
```

The helper requires the existing managed hub/config/routes and its installed
implementation to match. It checks the current streams through public HTTPS.
Unexpected edits, conflicting files, symbolic paths or a stream already bound
to a different snapshot are rejected. It never prints a publisher token.

## 2. Add only the Undernet stream

Repeat the same command with `--apply`. The helper takes a provisioning lock,
backs up its scoped files privately and creates one new credential, publisher
configuration, unit and timer. It extends the hub configuration and managed
Apache routes, reloads the hub/Apache and validates all public stream endpoints.

The existing bot instances and publishers are not restarted. The shared hub
briefly restarts to load its additional stream. Failure restores managed files,
restarts the previous hub configuration and retains histories/outboxes. A
concurrent operator edit is retained with the backup location reported.
If a recovery write or service restart itself fails, the helper explicitly
reports that local inspection is required and retains the private backup.
Repeated application verifies the existing binding without rotating its token
or restarting the hub. History starts when real Undernet observations arrive.

The publisher configuration is private at
`/etc/mediabot-network-stats/undernet.publisher.json` (0600). It uses the local
loopback ingest endpoint and its own durable outbox. No SSH or remote token
transfer is needed for this local bot.

## 3. Enable export in the real Undernet configuration

After the hub extension succeeds, stop only `mediabot@undernet.service`, back up
its configuration privately, use `Mediabot::Conf` to write the following keys,
reread them, then start that same unit. Keep a start-on-exit trap while stopped.

```ini
[network_stats]
ENABLED=1
OUTPUT_FILE=/home/mediabot/mediabot3/var/network-stats.json

[main]
LUSERS_REFRESH=300
```

These are individual settings in the existing file, not replacement sections.
The account/network settings and all other private configuration are retained.
The prior absence of `LUSERS_REFRESH` already meant the five-minute default;
writing it explicitly records the selected collection interval.

Use the bundle's `activate_undernet.sh` after the hub has been provisioned. It
checks the running instance's real process directory and the private publisher
snapshot binding before stopping the bot. It uses `mbundernet.conf` explicitly,
backs it up while stopped and restores the original configuration if validation
fails before starting the bot again. It does not activate AI or other features.

## 4. Verify real collection, not just an empty dashboard

Confirm both units are active:

```bash
systemctl --no-pager show mediabot@undernet.service \
  mediabot-network-publish-undernet.timer -p Id -p ActiveState -p SubState
```

After reconnection and at most one normal collection interval, the private
snapshot should have `network=Undernet` and a fresh `sampled_at` value. The
publisher timer runs every 30 seconds. Check the public endpoint:

```text
https://teuk.org/undernet/data?range=1h
```

It must identify `stream=undernet` and eventually contain an actual Undernet
observation, rather than the dev network. `/mbdev` and `/epiknet` must still
show their own streams. A page that is merely waiting for its first sample
confirms routing, not end-to-end collection. Missing/restricted IRC numerics
remain unknown and no history is manufactured.

## Future maintenance

The original `setup.py hub` command deliberately refuses a changed stream set.
After this addition the hub has three streams: a later whole-hub deployment
must explicitly retain all three. A separate full reconfiguration needs review;
do not delete hub.json, regenerate all tokens or reset the history to add a
network. Source updates and web-service deployment remain separate operations.
