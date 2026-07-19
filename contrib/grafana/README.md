# Mediabot Fleet Dream — Hourly Grafana dashboard

## File

```text
grafana_mediabot_fleet_dream_hourly.json
```

## Goal

A zero-panel-configuration Grafana dashboard for a fleet of Mediabot v3 instances.

It is built for quiet and medium IRC communities, so every activity chart uses a fixed one-hour window:

```promql
increase(metric[1h])
```

No per-minute noise. No empty-looking dashboard when the channel is alive but not constantly scrolling.

## Fleet model

The dashboard does not hard-code hosts, ports, IRC networks, channels or bot names.

Prometheus owns the fleet.

Each scraped Mediabot target should provide an `instance_name` label. The dashboard then groups by that label automatically.

Example:

```yaml
scrape_configs:
  - job_name: mediabot
    static_configs:
      - targets:
          - 127.0.0.1:9108
        labels:
          instance_name: teuk-dev

      - targets:
          - bot1.example.net:9108
        labels:
          instance_name: undernet

      - targets:
          - bot2.example.net:9108
        labels:
          instance_name: epiknet
```

## Import

1. Open Grafana.
2. Go to **Dashboards**.
3. Click **New**.
4. Click **Import**.
5. Upload `grafana_mediabot_fleet_dream_hourly.json`.
6. Select your Prometheus datasource if Grafana asks.
7. Import.

The dashboard uses a hidden datasource variable:

```text
DS_PROMETHEUS
```

That keeps the panels generic and import-friendly.

Grafana still needs an existing Prometheus datasource. A dashboard JSON cannot create the datasource itself.

## Default behavior

```text
time range: last 7 days
refresh:    1 minute
style:      dark
filters:    none visible
```

The dashboard shows the whole fleet by default.

## Sections

```text
Fleet Health
Community Activity
Command Center
URL & Media Intelligence
Games, Fun & Engagement
Safety & Operations
Fleet inventory / build info
```

## Main panels

```text
Bots Up
IRC Connected
DB Connected
Managed Channels
Known Users
Lines / hour
Commands / hour
URL catches / hour
Heartbeat by bot
Reconnects, DB errors and command errors / hour
Lines / hour by bot and channel
Top active channels — current hour
Joins / parts / nick changes per hour
Current nick count by channel
Public / private / partyline commands / hour
Top commands — current hour
URL previews / hour by type
Search and AI / hour
Games / hour
Social features / hour
Community analytics / hour
Flood and cooldown blocks / hour
Auth and partyline / hour
Admin operations / hour
Netsplits and bans / hour
Fleet inventory now
```

## Prometheus metrics expected

The dashboard uses Mediabot v3 metrics such as:

```text
mediabot_up
mediabot_irc_connected
mediabot_db_connected
mediabot_channels_managed
mediabot_users_known
mediabot_channel_lines_in_total
mediabot_commands_public_total
mediabot_commands_private_total
mediabot_commands_partyline_total
mediabot_channel_commands_total
mediabot_commands_by_name_total
mediabot_channel_commands_by_name_total
mediabot_urltitle_requests_total
mediabot_joins_total
mediabot_parts_total
mediabot_nick_changes_total
mediabot_channel_nick_count
mediabot_irc_reconnect_total
mediabot_db_query_errors_total
mediabot_command_errors_total
mediabot_trivia_questions_total
mediabot_poll_votes_total
mediabot_karma_votes_total
mediabot_mood_total
mediabot_duel_total
mediabot_compat_total
mediabot_achievements_unlocked_total
mediabot_antiflood_blocks_total
mediabot_auth_success_total
mediabot_auth_failure_total
mediabot_partyline_sessions_current
mediabot_rehash_total
mediabot_restart_total
mediabot_jump_total
mediabot_build_info
```

If a panel is empty, either the metric is not emitted yet, the corresponding feature has not been used, or Prometheus is not scraping that instance.

## Design choices

- Hourly windows everywhere for activity.
- No visible bot/channel variables.
- No channel hard-coding.
- No server hard-coding.
- No IRC network hard-coding.
- Chromium/URL, games, auth, partyline, flood guards and admin operations all visible.
- Designed to look good across several bots on different servers.

## Version

```text
Dashboard UID: mediabot-fleet-dream-hourly
```

## Script bridge (plugins) — grafana_mediabot_scriptbridge_v1.json

Dashboard for the external script bridge (mb540 metrics): runs by origin and
result, channel-event outcomes (including bursts absorbed by the anti-storm
cooldown), timer lifecycle and the armed-timers gauge. Import it and point
the DS_PROMETHEUS variable at the Prometheus instance that scrapes the bot's
metrics endpoint. Requires the bot's metrics system to be enabled; the
series appear after the ScriptDryRun plugin is loaded.
