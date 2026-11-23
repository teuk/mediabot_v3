import json
import sys

MAX_CHANNELS = 12
MAX_NOTE_BYTES = 120
IRC_CASEMAP = str.maketrans("[]\\^", "{}|~")
EMPTY_NOTE = "Aucune note pour ce canal."


def reply(text):
    return [{"type": "reply", "text": text}]


def note_actions(data):
    command = data["command"]
    args = data["args"]
    channel = data["channel"].lower().translate(IRC_CASEMAP)
    if len(channel) < 2 or channel[0] not in "#&+!" or len(channel) > 64:
        return reply("Utilise cette commande dans un canal IRC de 64 caractères maximum.")

    notes = data.get("storage", {})
    if command == "plirenote":
        if args:
            return reply("Usage : plirenote")
        note = notes.get(channel)
        return reply(f"Note du canal : {note}" if note else EMPTY_NOTE)

    if command == "pnote":
        note = " ".join(args).strip()
        if not note or len(note.encode("utf-8")) > MAX_NOTE_BYTES or not note.isprintable():
            return reply(f"Usage : pnote <texte de 1 à {MAX_NOTE_BYTES} octets UTF-8>")
        if channel not in notes and len(notes) >= MAX_CHANNELS:
            return reply("Le mémo a atteint sa limite de canaux.")
        notes[channel] = note
    elif command == "peffacenote":
        if args:
            return reply("Usage : peffacenote")
        if channel not in notes:
            return reply(EMPTY_NOTE)
        del notes[channel]
    else:
        return []

    return [{"type": "store", "data": notes}]


request = json.load(sys.stdin.buffer)
print(json.dumps({
    "protocol": "mediabot-script-v1",
    "ok": True,
    "actions": note_actions(request["data"]),
}))
