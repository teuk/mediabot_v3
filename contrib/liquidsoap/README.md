# Liquidsoap / Icecast2 radio sample for Mediabot v3

This directory contains sample files for running a small Icecast2 + Liquidsoap radio stack that can be controlled or inspected by Mediabot.

The original idea behind Mediabot radio support was simple:

```text
"now playing on the radio: <artist> - <song>"
```

Instead of flooding a dedicated radio channel, Mediabot can publish radio information only when the channel configuration allows it, for example with a channel setting such as `+RadioPub`.

## What this sample is for

This sample describes a practical radio setup with:

```text
- one global playlist, backed by a local .m3u file;
- one optional live input port for direct streaming;
- one request queue for tracks downloaded or selected by Mediabot;
- one Icecast2 output mount;
- one local Liquidsoap telnet control port.
```

The intended source priority is:

```text
live input > Mediabot/request queue > global playlist
```

That means:

1. if a live DJ/source is connected, Liquidsoap plays the live source;
2. otherwise, if Mediabot has queued a requested track, Liquidsoap plays it;
3. otherwise, Liquidsoap falls back to the global playlist.

## Repository files

Recommended repository layout:

```text
contrib/liquidsoap/
  README.md
  radio-8000.sample.liq
```

The sample file must not contain real passwords, real private hostnames, or production-only paths.

Use placeholders and copy the file locally before adapting it.

## Recommended local runtime layout

Example runtime directories:

```text
/var/lib/mediabot-radio/
  playlists/
    global.m3u
    jingles.m3u
  queue/
  music/

/var/log/liquidsoap/
```

Example playlist:

```text
/var/lib/mediabot-radio/playlists/global.m3u
```

The `.m3u` file should contain local audio file paths, for example:

```text
/var/lib/mediabot-radio/music/Artist - Song.mp3
/var/lib/mediabot-radio/music/Another Artist - Another Song.mp3
```

## Debian packages

Install the base packages:

```bash
sudo apt update
sudo apt install -y icecast2 liquidsoap yt-dlp curl jq
```

`yt-dlp` is used by Mediabot for request/download features such as `m play`.

## Icecast2

Icecast2 provides the public stream endpoint.

For a clean test instance, keep the configuration separate from any existing production radio service.

Example layout:

```text
Icecast2:
  config: /etc/icecast2/icecast-8000.xml
  port:   8000
  mount:  /radio.mp3
```

Useful checks:

```bash
curl -s http://127.0.0.1:8000/status-json.xsl | jq .
curl -s http://127.0.0.1:8000/status-json.xsl | jq '.icestats.source'
```

## Liquidsoap

Liquidsoap provides the automation logic:

```text
live input > request queue > playlist
```

Recommended ports for a clean test setup:

```text
Icecast output:        127.0.0.1:8000
Liquidsoap telnet:     127.0.0.1:1235
Liquidsoap live input: 18005
```

The live input port is intentionally not `8005` or `8006`, to avoid collisions with existing radio stacks.

Copy the sample:

```bash
sudo cp contrib/liquidsoap/radio-8000.sample.liq /etc/liquidsoap/radio-8000.liq
sudo chmod 640 /etc/liquidsoap/radio-8000.liq
```

Edit placeholders:

```bash
sudo vi /etc/liquidsoap/radio-8000.liq
```

At minimum, change:

```text
ICECAST_SOURCE_PASSWORD
LIVE_SOURCE_PASSWORD
stream name / description / url
playlist paths
```

## Mediabot configuration

In `mediabot.conf`, the radio section should point to the local paths and services used by this stack.

Example:

```ini
[radio]
YOUTUBEDL_INCOMING=/var/lib/mediabot-radio/queue
YTDLP_PATH=/usr/bin/yt-dlp

RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000
RADIO_ICECAST_PUBLIC_BASE_URL=http://example.com:8000
RADIO_ICECAST_TIMEOUT=5
RADIO_ICECAST_PRIMARY_MOUNT=/radio.mp3

LIQUIDSOAP_TELNET_HOST=127.0.0.1
LIQUIDSOAP_TELNET_PORT=1235
```

Do not commit real `mediabot.conf` files.

## Request queue concept

When a user runs something like:

```text
m play Radiohead No Surprises
```

the intended workflow is:

```text
1. Mediabot searches/downloads the requested track with yt-dlp.
2. The file is written under the configured incoming/queue directory.
3. Metadata is inserted or updated in the MP3 table.
4. Mediabot pushes the local file path into the Liquidsoap request queue.
5. Liquidsoap plays the queued track before falling back to the playlist.
```

The exact Mediabot command behavior depends on the current radio implementation and configuration.

## Starting Liquidsoap manually

Test manually first:

```bash
liquidsoap /etc/liquidsoap/radio-8000.liq
```

Check logs:

```bash
tail -f /var/log/liquidsoap/radio-8000.log
```

Check ports:

```bash
ss -lntp | egrep ':8000\b|:1235\b|:18005\b'
```

## systemd service example

A simple service can be created later, once manual startup works.

Example:

```ini
[Unit]
Description=Liquidsoap Mediabot Radio 8000
After=network-online.target icecast2.service
Wants=network-online.target

[Service]
Type=simple
User=liquidsoap
Group=liquidsoap
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/radio-8000.liq
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Install it as:

```text
/etc/systemd/system/liquidsoap-radio-8000.service
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now liquidsoap-radio-8000.service
sudo systemctl status liquidsoap-radio-8000.service --no-pager
journalctl -u liquidsoap-radio-8000.service -f
```

## Security notes

Do not expose the Liquidsoap telnet port publicly.

Recommended:

```text
server.telnet.bind_addr = 127.0.0.1
```

The live input port may be exposed only if needed. Use a strong source password and firewall it when possible.

Never commit:

```text
- real Icecast source passwords;
- real admin passwords;
- real private hostnames;
- production-only local paths;
- generated logs;
- downloaded media files.
```
