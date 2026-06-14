#!/usr/bin/env python3
# mb181-B1: example external Python script for the Mediabot ScriptRunner protocol.

import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

data = payload.get("data", {})
command = data.get("command") or "unknown"
nick = data.get("nick") or "unknown"

print(json.dumps({
    "actions": [
        {
            "type": "reply",
            "text": "Python script bridge OK for command: " + command,
        },
        {
            "type": "log",
            "level": "info",
            "text": "Python example script produced a dry-run action plan",
        },
    ]
}))
