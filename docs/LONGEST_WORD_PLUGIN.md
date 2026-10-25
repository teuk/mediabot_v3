# Le mot le plus long: operator and contributor guide

MB959 introduces `longest-word-v3`, a Perl API v3 package, and a narrow,
asynchronous core-owned dictionary facade. Its entrypoint and rules live in
`plugins/longest-word-v3/lib/`; gameplay is not added to `UserCommands.pm`.

## Dictionary

The connection selects **database `DICT`, table `DICT`**. Both names are exact.
The existing three-column layout is supported unchanged:

```sql
CREATE TABLE DICT (
  id_word bigint NOT NULL AUTO_INCREMENT PRIMARY KEY,
  word varchar(255) NOT NULL DEFAULT '',
  sorted varchar(255) NOT NULL DEFAULT '',
  KEY sorted (sorted)
);
```

This is a layout illustration, not an automatic migration. Existing latin1
tables are supported: the supplied words and signatures are ASCII uppercase.
The supplied export contained 369,085 distinct words, lengths 2–15, with no
incorrect signatures. The game uses racks of 8–12 letters, ten by default.
Longer dictionary words need not be removed.

Import the supplied table into `DICT` using your normal MariaDB administration
workflow. The installer does not execute a SQL dump, create an account, grant
permissions or alter the Mediabot application database. The source dump is not
redistributed in the repository. Only `SELECT` on `DICT.DICT` is needed by the
runtime account; `SHOW INDEX` is used by the operator check.

Without a `[dictionary]` section, the core reuses the private `[mysql]` host,
port, user and password to open a **fresh connection to `DICT`**. That account
must have dictionary read permission. If needed, override only this connection
in the private `mediabot.conf`:

```ini
[dictionary]
DATABASE=DICT
HOST=127.0.0.1
PORT=3306
USER=dictionary_reader
PASS=replace_me
```

The literal password above is a placeholder. `SOCKET=/absolute/path/to/socket`
may be used instead of TCP. `localhost` follows Mediabot's existing TCP
convention and becomes `127.0.0.1`. Database names other than `DICT` are refused.
Do not put credentials in plugin JSON, channel policy or Git.

From the repository root, as the service owner:

```sh
perl tools/dictionary_check.pl --conf mediabot.conf
```

This verifies connection, index and a complete reference rack through the same
read-only solver used by the plugin. It changes no data or service. Public
errors contain a code, not driver exceptions, credentials or SQL text.

## Activate on dev

In the Owner partyline, after the code is installed and dev restarted:

```text
.plugins discoverv3
.plugins loadv3 longest-word-v3 data.dictionary.read,events.subscribe,irc.reply,irc.notice,irc.channel_message,scheduler.jobs,storage.kv
.plugins policy longest-word-v3 #test observe
.plugins enable longest-word-v3
.plugins doctor longest-word-v3
.plugins why longest-word-v3 #test
.plugins policy longest-word-v3 #test on
```

Then in `#test`: `!motlong`, followed by words typed directly, such as `NOTAIRES`.
`!motlong MOT` remains compatible. A package already loaded with R2 grants must
be disabled/unloaded and explicitly loaded again with `events.subscribe` in the
grant list; a code update never silently expands granted permissions. Reapply
the intended channel policy after loading and confirm it with `doctor`/`why`.
Do this between matches. Previous best-match records remain available. Observe mode
never creates games, emits game messages or writes records. No legacy command
is replaced. Only the explicitly selected channel can play. Existing v3 boot
ledger rules preserve explicit grants and operator posture on restart; this
installation itself loads or grants nothing.

Configuration fields, validated by the existing channel schema:

| Field | Default | Range |
| --- | ---: | ---: |
| letters | 10 | 8–12 |
| vowels | 4 | 3–5 |
| round_seconds | 50 | 20–120 |
| rounds | 5 | 1–20 |
| top_bonus | 3 | 0–10 |
| score_timezone | Europe/Paris | valid IANA time zone, up to 64 characters |

Changing a channel policy ends that channel's unfinished game. The default
draw uses weighted vowel and consonant pools. Up to six draws are attempted
to find a rack with a word of at least five letters; this is a minimum quality
filter, not a guarantee of uniform rack difficulty. The clock begins after
the complete dictionary result is available, when the draw is enqueued for IRC.
The shared five-second scheduler closes overdue rounds; guesses are refused
at the exact monotonic deadline even before the next scheduler tick.

R5 uses a strict common accepted-word record. It starts at zero for each draw;
only a validated, admitted word advances it. The next proposal needs the last
accepted record length plus one, including for a different player or spelling.
Equal or shorter guesses are refused privately and do not create participants
or points. The record is distinct from the solver's dictionary maximum. It resets
between rounds while match/cumulative scores remain. Earlier accepted words are
still scored normally; this change does not retrospectively invalidate them.
`tirage` shows the accepted record and next required length. Bare and prefixed
proposals share the same Engine gate. The solver and its result are unchanged.

R6 announces every accepted improvement once in the current channel, with the
player's nickname, normalized word, length and next minimum. Bare words and
command proposals share this public acknowledgement. Rejections remain private,
and unrelated conversation stays silent. The existing bounded channel output
and activation/channel policy checks apply; no new capability is required.
Each opening draw also gives the longest possible word length returned by the
solver, without revealing a solution. The player record still starts at zero;
the optimal words remain part of the closing result only.

