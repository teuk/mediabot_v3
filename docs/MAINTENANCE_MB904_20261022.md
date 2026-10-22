# MB904 — Connection presence for the Partyline

Date: 2026-10-22. Development maintenance; no database schema change.

## Operator behavior

| Command | Behavior |
| --- | --- |
| `.away` | Set the default reason `Away` for this connection. |
| `.away <reason>` | Set or replace a visible reason. |
| `.back` | Remove this connection's away state. |
| `.whom` / `.whom all` | List authenticated sessions, including away reasons. |
| `.whom away` / `.whom here` | Select away sessions / sessions without an away state. |
| `.whom telnet` / `.whom dcc` | Select sessions by transport. |

Filters and command names ignore case. One filter is accepted at a time.
Without any away sessions, the original unfiltered `.whom` response is preserved.
An empty filtered result reports that no session matches.

Presence belongs to a connection, including when several connections share one
account. It is discarded by the existing disconnect cleanup. It does not change
chat behavior or clear automatically when a user chats. It is neither sent to
IRC nor added to the runtime-status JSON.

Reasons are valid UTF-8, contain no C0/C1 control characters or DEL, and are
limited to 160 encoded bytes. Leading and trailing ASCII spaces/tabs are trimmed;
an empty reason becomes `Away`. Invalid input preserves the previous state and
is not announced to peers. The stored reason is a wire byte string, avoiding a
second encoding at IO::Async output. Repeating the same reason or clearing an
already-clear state only replies to the requester. A real state change announces
once to other authenticated Partyline users, excluding unauthenticated sessions.

Presence is visible to authenticated Partyline peers. Existing command history
and server input logging still apply. History inspection and clearing retain
the MB903 privacy behavior. Authentication and ten-commands-per-five-seconds
throttling remain in the existing dispatcher.

## Implementation and scope

`Mediabot::Partyline::Presence` owns `_cmd_away` and `_cmd_back`, imported by the
existing Partyline facade. The new module has no SQL, IRC request, network lookup,
timer or persistence. It reuses IRC::TextBudget's wire-byte count. Commands keeps
`_cmd_whom`; only its filter/away display and the help text change. Dispatcher
adds the two routes and `.whom` arguments; presence announces validated changes
instead of the generic raw dot-command announcement.

The other command bodies, old routes, authentication, history handling, throttle,
transport code, incremental Telnet decoder, disconnect cleanup and runtime-status
payload remain unchanged. No schema, migration, production SQL, private config,
VERSION, service, test runner or audit tool changes. Nine payload paths: seven
modified, two new (Presence and this note). All 1,156 numbered cases remain.

## Validation and limits

Twenty-seven behavior assertions extend the existing case 07 and native fixture.
They cover defaults, updates, repetition, byte limits including 40 four-byte
emoji, valid/invalid UTF-8, controls, back/invalid arguments, all filters, hidden
pre-auth sessions, chat while away, help, same-account connection isolation,
cleanup/connection-number reuse, authentication and rate limiting.

Two scenarios use real socketpairs, IO::Async readers and writers for Telnet/DCC.
A UTF-8 character is split across reads; actual peer bytes verify the reply is
encoded once. Database and IRC bot interfaces throw on any call during the new
commands. The fixture's existing private SQLite setup remains local test data;
no existing database, public listener or real IRC service is used.

The new acceptance criteria pass 27/27 on the candidate and 0/27 on the reference.
These criteria describe new features, not 27 pre-existing bugs. The old fixture
matrices and assertions remain present. Twelve default `.whom` contexts,
default `.history`, and six plugin help lines match the reference byte for byte.
The 62 old help command names remain; away/back bring the total to 64. Existing
help lines are identical except the updated `.whom` usage.

Seven independent mutations are detected: lost filter, shared presence state,
character-count budget, raw announcements, uncleared away state, allowed controls
and missing method-level authentication checks.

Local targeted suite: **2,024/2,024**, 71 files. Five syntax checks, security
**GO — 37 invariants**, startup integrity pass. Full reference: 30,332 passes and
one failure out of 30,333, 135 s. Full candidate: 30,362 passes and one failure out
of 30,363, 131 s. Both contain the same MB786 updater-rehearsal exit-status failure.
The 30-assertion delta consists of 27 added behavior assertions and three automatic
checks for the new module. These local full suites are not declared green and
no performance improvement is claimed. The delivered validator requires the
unfiltered full suite, with no exemption, to pass on the server.

These checks do not prove the absence of every regression. They cover local
native streams and controlled sessions, not external terminal clients or a
remote DCC network. The installer also verifies package integrity, exact source
preconditions, backups, repeat application and rollback. See the package's
QUALIFICATION.md for installation rehearsal evidence.
