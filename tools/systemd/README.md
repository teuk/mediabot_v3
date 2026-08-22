# Running Mediabot v3 with systemd

Mediabot v3 can be managed as one or more systemd instances.

The recommended service is a template unit:

```text
mediabot@.service
```

Each instance loads its own environment file:

```text
/etc/default/mediabot-<instance>
```

Example:

```bash
systemctl start mediabot@dev
```

loads:

```text
/etc/default/mediabot-dev
```

## Instance model

A Mediabot instance is defined by:

```text
- its project directory
- its configuration file
- its systemd instance name
```

The configuration file may stay at the root of each instance directory.

Example multi-instance layout:

```text
/home/mediabot/mediabot_v3  -> dev instance,      mediabot.conf
/home/mediabot/mediabot3    -> Undernet instance, mbundernet.conf
```

Corresponding systemd units:

```text
mediabot@dev.service
mediabot@undernet.service
```

Corresponding environment files:

```text
/etc/default/mediabot-dev
/etc/default/mediabot-undernet
```

## Template service

Example file:

```text
/etc/systemd/system/mediabot@.service
```

```ini
[Unit]
Description=Mediabot v3 IRC bot instance (%i)
After=network-online.target
Wants=network-online.target

StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExitType=cgroup

User=mediabot
Group=mediabot

EnvironmentFile=/etc/default/mediabot-%i
Environment=MEDIABOT_SYSTEMD_UPDATE_SAFE=1

WorkingDirectory=/
SyslogIdentifier=mediabot-%i

ExecStart=/bin/bash -lc 'cd "$BOT_DIR" && exec /usr/bin/stdbuf -oL -eL /usr/bin/perl "$BOT_BIN" --conf="$BOT_CONF"'

Restart=always
SuccessExitStatus=75
RestartPreventExitStatus=75
RestartSec=10s

TimeoutStopSec=30
KillSignal=SIGTERM

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Reload systemd after installing or editing the unit:

```bash
systemctl daemon-reload
```

## Supported installer

The repository provides a fail-closed installer for the published template and
instance environment files:

```text
install/systemd_install.sh
```

For a fresh development instance:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
sudo ./install/systemd_install.sh \
  --instance dev \
  --bot-dir /home/mediabot/mediabot_v3
```

This installs:

```text
/etc/systemd/system/mediabot@.service
/etc/default/mediabot-dev
```

The helper is deliberately conservative:

- an existing identical file is accepted unchanged;
- an existing divergent template is preserved unless `--replace-template` is explicit;
- an existing divergent instance environment is preserved unless `--replace-instance` is explicit;
- symlink targets are refused;
- the current template requires systemd 250 or newer because it uses `ExitType=cgroup`;
- it does not start, restart, or enable the bot automatically.

When real `/etc` files are changed the helper runs only `systemctl daemon-reload`.
Starting and enabling an instance remain explicit operator actions after review.

For an existing installation where the per-instance `/etc/default` file must
remain untouched, update only the shared template:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
sudo ./install/systemd_install.sh --template-only --replace-template
```

The previous divergent file is backed up beside the installed file before an
explicit replacement.

After installation, review the effective unit before starting or restarting an
instance:

```bash
systemd-analyze verify /etc/systemd/system/mediabot@.service
systemctl cat mediabot@dev.service --no-pager
systemctl show mediabot@dev.service \
  -p ExitType \
  -p Restart \
  -p SuccessExitStatus \
  -p RestartPreventExitStatus \
  --no-pager
