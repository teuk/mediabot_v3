# MB959 — Le mot le plus long, Perl API v3 (2026-10-25)

## Scope

Introduce `longest-word-v3`, `!motlong` and alias `!longest`. Reuse the existing
Perl package runtime, explicit channel policies, scheduler and atomic KV store.
Add a narrow asynchronous dictionary capability instead of passing SQL or the
bot object to a plugin. Gameplay remains inside the package. Application
schema, production services and live configuration are unchanged by the code
installer. MariaDB dictionary target: `DICT.DICT`.

## Behavior

- Independent finite matches per channel: five rounds, ten letters, 50 seconds
  by default; weighted draws with four vowels and a bounded quality retry.
- Every player keeps a personal best until timeout or the first accepted optimal
  word, which wins and closes the round immediately with the configured bonus.
  R5 admits only
  words strictly longer than the current round record, initialized at zero. At most 32 participants and eight concurrent matches.
- Single-word proposals are accepted during open rounds. Public messages acknowledge accepted words; bounded channel
  messages show draws, optimal words, player words and match rankings.
- All-time totals and ISO weekly rankings persist after each completed round,
  per channel and ruleset; five rows/page, equal ranks for ties, 52-week detail.
  Existing best-match records remain under `records`, without fabricated backfill.
  Guest identity is nick-based; authenticated accounts use Mediabot user IDs.
- Stop, disable, unload and policy edits discard unfinished games and revoke
  pending dictionary work. Late callbacks cannot resurrect an old game.
- Private connection settings select `DICT` only, with a fresh child-owned
  read-only repeatable-read connection. Signature batches use the existing
  `sorted` index; bounded complete results are validated before play.

## Qualification

The provided export contains 369,085 unique ASCII uppercase words, lengths
2–15. Every sorted signature was checked. On 40 racks, 14,825 complete results
from the actual Perl solver matched an independent whole-dictionary scan.
The local SQL fixture was an indexed SQLite adapter, not a MariaDB server.

The three MB959 native cases pass 93 assertions, including a real AsyncWorker
and independent IO::Async timer, plus the real manifest/registry/policy/job/KV
runtime. The broader plugin/config/module selection passes 3,296 assertions
across 143 files. Inventory, workshop, startup integrity and all 37 security
invariants pass. See the delivery qualification for the full-suite result and
local environment limitations; target-host installation requires its full
suite to pass before a dev restart.

## Operator acceptance still required

Run the read-only dictionary probe against the private dev configuration;
verify `SELECT` permission on `DICT.DICT`. Load and enable the package explicitly
on `#test`, observe one real match, then inspect off/disable behavior. Process
stability alone does not prove IRC reconnection or live play. No production
instance is targeted by this maintenance delivery.

## R2 — standalone dictionary probe configuration

The initial probe passed a raw Config::Simple object to a service requiring
Mediabot::Conf->get. Config::Simple exposes param, so this failed as
`dictionary_configuration` before any SQL operation. The service already used
the native wrapper in the live runtime; no credential or data change is needed.

The standalone probe now loads Mediabot::Conf exactly as production does. The
pre-install wrapper and deploy preflight also include the live repository in
Perl's module search path, because Conf.pm is an existing core dependency outside
the package payload. Error messages link to LONGEST_WORD_PLUGIN.md.

A new isolated end-to-end test uses a real private INI file and the native
configuration loader, with only the SQL transport stubbed. It verifies successful
probe execution, failure containment, the actual documentation path and unchanged
configuration bytes and permissions. Sixteen new assertions pass; all four MB959
cases pass 109 assertions. The dictionary already imported by R1 is preserved.

## R3 — direct words and cumulative/weekly scoring

Add the versioned `irc.channel.word` observation after the conversation exclusion
barrier. Its optional third handler argument is a scoped InvocationV3 carrying a
native principal, receipt clock and notices. It is revoked by policy epochs,
quarantine and lifecycle changes. The package accepts only a word valid for the
current rack, within the current window; all other ordinary chat stays silent.

Add core-owned per-channel collections under the existing `storage.kv` authority
without changing legacy KV quotas or application/dictionary SQL. Atomic locked
CAS commits persist a whole round and receipt. Retry after lost acknowledgement
is idempotent. Persistence refusal pauses progression, retaining the result in
memory until a retry succeeds or the operator ends the plugin process.

