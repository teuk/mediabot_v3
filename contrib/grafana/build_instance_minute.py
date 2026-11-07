#!/usr/bin/env python3
"""Build the single-instance Mediabot Grafana dashboard with no dependencies."""
import argparse
import json
from pathlib import Path

FILE = Path(__file__).with_name("grafana_mediabot_instance_minute.json")
DATASOURCE = {"type": "prometheus", "uid": "${DS_PROMETHEUS}"}
SELECT = 'job=~"${job:regex}",instance=~"${instance:regex}"'
WINDOW = "5m"
COLORS = {"read": "#2DD4BF", "sent": "#60A5FA", "commands": "#A78BFA", "links": "#FBBF24"}

COUNTERS = {
    "read": ("Messages lus", "mediabot_channel_lines_in_total", "Lignes publiques comptées par Mediabot dans ses salons."),
    "sent": ("Messages envoyés", "mediabot_privmsg_out_total", "Messages IRC envoyés par le bot, en salon ou en privé. Les notices sont exclues."),
    "commands": ("Commandes publiques", "mediabot_commands_public_total", "Commandes IRC publiques comptabilisées par le bot."),
    "links": ("Analyses de liens", "mediabot_urltitle_requests_total", "Demandes d’analyse de liens détectées. Le compteur ne mesure pas les aperçus réussis."),
}


def selector(metric):
    return f"{metric}{{{SELECT}}}"


HEALTH = f"max({selector('up')})"
HEALTHY = f"({HEALTH} == 1)"


def rate(metric, window=WINDOW):
    series = selector(metric)
    # rate() needs two samples. Only synthesize zero for a not-yet-emitted
    # counter on a live, identified Mediabot; preserve missing single-sample rates.
    quiet = f"(0 * {HEALTHY} and on() {selector('mediabot_build_info')} unless on() {series})"
    return f"(60 * sum(rate({series}[{window}])) or on() {quiet}) and on() {HEALTHY}"


def gauge(metric):
    return f"max({selector(metric)}) and on() {HEALTHY}"


def ranked(metric, label):
    return (f"sort_desc(topk(6, 60 * sum by ({label}) (rate({selector(metric)}[15m])) > 0))"
            f" and on() {HEALTHY}")


def target(expr, name, ref, instant=True):
    return {
        "refId": ref, "datasource": DATASOURCE, "expr": expr, "legendFormat": name,
        "editorMode": "code", "format": "time_series", "instant": instant, "range": not instant,
    }


def field(color=None, unit="none", decimals=None):
    result = {"unit": unit, "noValue": "—"}
    if color:
        result["color"] = {"mode": "fixed", "fixedColor": color}
    if decimals is not None:
        result["decimals"] = decimals
    return result


def panel(id_, kind, title, x, y, w, h, **extra):
    return {
        "id": id_, "type": kind, "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h}, **extra,
    }


def note(id_, y, h, content):
    return panel(id_, "text", "", 0, y, 24, h, transparent=True,
                 options={"mode": "markdown", "content": content})


def stat(id_, x, y, title, expr, description, fields):
    return panel(id_, "stat", title, x, y, 6, 4, description=description,
                 datasource=DATASOURCE, targets=[target(expr, title, "A")],
                 fieldConfig={"defaults": fields, "overrides": []},
                 options={"colorMode": "value", "graphMode": "none", "justifyMode": "center",
                          "textMode": "value", "reduceOptions": {"values": False, "calcs": ["last"]}})


def state_fields(up, down):
    return {
        **field(),
        "color": {"mode": "thresholds"},
        "mappings": [{"type": "value", "options": {
            "0": {"text": down, "color": "red", "index": 0},
            "1": {"text": up, "color": "green", "index": 1},
            "-1": {"text": "Non mesuré", "color": "gray", "index": 2},
        }}],
        "thresholds": {"mode": "absolute", "steps": [
            {"color": "red", "value": None}, {"color": "green", "value": 1},
        ]},
    }


def chart(id_, x, title, keys):
    names = [COUNTERS[k][0] for k in keys]
    series = [target(rate(COUNTERS[k][1]), n, ref, False)
              for k, n, ref in zip(keys, names, ("A", "B"))]
    return panel(id_, "timeseries", title, x, 14, 12, 8,
                 description="Rythme par minute, calculé sur cinq minutes glissantes. Un trou indique que la collecte ne permet pas de calculer le rythme.",
                 datasource=DATASOURCE, targets=series,
                 fieldConfig={
                     "defaults": {
                         **field(unit="suffix: /min", decimals=2),
                         "min": 0,
                         "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 13,
                                    "showPoints": "never", "spanNulls": False, "axisLabel": "/min",
                                    "lineInterpolation": "linear", "thresholdsStyle": {"mode": "off"}},
                     },
                     "overrides": [
                         {"matcher": {"id": "byName", "options": n},
                          "properties": [{"id": "color", "value": field(COLORS[k])["color"]}]}
                         for k, n in zip(keys, names)
                     ],
                 },
                 options={"legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"},
                          "tooltip": {"mode": "multi", "sort": "desc"}})