```

Expected update-safe lifecycle values are:

```text
ExitType=cgroup
Restart=always
SuccessExitStatus=75
RestartPreventExitStatus=75
```

Only after that review, enable/start explicitly when appropriate:

```bash
systemctl enable mediabot@dev.service
systemctl start mediabot@dev.service
```

### Debian 13 CI boundary

The Debian 13 gate executes this installer against an isolated filesystem root,
checks idempotency and fail-closed replacement, compares the installed unit to
the published template, and parses it with `systemd-analyze verify` from Debian
13.

That is an installation/static-unit proof. A container does not provide the
project's live systemd PID 1, so service startup, restart behavior, updater
handoff, and IRC connectivity remain end-to-end acceptance checks.

## Example environment files

### Dev instance

```text
/etc/default/mediabot-dev
```

```bash
BOT_DIR=/home/mediabot/mediabot_v3
BOT_BIN=/home/mediabot/mediabot_v3/mediabot.pl
BOT_CONF=/home/mediabot/mediabot_v3/mediabot.conf
```

### Undernet instance

```text
/etc/default/mediabot-undernet
```

```bash
BOT_DIR=/home/mediabot/mediabot3
BOT_BIN=/home/mediabot/mediabot3/mediabot.pl
BOT_CONF=/home/mediabot/mediabot3/mbundernet.conf
```

## Update and shutdown contract

The self-update command and systemd deliberately share a small lifecycle
contract:

```text
m update now
  -> deploy_update.sh is forked from the running bot
  -> the staged release is fully validated
  -> the old bot receives SIGTERM
  -> the updater remains alive in the same service cgroup
  -> config/brain are restored and the directory swap finishes
  -> the updater exits
  -> the cgroup becomes empty
  -> systemd starts the new release
```

`ExitType=cgroup` is important here: the main Perl process may exit before the
updater, but the service is not considered finished until the updater leaves
the cgroup. This removes any dependency on the directory swap completing
inside `RestartSec=`.

`Restart=always` is intentional. It also makes the service compatible with an
older Mediabot release whose SIGTERM handler exits with status 0 during an
update. Explicit bot shutdown remains available: the template exports
`MEDIABOT_SYSTEMD_UPDATE_SAFE=1`, so `die` and Partyline `.die` use exit status
**75**, which is listed in both `SuccessExitStatus=` and
`RestartPreventExitStatus=`. The first makes the explicit shutdown a clean
systemd termination; the second prevents `Restart=always` from starting it
again.

That environment marker is also a compatibility guard. If new Mediabot code is
started by an older template (or manually) the marker is absent, so `die`
keeps its historical exit status 0 instead of being misread as a failure by an
old `Restart=on-failure` unit.

An administrative stop remains an administrative stop:

```bash
systemctl stop mediabot@dev
```

systemd does not restart a service that it is explicitly stopping.

`ExitType=cgroup` was added in systemd 250. On older systemd releases the bot
can still be managed normally, but the IRC self-update path must not be relied
upon; update the code manually or upgrade systemd first. `deploy_update.sh`
checks the live service policy before it sends SIGTERM and fails closed when
the required update contract is not active.

After installing or changing the template on a host:

```bash
systemctl daemon-reload
systemctl restart mediabot@dev
```

For another instance, replace `dev` with its instance name.

## Useful commands

Start an instance:

```bash
systemctl start mediabot@dev
```

Stop an instance:

```bash
systemctl stop mediabot@dev
```

Restart an instance:

```bash
systemctl restart mediabot@dev
```

Check status:

```bash
systemctl status mediabot@dev --no-pager
```

Follow logs:

```bash
journalctl -u mediabot@dev -f
```

Enable at boot:

```bash
systemctl enable mediabot@dev
```

Disable at boot:

```bash
systemctl disable mediabot@dev
```

## Temporary pause

Stop an instance and restart it after 10 minutes:

```bash
systemctl stop mediabot@dev

systemd-run \
  --unit=mediabot-resume-dev \
  --on-active=10m \
  /bin/systemctl start mediabot@dev
```

List pending restart timers:

```bash
systemctl list-timers | grep mediabot
```

## Development helper

The repository may provide a convenience wrapper:

```text
tools/dev/mbctl
```

Examples:

```bash
tools/dev/mbctl dev status
tools/dev/mbctl dev restart
tools/dev/mbctl dev logs
tools/dev/mbctl undernet pause 10m
```

This helper only wraps `systemctl`, `journalctl` and `systemd-run`.

## ZNC / bouncer usage

systemd does not need to know whether Mediabot connects directly to an IRC server or through a bouncer such as ZNC.

Configure the IRC server, port, SSL, credentials and bouncer details in the Mediabot configuration file.
