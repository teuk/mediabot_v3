#!/usr/bin/env python3
"""Minimal Python reference script for the mediabot-script-v1 protocol.

The bridge configuration decides whether returned actions are only planned or
actually applied. External scripts only read the JSON envelope from STDIN and
return a JSON result on STDOUT.
"""

import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

if not isinstance(payload, dict):
    payload = {}

data = payload.get("data")
if not isinstance(data, dict):
    data = {}

command = data.get("command")
if not isinstance(command, str) or not command:
    command = "unknown"

print(json.dumps({
    "protocol": "mediabot-script-v1",
    "ok": True,
    "actions": [
        {
            "type": "reply",
            "text": "Python script bridge OK for command: " + command,
        },
        {
            "type": "log",
            "level": "info",
            "text": "Python example script produced an action plan",
        },
    ],
}))