Scores.pm owns cumulative arithmetic, weekly retention, ISO/DST boundaries and
rankings. Points use the deadline week, including when a tick crosses Monday.
Every player remains represented within the explicit collection quota. Limits
never silently truncate totals. Existing maxima remain independently readable.

New cases 1330–1332 cover the real filesystem repository, score arithmetic and
native core Context/EventBus/queue/principal/plugin/job/collection path. Case
1328 now grants events.subscribe and supplies its real EventBus. The existing
MB765 ordering guard also checks that public word observation follows exclusion.
See the delivery QUALIFICATION.md for the final local test counts and limits.

## R4 — partyline Unicode output containment

The dev log showed exit 255 from IO::Async's deferred syswrite while sending
`Unknown plugin 'longest-word-v3' — see .plugins loaded`. The package was absent;
no stop hook ran. The Unicode em dash, queued as characters on a byte stream,
failed outside the synchronous command-dispatch exception boundary.

A core Encode::Encoding adapter is configured on both Telnet and DCC sessions.
It encodes character output to UTF-8 before queueing and byte accounting. Existing
UTF-8 bytes and binary IAC ECHO controls pass through unchanged. Its read direction
keeps raw chunks and consumes them exactly once, preserving the current Telnet
filter, authentication input bytes, framing and input-byte limits. No warning is
suppressed; no plugin, grants, policy, dictionary or score is reset automatically.

Case 1333 exercises the exact production error with the real TCP listener and
native plugin dispatcher, then another command on the same connection. It also
checks the loaded-package disable path, DCC, broadcasts, partial writes, callbacks,
CODE/Future-produced output and fragmented protocol bytes. Authentication lookup
is excluded from this offline scenario; the test seeds an authenticated Owner
session to reach the affected command path without using a real account.

## R5 — strictly improving round proposals

Only the round admission rule changes. Engine tracks round_best_length separately
from the dictionary maximum, initializes it to zero in new/begin_round and updates
it only after validation and participant admission. Equal and shorter proposals
are rejected before player/word mutation. The next required length is record + 1.
The common deadline, dictionary solver, scoring formula and persistent counters
remain. Words accepted earlier keep their points; previously saved scores are not
reset or reinterpreted.

The native plugin displays private refusal notices and exposes the accepted
record in rack status. Both command and bare-word paths use the same gate. The
local demo and existing runtime scenarios now follow rising record lengths;
a fresh scheduled callback is captured after fixture reload for multi-match
pagination coverage. New case 1334 covers zero initialization, strict inequalities,
normalized lengths, invalid proposals, earlier accepted words and round reset.
The native runtime case also checks both input routes and rejected-player scores.

## R6 — public accepted words and opening maximum length

Each accepted word now produces one public acknowledgement in its current
channel, containing the player's nickname, normalized word, length and next
minimum. Both the native bare-word event and command route use the same bounded
output helper and channel policy. Rejections remain private and unrelated chat
stays silent. Every draw, including later automatic rounds, announces the solver's
maximum word length without revealing the solutions. The accepted-player record
still starts at zero, distinct from that theoretical maximum.

The Engine, solver, dictionary services, score calculation and score persistence
are unchanged. API grants and channel policies need no change. R6 targets the
confirmed R5 snapshot; it is a dev test delivery with no commit/push operation.
Native integration checks cover both public proposal routes, one message per
acceptance, private refusals, the first/next draw hint and zero record reset.

## R7 — immediate optimal-word win and bonus

An accepted dictionary maximum now permits immediate Engine closure. The native
coordinator announces the winner and the length-plus-configured-bonus arithmetic,
scores the whole round once and commits its receipt before immediately preparing
the next draw. The final round completes the match. No impossible next minimum
is displayed after a maximum; a timeout retains its normal path and pause.

The existing default bonus is three points, configurable through `top_bonus`.
Seven letters plus three earns ten, with no duplicate bonus. Earlier record
holders keep their points. Existing cumulative scores and their storage format
are retained. Early wins use their actual acceptance week, even when the planned
deadline was in the next ISO week. A failed acknowledgement pauses progression;
the idempotent retry cannot add points again. Old-round queued words cannot leak
into the immediate next draw, including equal close/open timestamps.

The integration case 1335 exercises the reported LOUPS, LOUPAS, POUFFAS sequence
on FFMOASLUOP, asynchronous next-draw preparation, default/custom bonuses,
command and bare-word winners, exact-once save recovery, week boundaries and
match completion. Other native fixtures keep non-optimal words where they
specifically exercise timeouts, strict inequalities or unfinished-game reloads.
