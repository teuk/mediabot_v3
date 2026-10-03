# Automatic channel quotes

MB813 restores `+RandomQuote` periodic announcements and adds a separate
frequency setting for each registered channel. Previously the RandomQuote
block ran at file scope once, outside the timer, and quote selection could
exclude anonymous authors while still counting them.

## Commands

Examples use the public `!` prefix. If your bot's prefix is `m`, use
`m randomquote #test every 60m`, for example. Commands also work from the
console channel by specifying the target channel first.

```text
!chanset #test +RandomQuote
!randomquote #test every 60m
!randomquote #test
!randomquote #test status
!randomquote #test default
!chanset #test -RandomQuote
```

| Form | Effect |
| --- | --- |
| `!randomquote #test every 60m` | One attempt every hour on #test |
| `!randomquote #test every 2h` | One attempt every two hours |
| `!randomquote #test every 1d` | One attempt every day |
| `!randomquote #test 90` | Shorthand: 90 minutes |
| `!randomquote #test` or `status` | Inspect activation, frequency, quote count and next attempt |
| `!randomquote #test default` | Remove the channel override and follow the instance default |
| `!chanset #test -RandomQuote` | Pause announcements |

On the target channel, `!randomquote every 60m` uses that channel. In a private
message, specify the channel: `/msg mediabot randomquote #test every 60m`.
Setting the frequency does **not** enable the flag or make the bot JOIN.
All randomquote command responses are ordinary private NOTICEs to the caller.
Authentication plus Administrator (or higher), or channel level 450 on the
**target** channel, is required for reading and changing the setting. Rights
on the console alone do not authorize changes on another channel.

## Frequency and delivery

Durations accept integer `m`, `h` or `d` units, or bare integer minutes, from
**15 minutes to seven days**. There is no `now` command or catch-up mode.
The default is `main.RANDOM_QUOTE` in seconds, when it is a valid integer in
900..604800; otherwise the default is **three hours**. No private configuration
file needs editing to use the per-channel command.

The scheduler checks every 30 seconds. A channel first observed enabled and
joined waits one full interval. Changing its frequency starts a new full
interval and invalidates a pending old reply. Repeating the same setting
does not postpone an existing deadline. A persisted overdue deadline can
produce one attempt after reconnect or restart, then the next deadline starts
from the current time. Missed intervals are never replayed.

Each attempt reserves the next deadline before selecting a quote. Empty
channels, worker errors and rejected sends stay quiet until the next interval.
Automatic delivery uses one normal PRIVMSG, sanitized and shortened to the
shared 400-byte IRC budget; AntiFlood, NoColors and badword filtering still
apply. AntiFlood rejection is not added to the deferred-send queue.

Quote selection runs in at most two isolated workers simultaneously. The bot
must still be connected and joined, with `+RandomQuote` active, when the
worker returns. PART/reJOIN, disconnect and frequency changes invalidate old
replies. The selected id is recorded only after accepted output. With several
quotes, the last accepted id is excluded from the next selection; a channel
with one quote may repeat it. Anonymous quotes are included. Quote records,
schema and recall counters are not changed by automatic delivery.

## Persistence and checks on dev

Overrides, deadlines and last accepted ids live in
`plugins.DATA_DIR/.randomquote.json` (default `plugin-data/.randomquote.json`),
with a private lock and atomic replacement. This instance data directory is
preserved by the normal deployment updater. Dev and production retain their
own schedules and databases. Source promotion does not copy the dev policy
to production: issue the desired randomquote command there after promotion.
Missing initialized state, corrupt state or a busy lock fails closed and
logs a RandomQuote diagnostic; do not delete the schedule to force output.

Test on a registered dev channel containing a quote:

```text
!q s <a word present in a dev quote>
!chanset #test +RandomQuote
!randomquote #test every 15m
!randomquote #test
```

Wait for the announced next attempt (up to 30 seconds beyond the deadline).
Expect one quote, then no new automatic quote before another interval. Set
the desired quieter production frequency, such as `every 3h`, after testing.
Use `!chanset #test -RandomQuote` to pause. After validating dev, the normal
production promotion remains `m update now`.

If no quote appears, inspect `randomquote #test`: the channel must be
registered, enabled, joined and contain quotes in **this instance's** database.
Check the next-attempt delay, AntiFlood/badword policy and RandomQuote logs.
An empty dev quote database does not imply a production quote search failure.