def ranking(id_, x, title, description, metric, label, color):
    return panel(id_, "bargauge", title, x, 24, 12, 8, description=description,
                 datasource=DATASOURCE, targets=[target(ranked(metric, label), "{{" + label + "}}", "A")],
                 fieldConfig={"defaults": {**field(color, "suffix: /min", 2), "min": 0},
                              "overrides": []},
                 options={"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True,
                          "namePlacement": "left", "valueMode": "color",
                          "reduceOptions": {"calcs": ["last"], "values": False}})


def build():
    db = f"(max({selector('mediabot_db_up')}) or on() max({selector('mediabot_db_connected')})) and on() {HEALTHY}"
    panels = [
        note(1, 0, 3, "## Mediabot · En direct\nUne instance, son état et son activité récente. **/min** = rythme moyen ; **—** = mesure indisponible."),
        stat(2, 0, 3, "Collecte des statistiques", f"{HEALTH} or on() vector(-1)", "Prometheus arrive à lire les métriques de l’instance.",
             state_fields("Disponible", "Interrompue")),
        stat(3, 6, 3, "Connexion IRC", f"({gauge('mediabot_irc_connected')}) or on() vector(-1)", "Le bot est connecté au réseau IRC.",
             state_fields("Connecté", "Déconnecté")),
        stat(4, 12, 3, "Base du bot", f"({db}) or on() vector(-1)", "Dernier état connu de la connexion à la base de Mediabot.",
             state_fields("Disponible", "Indisponible")),
        stat(5, 18, 3, "Salons rejoints", gauge("mediabot_current_channels"), "Nombre de salons IRC rejoints actuellement.", field("#94A3B8", decimals=0)),
        note(6, 7, 2, "### Activité par minute\nMoyenne sur **5 minutes**, pour que les petits échanges restent lisibles."),
    ]
    for i, key in enumerate(("read", "commands", "links", "sent")):
        name, metric, help_ = COUNTERS[key]
        panels.append(stat(7+i, i*6, 9, name, rate(metric), help_, field(COLORS[key], "suffix: /min", 2)))
    panels.extend([
        chart(11, 0, "Conversations · lu et envoyé", ("read", "sent")),
        chart(12, 12, "Interactions · commandes et liens", ("commands", "links")),
        note(13, 22, 2, "### Ce qui s’anime · 15 dernières minutes"),
        ranking(14, 0, "Salons les plus actifs", "Jusqu’à six salons avec une activité mesurée. Les noms de salons proviennent du bot ; aucun contenu de message.",
                "mediabot_channel_lines_in_total", "channel", COLORS["read"]),
        ranking(15, 12, "Commandes publiques les plus utilisées", "Jusqu’à six commandes publiques avec une activité mesurée. Seul leur nom est affiché.",
                "mediabot_channel_commands_by_name_total", "command", COLORS["commands"]),
        note(16, 32, 2, "**Comment lire le tableau :** 0,20/min correspond à environ une action toutes les cinq minutes. Un classement vide signifie qu’aucune hausse n’a été mesurée, ou que la collecte est interrompue."),
    ])
    return {
        "id": None, "uid": "mediabot-instance-minute", "title": "Mediabot · En direct",
        "description": "Une seule instance Mediabot : état du bot, rythme des conversations, commandes publiques et analyses de liens.",
        "tags": ["mediabot", "irc", "instance"], "schemaVersion": 41,
        "version": 1, "editable": True, "timezone": "browser", "style": "dark",
        "time": {"from": "now-6h", "to": "now"}, "refresh": "30s",
        "timepicker": {"refresh_intervals": ["30s", "1m", "5m"],
                       "time_options": ["15m", "1h", "6h", "12h", "24h", "7d"]},
        "annotations": {"list": []}, "links": [], "panels": panels,
        "templating": {"list": [
            {"name": "DS_PROMETHEUS", "label": "Source Prometheus", "type": "datasource", "query": "prometheus",
             "current": {}, "options": [], "refresh": 1, "hide": 0, "multi": False, "includeAll": False},
            {"name": "job", "label": "Collecte", "type": "query", "datasource": DATASOURCE,
             "query": "label_values(mediabot_up, job)", "definition": "label_values(mediabot_up, job)",
             "current": {}, "options": [], "refresh": 1, "hide": 0, "multi": False, "includeAll": False},
            {"name": "instance", "label": "Instance", "type": "query", "datasource": DATASOURCE,
             "query": 'label_values(mediabot_up{job=~"${job:regex}"}, instance)',
             "definition": 'label_values(mediabot_up{job=~"${job:regex}"}, instance)',
             "current": {}, "options": [], "refresh": 1, "hide": 0, "multi": False, "includeAll": False},
        ]},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check the committed JSON without writing")
    args = parser.parse_args()
    payload = (json.dumps(build(), ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if args.check:
        if not FILE.is_file() or FILE.read_bytes() != payload:
            parser.exit(1, f"{FILE.name} differs; run the generator without --check.\n")
    else:
        FILE.write_bytes(payload)
