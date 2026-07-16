#!/usr/bin/env python3
# =============================================================================
# countdown.py — Mediabot v3 reference plugin script (mediabot-script-v1).
#
# The PYTHON reference for TIMER actions and per-route configuration, routed
# as `pcountdown` in the sample configuration (the Perl counterpart is
# examples/remind.pl):
#
#   pcountdown 60 pizza         -> announces a countdown, pings 60s later
#   pcountdown 10               -> a plain 10-second countdown
#
# Timer lifecycle demonstrated here (identical to the Perl reference — the
# protocol is language-neutral):
#   1. event "public_command": validate, then emit a reply (announcement) AND
#      a timer action {"type": "timer", "name": "countdown_<nick>", "delay": N};
#   2. when the timer expires the bridge re-runs this SAME script with event
#      "timer" and the ORIGINAL data (channel/nick/command/args + timer_name/
#      timer_delay) — the label is rebuilt from the original args;
#   3. event "timer": announce the end. Never emit another timer here (the
#      bridge rejects timer chains anyway).
#
# Per-route configuration (mb531): CONFIG_pcountdown=max_seconds=600 lowers
# the accepted ceiling for this route. Configuration may only TIGHTEN the
# protocol bounds (1..3600); bad values fall back to the protocol default.
#
# Bridge guardrails (enforced upstream): delay bounded 1..3600, timer names
# [A-Za-z0-9_.-] max 64, one pending timer per name (so one countdown per
# nick here), no chains. Dependency-free (standard library only).
# =============================================================================

import json
import re
import sys

PROTOCOL = "mediabot-script-v1"
MIN_SECONDS = 1
MAX_SECONDS = 3600
MAX_LABEL = 200


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    event = payload.get("event")
    if not isinstance(event, str):
        event = "unknown"
    data = payload.get("data")
    if not isinstance(data, dict):
        data = {}

    nick = data.get("nick")
    if not isinstance(nick, str) or not nick:
        nick = "someone"
    command = data.get("command")
    if not isinstance(command, str) or not command:
        command = "countdown"
    args = data.get("args")
    if not isinstance(args, list):
        args = []
    args = [a for a in args if isinstance(a, str)]

    # Per-route configuration: the ceiling may only tighten protocol bounds.
    config = data.get("config")
    if not isinstance(config, dict):
        config = {}
    max_seconds = MAX_SECONDS
    raw_ceiling = config.get("max_seconds")
    if isinstance(raw_ceiling, str) and raw_ceiling.isdigit():
        configured = int(raw_ceiling)
        if MIN_SECONDS <= configured <= MAX_SECONDS:
            max_seconds = configured

    # Rebuild the label from the original args (works for both runs: the
    # deferred "timer" event receives the original args again).
    label = " ".join(args[1:]).strip()[:MAX_LABEL]

    actions = []

    if event == "timer":
        shown = label if label else "countdown"
        actions.append({"type": "reply", "text": f"{nick}: time! {shown} is up"})
        actions.append({"type": "log", "level": "info",
                        "text": f"countdown: finished for {nick}"})
    else:
        seconds = 0
        if args and re.fullmatch(r"[0-9]+", args[0] or ""):
            seconds = int(args[0])

        if seconds < MIN_SECONDS or seconds > max_seconds:
            actions.append({
                "type": "reply",
                "text": (f"{nick}: usage: {command} <seconds 1-{max_seconds}>"
                         f" [label], e.g. {command} 60 pizza"),
            })
        else:
            safe_nick = re.sub(r"[^A-Za-z0-9_.-]", "_", nick)
            timer_name = ("countdown_" + safe_nick)[:64]
            shown = label if label else "countdown"
            actions.append({"type": "reply",
                            "text": f"{nick}: {shown}: {seconds}s, starting now"})
            actions.append({"type": "timer", "name": timer_name, "delay": seconds})
            actions.append({"type": "log", "level": "info",
                            "text": f"countdown: armed {timer_name} delay={seconds}s"})

    json.dump({"protocol": PROTOCOL, "ok": True, "actions": actions}, sys.stdout)


if __name__ == "__main__":
    main()
