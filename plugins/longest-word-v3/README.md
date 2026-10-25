# Le mot le plus long — Perl API v3

A multiplayer letter game for IRC. Each channel gets its own finite match.
Ten letters, five 50-second rounds and a three-point optimal-word bonus are
the defaults. Every player keeps their own longest accepted word. Each new
accepted proposal must beat the current round record. The first accepted word
that reaches the dictionary maximum wins the round immediately; otherwise the
common deadline ends it.

## Try the rules locally

From the repository root, with Perl and its core modules only:

```sh
perl tools/word_game_demo.pl --check
```

This runs the real rules engine with a tiny fixture dictionary. It needs no
database, configuration, service or IRC connection. The native API v3 lifecycle
and the asynchronous service are exercised separately by the MB959 test cases.

## Play

```text
!motlong
NOTAIRES
!motlong tirage
!motlong score
!motlong scores
!motlong top total
!motlong top semaine
!motlong records
!motlong stop
!motlong aide
```

`!longest` is an alias. During an open round, type the word directly in the
channel: `NOTAIRES`, `été`, or even `STOP` (which is a word, not a stop command).
The previous `!motlong MOT` and `!motlong mot STOP` forms remain accepted.
Each accepted word is acknowledged once in the channel with the player's nick,
normalized word, length and next minimum. At the maximum, it announces the winner
and length plus configured bonus instead of asking for an impossible improvement.
Rejections and syntax errors use notices.
The channel also receives draws, one final reminder, results and the match ranking.
Each draw announces the dictionary's longest possible word length; solutions
are revealed only when the round ends. This hint does not set the player record.
Only single alphabetic words in an active round are considered. Sentences,
commands, actions, private messages and other channels are ignored. A word that
does not solve the current rack produces no reply or notice. Guesses remain
public and can be copied by other players; this is not a private-entry game.

The round record starts at **zero for every draw** and changes only after a
valid word has been accepted. A proposal must be **strictly longer** than that
record: after six letters, the next accepted word needs at least seven. Equal
lengths are refused even if the spelling or player differs. This rule applies
to bare words and command proposals alike. A private notice explains the next
required length; `tirage` also shows the current record and next minimum.
Previously accepted words retain their points when another player raises the
record. Rejected proposals add no player, accepted word or points. A new round
resets the record to zero independently of the dictionary maximum and match totals.

Finding the maximum closes the round at once, scores each player's best accepted
word and gives the finder the configured `top_bonus` (three points by default).
A seven-letter maximum therefore earns **7 + 3 = 10 points**, once. After the
whole round is saved, the next draw starts immediately, without waiting for the
old deadline or the normal eight-second inter-round pause. The last round ends
the match. If saving fails, the match pauses and retries before drawing again.

Accents and case are normalized; `ÉTÉ` becomes `ETE`, `CŒUR` becomes `COEUR`.
The actual supplied dictionary determines which words are accepted. Hyphens,
apostrophes, phrases and extra letters are refused. Repeated letters must be
available in exactly the necessary quantities.

The initiator, a global administrator or a channel operator with level 400 can
stop a match. No unfinished round is scored. Registered authenticated players
use their Mediabot user ID; guests use their RFC1459-folded nickname. Guest
nicknames are not authenticated identities.

## Scores and leaderboards

- `!motlong score`: your all-time total and current-week total, plus current
  match points if a match is running. It also works between games.
- `!motlong scores`: current match standings.
- `!motlong top` or `!motlong top total [page]`: cumulative channel ranking.
- `!motlong top semaine [page]`: current weekly ranking.
- `!motlong top semaine 2026-W43 [page]`: a week in the last 52 calendar weeks.
- `!motlong records`: the former best complete-match records.

Every completed round adds each player's best accepted word score once. Improving
a non-optimal word adds no points immediately; only the final accepted personal
best is scored when the round closes, either on a maximum or timeout. Equal
cumulative totals still share rank; equal-length round guesses
are refused. Rankings show five players per page with
shared ranks for ties. Players outside the displayed page retain their points.

Weeks run from Monday 00:00 through Sunday 23:59:59 in `Europe/Paris` by default,
using ISO week-years and daylight-saving rules. Configure `score_timezone` before
play if a different IANA zone is needed. A round belongs to the week of its
deadline for a timeout, or its winning word's actual acceptance time for an early
maximum, even if saving is retried later. All-time totals never
expire; weekly detail is available for the current week and 51 previous weeks.

All standings are per channel and gameplay ruleset (letters, vowels, duration,
rounds and bonus). Unlike rules are not mixed. Authenticated players keep their
Mediabot user ID across nick changes; guests keep a case-folded nick identity.
A guest nick can be reused by another person. Logging in does not automatically
merge previous guest points into an authenticated account.

Totals start with this version. Earlier best-match records are retained, but
cannot reconstruct a complete historical total and are not converted into one.

The core saves a whole round and its receipt atomically in channel collections
under `plugins.DATA_DIR`, separate from `DICT.DICT` and the legacy KV records.
A lost write acknowledgement is safe to retry without duplicate points. A failed
save pauses the match and retries on timer ticks; no player is evicted to make
room. Previously saved rounds survive a stop, restart, reload or policy change.
Unfinished rounds do not. If the operator disables/reloads/restarts while a save
is still failing, its in-memory unsaved round cannot be recovered automatically.

Bounds: eight active matches per plugin, 32 players per match, 128 attempted
identities per match, one proposal per second per identity. Each channel
collection has 1,024 entries of at most 2,048 bytes and a 2 MiB document limit.
Each player/ruleset pair occupies one entry; each ruleset also has one receipt.
Capacity refusal is explicit and preserves existing scores. The old best-match
list retains its previous ten-entry and small-KV limits. Owner-only
`.plugins clearv3data longest-word-v3` deliberately clears both kinds of data;
back up `plugins.DATA_DIR` before using that destructive operator command.

## Install and activate

See [the operator guide](../../docs/LONGEST_WORD_PLUGIN.md). The dictionary is
external: MariaDB database `DICT`, table `DICT`, columns `word` and `sorted`,
with an index named `sorted` beginning with that column. No dictionary data or
credentials are shipped in this public package.

The package starts off and unloaded. It requests only `data.dictionary.read`, `events.subscribe`,
`irc.reply`, `irc.notice`, `irc.channel_message`, `scheduler.jobs`, `storage.kv`.
It receives no SQL connection, bot object, private configuration or raw socket.
