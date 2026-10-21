# MB888 — Give external data sources their own modules

## Reason for the split

`Mediabot::UserCommands` combined command dispatch and game state with HTTP
clients and JSON parsers for Wiktionary and Open Trivia DB. Those source
implementations do not need IRC command state. This change moves them to two
explicit owners under `Mediabot::External`, following the existing provider
layout, without changing their algorithms.

| Owner | Responsibilities |
| --- | --- |
| `Mediabot::External::Wiktionary` | `_define_pick_entry`, `_define_lookup_sync` |
| `Mediabot::External::OpenTriviaDB` | `_trivia_parse_api_content`, `_trivia_fetch_sync` |
| `Mediabot::UserCommands` | Async adapters, callbacks, command validation, replies, trivia state, timers and SQL |

The two new modules have explicit optional exports and load independently of
UserCommands and the External facade. They retain the existing runtime HTTP
factory call; Open Trivia DB also retains its injected-client option. This is
an ownership change, not a new HTTP abstraction or a new command API.

## Compatibility boundaries

The four moved function bodies are byte-identical to the snapshot. All 85
remaining named function bodies in UserCommands are also byte-identical.
UserCommands imports the same historical helper names and retains its 101
default exports. Its source shrinks from 8,462 to 7,876 lines.

The asynchronous adapters remain in UserCommands and resolve its synchronous
helper symbols at call time. Existing runtime overrides of those adapter hooks
therefore still work. Each source parser is now resolved within its own module.
No repository caller overrides those parser symbols.

Provider policies deliberately remain separate: Wiktionary keeps its 512 KiB
response bound, deterministic language choice, UTF-8 query escaping and existing
definition cleanup; Open Trivia DB keeps its 64 KiB bound, seven-second default
hard request deadline, progress protocol and one rate-limit retry. Its retry
wait still runs in the worker. The distinct outer worker deadlines, failure
shapes and result transport remain in their existing adapters.

There is no schema, migration, configuration, VERSION or service change.
No command, SQL statement, output budget or IRC routing policy is rewritten.

## Verification

Six existing test cases now locate source bodies in their new owners. Eight
assertions are added to two of those cases: independent cold load orders,
canonical legacy aliases and actual asynchronous adapters honoring runtime
source overrides. No new numbered test file is added.

- Targeted lane: **249/249**, ten files.
- Scratch-only comparison: **67 before/after scenarios**, identical outputs,
  scalar UTF-8 flags, HTTP options, URLs, errors, retry delays and progress
  stages after removing elapsed-time measurements. These call the actual
  functions with controlled HTTP responses, rather than copied algorithms.
- Four of those scenarios use native IO::Async workers. Trivia success and
  HTTP failure both complete once without parent-side HTTP. Both Wiktionary
  native probes return the same existing fallback on this local runtime;
  they establish equivalence, not successful native definition delivery.
  Synchronous definition success and error paths are compared separately.
- Full reference: **30,123 passed, 1 failed / 30,124**, 1,156 files, 117 s.
- Full candidate: **30,137 passed, 1 failed / 30,138**, 1,156 files, 111 s.
- The sole failure in both trees is the existing local MB786 updater rehearsal.
  The candidate adds eight explicit assertions and six generic module checks.
  The observed durations are not a performance claim.
- Security: all **37 invariants** hold. Startup integrity: pass.

The server installer requires the unfiltered full suite, security audit and
startup integrity to pass. MB786 is neither skipped nor tolerated there.
The guarded package also checks source hashes, preserves backups, and restores
only files owned by a failed installation attempt. See its qualification note
for installation and restoration evidence.
