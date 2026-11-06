# MB1126 — Karma shorthand

In ordinary chat on a registered channel, `Bob++` adds one point and
`Bob--` removes one. The full nick must appear in the channel's current
nicklist, regardless of letter case. The shortcut never infers a target
by dropping a nick decoration, and silently skips absent names.

Both syntaxes share the existing cooldown, self-vote and brigade checks,
storage, history and watcher notifications. The three-vote limit per
message remains. Explicit `!karma + Bob` and `!karma - Bob` keep their
existing behavior. Private messages, commands, link previews, CTCP
messages and known bot output do not trigger shorthand votes.

PART/KICK/QUIT removal clears matching nicks from current and buffered
NAMES lists. On the bot's own JOIN, any old list for that channel is
discarded; subsequent membership updates make the nick eligible again.
No configuration or database migration is needed.
