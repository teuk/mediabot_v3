#!/usr/bin/env python3
# =============================================================================
# coin.py — Mediabot v3 plugin-v2 example script (mediabot-script-v1), Python.
#
# Declared by its sidecar (coin.py.manifest.json), mounted with:
#
#   .plugins loadscript examples-v2/coin.py            (partyline, Owner)
#
#   coin        -> flips one coin
#   coin 5      -> flips up to 10 coins (anti-abuse cap, cookbook pattern 3)
#
# Same mediabot-script-v1 body as examples/: envelope on STDIN, explicit
# ok + protocol, reply/log actions, the json module does the escaping.
# =============================================================================

import json
import random
import sys

try:
    env = json.load(sys.stdin)
except Exception:
    env = {}

data = env.get("data") if isinstance(env.get("data"), dict) else {}
args = data.get("args") if isinstance(data.get("args"), list) else []

count = 1
if args:
    try:
        count = int(str(args[0]))
    except (TypeError, ValueError):
        count = 1
count = max(1, min(count, 10))  # anti-abuse cap: never more than 10 flips

flips = [random.choice(["heads", "tails"]) for _ in range(count)]
if count == 1:
    text = "The coin lands on... %s!" % flips[0]
else:
    text = "%d flips: %s (%d heads / %d tails)" % (
        count, ", ".join(flips),
        flips.count("heads"), flips.count("tails"))

print(json.dumps({
    "ok": True,
    "protocol": "mediabot-script-v1",
    "actions": [
        {"type": "reply", "text": text},
        {"type": "log", "level": 3, "text": "coin.py flipped %d coin(s)" % count},
    ],
}))
