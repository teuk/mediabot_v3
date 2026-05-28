# Legacy Mediabot helpers

This directory contains old root-level helper scripts kept temporarily for reference.

These scripts are no longer the recommended way to run Mediabot v3.

## Recommended method

Mediabot v3 should preferably be managed through systemd.

Typical commands:

```bash
systemctl start mediabot@dev
systemctl stop mediabot@dev
systemctl restart mediabot@dev
systemctl status mediabot@dev --no-pager
journalctl -u mediabot@dev -f
```

For another instance:

```bash
systemctl restart mediabot@undernet
journalctl -u mediabot@undernet -f
```

## Convenience helper

For day-to-day development, use:

```bash
tools/dev/mbctl dev status
tools/dev/mbctl dev restart
tools/dev/mbctl dev logs
tools/dev/mbctl undernet status
tools/dev/mbctl undernet pause 10m
```

## Legacy scripts

The old scripts may include:

```text
start.legacy
stop.legacy
daemon.legacy
check_alive_cron_script.sh.legacy
```

They are kept only to preserve the old workflow during the transition.

Do not use them as the preferred production supervisor.

## Cron watchdog

The old cron watchdog approach is discouraged for normal usage.

systemd is now preferred because it provides:

```text
- automatic restart on failure
- journalctl logging
- restart-loop protection
- cleaner stop/start/restart behavior
- better multi-instance management
```

A cron watchdog may still be useful as a last-resort legacy fallback, but it should not be the default method.

## Multi-instance note

A Mediabot instance is usually defined by:

```text
- its project directory
- its configuration file
- its systemd instance name
```

Example layout:

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

## ZNC / bouncer usage

systemd does not need to know whether Mediabot connects directly to an IRC server or through a bouncer such as ZNC.

Configure the IRC server, port, SSL, credentials and bouncer details in the Mediabot configuration file.
