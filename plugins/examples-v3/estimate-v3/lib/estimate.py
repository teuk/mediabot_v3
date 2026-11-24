import json
import re
import sys

MAX_TASKS = 100
USAGE = f"Usage : v3estime <1 à {MAX_TASKS} tâches>"


def estimate(data):
    args = data["args"]
    if len(args) != 1 or not re.fullmatch(r"[1-9][0-9]{0,2}", args[0]):
        return USAGE

    tasks = int(args[0])
    if tasks > MAX_TASKS:
        return USAGE

    minutes = data["config"]["minutes_per_task"]
    unit = "tâche" if tasks == 1 else "tâches"
    return f"{tasks} {unit} : {tasks * minutes} min ({minutes} min par tâche)."


request = json.load(sys.stdin.buffer)
print(json.dumps({
    "protocol": "mediabot-script-v1",
    "ok": True,
    "actions": [{"type": "reply", "text": estimate(request["data"])}],
}))
