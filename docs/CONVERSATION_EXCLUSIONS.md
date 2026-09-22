# Channel conversation exclusions

Mediabot has one central boundary for automation that must be ignored by the
entire public interaction pipeline. The boundary runs after the ordinary IRC
ignore check and before user-seen updates, achievements, reminders, trivia,
quote games, Wit/Quip, Spark/SparkAction, Hailo, responders, command dispatch
and URL previews.

It is deliberately different from `main.BOT_NICKS`. That older global list
keeps visible automation out of human audience counts while still allowing it
to create bot pressure. A channel conversation exclusion drops the line from
all interactive processing.

## Configuration

The private configuration accepts two reloadable keys:

```ini
[conversation]
CHANNEL_BOTS=radiocapsule:Balibalo+mediacaps+WarHawk
CHANNEL_COMMANDS=
```

Channel names omit the leading `#`. Separate channels with `|` and separate
items with `+`. Nick matching is case-insensitive under the IRC RFC1459
casemap. Invalid or oversized entries are ignored within fixed parser bounds.

`CHANNEL_BOTS` drops:

- every public line sent by a declared bot on that channel;
- a human line whose first token directly addresses that bot, including
  `Coin: ...`, `Coin, ...`, `@Coin ...` and `Coin ...`.

It does not drop a later ordinary-language occurrence. For example,
`on se retrouve dans un coin tranquille` remains a human line.

`CHANNEL_COMMANDS` contains exact, prefixed command words belonging to an
external bot. It neither accepts wildcards nor consumes a different command.
For the current pyDuckHunt public command set on production `#i/o`:

```ini
[conversation]
CHANNEL_BOTS=i/o:Coin
CHANNEL_COMMANDS=i/o:!bang+!pan+!reload+!shop+!inventory+!duckstats+!lastduck+!duckrank
```

Thus `!bang vite` is ignored by Mediabot, while `#quote`, `!helpful` and normal
conversation continue through their existing paths. The command list is an
explicit operational contract and must be reviewed if pyDuckHunt adds or
renames public commands.

## Runtime and observation

The configuration object is re-read through a bounded signature, so the normal
configuration reload path applies changes without retaining a stale compiled
map. Invalid configuration fails open and emits a sanitized error; it cannot
take the IRC callback down.

Excluded lines retain the existing optional `[LIVE]` record and incoming-line
count, then stop. A payload-free diagnostic records only channel, sender and
one fixed reason:

```text
[CONVERSATION_IGNORE] channel=#i/o action=drop reason=bot_command nick=player
```

`mediabot_conversation_excluded_total{reason=...}` uses exactly
`declared_bot`, `bot_address` or `bot_command`. Message text is never a metric
label or exclusion diagnostic field.

## Rollout

Development first:

```ini
[conversation]
CHANNEL_BOTS=radiocapsule:Balibalo+mediacaps+WarHawk
CHANNEL_COMMANDS=
```

Confirm that the three senders produce exclusion diagnostics and cannot affect
Wit, Quip, Spark, SparkAction or Hailo, while a normal user line still reaches
the usual pipeline. Only after that evidence is accepted should the `#i/o`
configuration above be installed on the `nbot` instance. Removing the two
values and reloading is the immediate rollback; no schema or channel policy is
changed.
