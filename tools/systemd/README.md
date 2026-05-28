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
User=mediabot
Group=mediabot

EnvironmentFile=/etc/default/mediabot-%i

WorkingDirectory=/
SyslogIdentifier=mediabot-%i

ExecStart=/bin/bash -lc 'cd "$BOT_DIR" && exec /usr/bin/stdbuf -oL -eL /usr/bin/perl "$BOT_BIN" --conf="$BOT_CONF"'

Restart=on-failure
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
