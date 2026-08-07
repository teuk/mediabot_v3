#!/usr/bin/env python3
# =============================================================================
# karma.py — Mediabot v3 plugin-v2 STORAGE example (mediabot-script-v1).
#
# The mb601 showcase, and the example the cookbook long declared impossible:
# a plugin WITH state. The script still never touches the filesystem — it
# asks, and the bot writes:
#
#   .plugins loadscript examples-v2/karma.py           (partyline, Owner)
#
#   thanks SlaY   -> "SlaY now has 4 karma."   (self-thanks refused)
#   karma SlaY    -> "SlaY has 4 karma."
#   karma         -> the top three
#
# The current document arrives in the envelope as data.storage, read fresh
# at every dispatch; a "store" action hands the WHOLE new document back to
# the bot (read-modify-write is yours, cookbook pattern 8). One store per
# run, and the bot enforces the bounds — this script stays well inside
# them on purpose, see the pruning below.
# =============================================================================

import json
import sys

# The bot allows 256 keys; a channel gathers nicks forever, so keep our own
# ceiling well under it and drop the quietest entries when we reach it.
# A plugin that needs more than a notebook wants a database.
MAX_TRACKED = 200

try:
    env = json.load(sys.stdin)
except Exception:
    env = {}


def fail(reason):
    print(json.dumps({"ok": False, "protocol": "mediabot-script-v1",
                      "error": reason}))
    sys.exit(0)


def emit(actions):
    print(json.dumps({"ok": True, "protocol": "mediabot-script-v1",
                      "actions": actions}))
    sys.exit(0)


data = env.get("data") if isinstance(env.get("data"), dict) else {}
command = str(data.get("command") or "")
nick = str(data.get("nick") or "")
args = data.get("args") if isinstance(data.get("args"), list) else []

# data.storage is the document the bot holds for THIS plugin. Absent on the
# very first run — treat a missing or damaged shape as an empty notebook.
storage = data.get("storage") if isinstance(data.get("storage"), dict) else {}
scores = storage.get("scores") if isinstance(storage.get("scores"), dict) else {}
scores = {str(k): int(v) for k, v in scores.items()
          if isinstance(v, (int, float)) and not isinstance(v, bool)}

target = str(args[0]).lstrip("@") if args else ""
target = target[:30]

if command == "thanks":
    if not target:
        emit([{"type": "reply", "text": "Usage: thanks <nick>"}])
    if target.lower() == nick.lower():
        # Anti-abuse, cookbook pattern 3: no self-service karma.
        emit([{"type": "reply",
               "text": "%s, thanking yourself is not how this works." % nick}])

    key = target.lower()
    scores[key] = scores.get(key, 0) + 1

    # Stay under our own ceiling: drop the lowest scores (ties broken by
    # name) rather than letting the document grow until the bot refuses it.
    if len(scores) > MAX_TRACKED:
        keep = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))[:MAX_TRACKED]
        kept = dict(keep)
        if key not in kept:
            # The just-thanked nick must survive, but the cap must remain exact.
            # Replace the quietest retained entry instead of adding a 201st key.
            kept.pop(keep[-1][0], None)
            kept[key] = scores[key]
        scores = kept

    emit([
        {"type": "store", "data": {"scores": scores}},
        {"type": "reply", "text": "%s now has %d karma." % (target, scores[key])},
    ])

# 'karma' with a nick reports one score, without arguments the podium.
if target:
    score = scores.get(target.lower(), 0)
    emit([{"type": "reply", "text": "%s has %d karma." % (target, score)}])

if not scores:
    emit([{"type": "reply", "text": "No karma yet. Try: thanks <nick>"}])

top = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
emit([{"type": "reply", "text": "Top karma: " +
       ", ".join("%s (%d)" % (name, value) for name, value in top)}])
