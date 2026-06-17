#!/usr/bin/env python3
# =============================================================================
# roll.py — Mediabot v3 reference plugin script (mediabot-script-v1)
#
# A useful example beyond hello-world: a dice roller that can be routed under
# any command token. The sample configuration uses `proll` so Mediabot's richer
# built-in `roll` command and its history subcommand remain available.
#
#   proll              -> rolls 1d6
#   proll 2d6          -> rolls two six-sided dice
#   proll d20+3        -> rolls one d20 and adds 3
#   proll 4d8-2        -> rolls four d8 and subtracts 2
#
# It shows everything a real plugin script needs:
#   - read the mediabot-script-v1 JSON envelope on STDIN;
#   - take the command arguments (the dice spec);
#   - validate input strictly with anti-abuse limits (no huge rolls);
#   - on bad input, reply with a friendly usage line (never crash the bridge);
#   - emit an explicit `ok` + `protocol` and a `reply` action (no target, so it
#     defaults to the originating channel) plus a `log` action.
#
# Dependency-free (standard library only). The repository test suite validates
# it through the real ScriptRunner/ScriptActionRunner bridge.
# =============================================================================

import json
import random
import re
import sys

PROTOCOL = "mediabot-script-v1"

# Anti-abuse limits: keep replies short and the host safe.
MAX_DICE = 100
MAX_SIDES = 1000
MAX_SHOWN = 20          # how many individual dice to list before summarizing
MAX_MODIFIER = 1_000_000

SPEC_RE = re.compile(
    r"""^\s*
        (?P<count>\d+)?            # optional number of dice (default 1)
        d
        (?P<sides>\d+)             # sides per die
        (?:\s*(?P<mod>[+-]\s*\d+))?  # optional +K / -K modifier
        \s*$""",
    re.IGNORECASE | re.VERBOSE,
)



def read_payload():
    try:
        raw = sys.stdin.read()
        return json.loads(raw or "{}")
    except Exception:
        return {}


def command_name(data):
    value = data.get("command") if isinstance(data, dict) else None
    return value if isinstance(value, str) and value else "roll"


def usage(command):
    return (f"usage: {command} NdM[+/-K]  "
            f"e.g. {command} 2d6, {command} d20+3, {command} 4d8-2")


def first_arg(data):
    """Return the dice spec: prefer args[0], else the rest of the message."""
    args = data.get("args")
    if isinstance(args, list) and args:
        first = args[0]
        if isinstance(first, str) and first.strip():
            return first.strip()
    return ""


def parse_spec(spec):
    """Parse 'NdM(+/-K)'. Return (count, sides, modifier) or None if invalid."""
    if not spec:
        return (1, 6, 0)  # bare routed command -> 1d6
    m = SPEC_RE.match(spec)
    if not m:
        return None
    count = int(m.group("count")) if m.group("count") else 1
    sides = int(m.group("sides"))
    mod = 0
    if m.group("mod"):
        mod = int(re.sub(r"\s+", "", m.group("mod")))
    if not (1 <= count <= MAX_DICE):
        return None
    if not (1 <= sides <= MAX_SIDES):
        return None
    if abs(mod) > MAX_MODIFIER:
        return None
    return (count, sides, mod)


def render(nick, spec, count, sides, mod):
    rolls = [random.randint(1, sides) for _ in range(count)]
    total = sum(rolls) + mod

    if len(rolls) <= MAX_SHOWN:
        shown = "[" + ", ".join(str(r) for r in rolls) + "]"
    else:
        shown = "[" + ", ".join(str(r) for r in rolls[:MAX_SHOWN]) + ", …]"

    label = spec if spec else f"{count}d{sides}"
    mod_str = ""
    if mod > 0:
        mod_str = f" +{mod}"
    elif mod < 0:
        mod_str = f" {mod}"

    who = nick if nick else "someone"
    return f"{who} rolled {label} → {shown}{mod_str} = {total}"


def main():
    payload = read_payload()
    data = payload.get("data", {}) if isinstance(payload, dict) else {}
    nick = data.get("nick") or ""
    command = command_name(data)
    spec = first_arg(data)

    parsed = parse_spec(spec)
    if parsed is None:
        hint = usage(command)
        text = f"{nick}: {hint}" if nick else hint
        actions = [{"type": "reply", "text": text}]
    else:
        count, sides, mod = parsed
        text = render(nick, spec, count, sides, mod)
        actions = [
            {"type": "reply", "text": text},
            {"type": "log", "level": "info",
             "text": f"roll plugin: {nick or 'someone'} rolled {spec or '1d6'}"},
        ]

    print(json.dumps({
        "protocol": PROTOCOL,
        "ok": True,
        "actions": actions,
    }))


if __name__ == "__main__":
    main()
