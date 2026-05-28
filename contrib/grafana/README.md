# Mediabot v3 Grafana dashboard — hourly import-friendly version

This directory contains an import-friendly Grafana dashboard for Mediabot v3 Prometheus metrics.

## Dashboard

Recommended file:

```text
grafana_mediabot_community_hourly_v3.json
```

## Why this version exists

The older dashboard displayed activity as per-minute rates. That is fine for a very active bot, but most IRC communities are quieter and the graphs can look almost empty.

This version uses hourly activity windows instead:

```promql
increase(metric[1h])
```

That makes low-to-medium activity easier to read.

## Import in Grafana

1. Open Grafana.
2. Go to **Dashboards**.
3. Click **New**.
4. Click **Import**.
5. Upload `grafana_mediabot_community_hourly_v3.json`.
6. Click **Import**.

The dashboard uses a hidden Prometheus datasource variable named:

```text
DS_PROMETHEUS
```

If your Grafana instance already has a Prometheus datasource, the dashboard should be usable without manual panel editing.

## Important limitation

Grafana still needs a Prometheus datasource to exist.

This dashboard can avoid per-panel configuration, but it cannot create the Prometheus datasource by itself.

## Multi-instance support

The dashboard supports multiple Mediabot instances through the `instance_name` label.

Only instances with metrics enabled and scraped by Prometheus will appear in Grafana.

## Prometheus scrape example

Each metrics-enabled instance should expose a metrics endpoint and be scraped by Prometheus.

Example scrape config:

```yaml
scrape_configs:
  - job_name: mediabot
    static_configs:
      - targets:
          - 127.0.0.1:9108
        labels:
          instance_name: teuk-dev

      - targets:
          - mediabot.mydomain1.com:9108
        labels:
          instance_name: mediabot1

      - targets:
          - mediabot.mydomain2.com:9108
        labels:
          instance_name: mediabot2
```

Adapt ports, hosts and firewall rules to your real setup.

## Recommended dashboard time range

This dashboard defaults to:

```text
Last 7 days
```

Refresh interval:

```text
1 minute
```

This is more appropriate for quiet IRC activity than a fast 15-second dashboard refresh.

## Main panels

The dashboard includes:

```text
- Bot up / IRC connected / DB connected
- Managed channels
- Uptime
- Lines per hour
- Commands per hour
- Lines per hour by bot and channel
- Commands per hour by bot and channel
- Top commands by bot/channel over selected range
- Global top commands over selected range
- Operations over selected range
- Auth / Partyline activity
- Build info
```

## Notes

The dashboard is intentionally generic.

It should not assume that every Mediabot instance runs on the same server, the same directory, or the same IRC network.

Grafana only sees what Prometheus scrapes.