R7 closes a round as soon as an accepted word reaches the dictionary maximum.
The public acknowledgement announces the round winner, word length and configured
`top_bonus` (default three): seven letters plus three bonus points gives ten.
The existing bonus is applied once, not stacked with a new second bonus. Earlier
accepted words from other players still receive their normal round points.
All round results and the receipt are saved before starting the next dictionary
request immediately; no scheduler tick, remaining deadline or eight-second pause
is required after a maximum. An unfinished save pauses progression and retries
without scoring again. The final round completes the match instead of drawing
again. A round without an accepted maximum still expires normally.

The maximum is always the dictionary's validated maximum for that rack, even if
shorter than the rack. Queued proposals from the previous round, including ones
with the same timestamp as its closure, cannot enter the newly opened draw.


## Architecture and failure handling

`PluginContext::dictionary_solve(invocation, letters, callback)` requires
`data.dictionary.read`. The caller supplies only 2–12 ASCII letters. The core
enumerates distinct submultisets, batches 128 signatures in parameterized
indexed queries and validates every returned word. All valid words for the
rack are returned together. A partial, truncated, corrupt or failed result is
never presented as an authoritative maximum.

Each request uses `AsyncWorker`: the IRC event loop never opens or waits on
MariaDB. The child opens a fresh connection, uses a read-only repeatable-read
transaction and closes it with rollback. Connect/read/write timeouts are three
seconds; statements have a two-second MariaDB limit; the parent has a ten-second
worker deadline. Limits are two concurrent requests per plugin, four total,
4,096 words per rack and 128 KiB worker output. The 32-entry cache expires
after five minutes and is cleared on disable/unload.

`dictionary_cancel(invocation)` cancels only the calling plugin's current
channel. Entry identity, current policy and policy epoch are checked before
completion delivery. A late response cannot revive a stopped or replaced game.
The optional package `policy_changed(context => ..., channel => ..., mode => ...)`
hook is called after successful policy set/reset and allows this package to
discard unfinished state. It receives no private configuration.

The package subscribes to `irc.channel.word` v1. Its core publisher sits after
the public conversation exclusion barrier and considers only 2–32-letter
alphabetic tokens. It exposes channel/nick/word, plus a separate scoped
invocation with a core-resolved principal, monotonic receipt time and notice
sink. Raw messages, hostmasks, bot objects and SQL handles remain unavailable.
The existing bounded deferred event queue and quarantine gates apply. Revoked
policy epochs, old game windows, inactive channels and exact deadlines cannot
revive a queued guess. Saturated queues can drop new events with existing
backpressure metrics; late delivery after closing is conservatively refused.
Invalid ordinary chat words remain silent.

`channel_storage_snapshot(inv)` and `channel_storage_commit(inv, ...)` share
`storage.kv` authority but use core-derived per-package/per-policy-channel
collections. The plugin cannot select a file or another channel. Legacy KV
behavior and its quotas stay unchanged. Collections use strict JSON validation,
private files, atomic replacement, nonblocking process locks and optimistic
revision checks. Invalid, unreadable or symlinked files fail closed rather than
resetting totals. Limits: 1,024 values/channel, 2,048 bytes/value, 2 MiB/document.

Every closed round commits all participant points and an idempotency receipt
in one transaction. A failed write pauses progression and is retried; a repeated
save cannot double points. The week is captured from the round's deadline for a
timeout or actual winning-word acceptance for an early top, in `score_timezone`
(default Europe/Paris), not the eventual save or retry tick. ISO
week-years handle New Year and daylight-saving boundaries. All-time totals do
not expire; queries expose the current and previous 51 calendar weeks. Scores
are isolated by channel and gameplay rules, and keep players below the displayed
top five. Pagination and tied ranks are handled in the package.

`score` shows personal cumulative/weekly points; `scores` keeps the current
match view; `top total` and `top semaine [YYYY-Www] [page]` show persistent
rankings. `records` retains the previous best-match view. These old maxima are
preserved and are not misrepresented as a complete history. New totals begin
with R3. Complete-match records still use their original small KV document.

Back up the complete configured `plugins.DATA_DIR`, including `v3-collections`,
with the bot stopped or from a consistent filesystem snapshot. Source rollback
does not delete scores. Owner `clearv3data` intentionally clears both legacy KV
and channel collections for that exact package, leaving other plugins alone.
Do not edit state files during play. Disable/reload/stop of a still-unsaved,
paused round discards that in-memory result; saved rounds remain intact.

## Qualification

```sh
perl tools/word_game_demo.pl --check
perl t/test_commands.pl --filter mb959 --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```

The MB959 tests cover exact letter multiplicity, normalized input, common
deadlines, strict round records, accepted personal bests, finite rounds, real worker/event-loop
completion, bounded service calls, cached-data isolation, native runtime
activation, bare-word events and identity, weekly rollover, retry receipts,
channel isolation, policy revocation, stop/unload and persistent scores. The supplied
full export was also compared against an independent whole-dictionary oracle
on 40 racks. That local fixture used an indexed SQLite adapter; a live MariaDB
connection and real IRC play must still be verified on the target dev host.

## Partyline unknown-package crash fixed in R4

`Unknown plugin 'longest-word-v3'` means the package has not been loaded in the
current runtime. Run `.plugins loaded` / `.plugins discoverv3`, then explicitly
load it with the grant list above. There is no need to disable or unload an absent
package. R4 also fixes Unicode output on both partyline transports, so such an
error is a normal reply and cannot trigger the observed wide-character syswrite
exception. Existing grants and persisted policies are not expanded by installing
code. R4 can update the qualified R2 or R3 sources and preserves their data.
