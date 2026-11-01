# MB1058 — Prune repeated checks and shorten test fixtures

Base: public master `8131333a6c667c64b337a85887fe2d97b52c0aab` (MB1057).

## Scope

The default `perl t/test_commands.pl --progress` still executes every discovered
case. The runner, application, VERSION, configuration, dependencies and schemas
are unchanged. There is no default filter, cached pass, quarantine, aggregate
assertion rewrite or parallel executor.

Thirty historical source/prose cases (1,401 assertions on the measured base)
are deleted. They pinned extraction comments, physical function placement,
source expression spelling, a copied notes algorithm, or cookbook coverage.
Those textual constraints deliberately cease to be enforced. This does not
claim that every retired assertion was a semantic duplicate or that pruning
can guarantee zero regression.

A fixed native inventory checks 223 compatibility aliases by exact code reference.
Its expected names are literal, never discovered from the facade being tested:
removing an alias fails. Full behavior/fault matrices now run once on the owner
rather than repeatedly on imported names that execute the same function.
Registered karma spellings and registered duel/trivia integration remain actual
handler calls. Both DBI RaiseError modes and every distinct owner fault/identity,
calendar/DST, permission, cancellation and late-callback scenario are retained.

## Reviewed retirements

| Deleted case | Retained checks / deliberate retirement |
| --- | --- |
| `852_mb670_social_history_extraction.t` | Native alias inventory 1431, export/dispatch guards 83/85/86/383, and native owner behavior cases; retire extraction layout and line-count pins. |
| `860_mb676_karma_extraction.t` | Native alias inventory 1431, export/dispatch guards 83/85/86/383, and native owner behavior cases; retire extraction layout and line-count pins. |
| `861_mb677_community_state_extraction.t` | Native alias inventory 1431, export/dispatch guards 83/85/86/383, and native owner behavior cases; retire extraction layout and line-count pins. |
| `862_mb678_partyline_transport_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `863_mb678_partyline_session_auth_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `864_mb678_partyline_dispatcher_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `865_mb678_partyline_plugin_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `866_mb678_partyline_core_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `867_mb678_partyline_operational_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `868_mb678_partyline_channel_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `869_mb678_partyline_reminder_seen_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `870_mb678_partyline_karma_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `872_mb678_partyline_reload_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `873_mb678_partyline_network_stats_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `874_mb678_partyline_irc_control_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `875_mb678_partyline_ai_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `876_mb678_partyline_runtime_diagnostics_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `877_mb678_partyline_channel_moderation_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `878_mb678_partyline_antiflood_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `879_mb678_partyline_remaining_standard_commands_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `880_mb678_partyline_privileged_controls_extraction.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `881_mb678_partyline_boundary_closure.t` | Native Partyline alias inventory 1431; real Partyline/DCC/authentication/dispatcher/shell and UTF-8 wire cases remain. Retire extraction comments, implementation location and repeated .eval placement checks. |
| `243_usercommands_notes.t` | Native notes read/write/identity/reconciliation and Unicode-length cases in 1341; aliases in 1431. Retire sub-existence and expression-spelling checks. |
| `380_note_export_lc_key_and_limit.t` | Native notes read/write/identity/reconciliation and Unicode-length cases in 1341; aliases in 1431. Retire sub-existence and expression-spelling checks. |
| `652_mb437_notes_load_before_cap.t` | Retire the copied cache-loading algorithm and helper-call ordering regex. Native storage/load/failure cases remain in 1341; this copied algorithm did not execute the application. |
| `190_seen_respects_channel_scope.t` | 1338 exercises actual scoped seen reads and read failures; 1424 covers all four channel prefixes. |
| `192_seen_persisted_respects_channel_scope.t` | 1338 exercises actual scoped seen reads and read failures; 1424 covers all four channel prefixes. |
| `33_quote_search_like_escape.t` | 1356 exercises native literal wildcard search/ranking/bounds; retire SQL-expression spelling. |
| `79_quotes_db_safety.t` | Native quote suites 1350–1357 and existing deletion/access tests remain; retire prepare/execute/finish text, statement strategy and source-shape pins. |
| `736_mb538_cookbook_doc_truth.t` | Deliberately retire exact cookbook coverage/count/wording and README backlinks; executable script examples, protocol/runtime gates and configuration tests remain (including 514). |

## Faster fixtures

- Eight file-backed SQLite setup functions plus the native deluser fixture seed
  their schema/data in one transaction, committed before any handler, injected
  fault, peer observation or caller transaction begins. Real handler commits,
  rollback, constraints, independent connections and synchronous durability are
  preserved; no `synchronous=OFF` or in-memory replacement is introduced.
- Synchronous Gemini retry-policy tests advance a scoped virtual clock through
  the real retry code. The actual async worker/backoff integration stays real.
- Scheduler slow-callback metrics use a scoped virtual clock and real
  Time::HiRes interval arithmetic instead of two blocking sleeps.
- Shell watch retains the validated five-second interval, real native periodic
  timer, heartbeat and UTF-8 socket. Only the fixture's first timer occurrence is
  accelerated; policy validation and resource cleanup remain asserted.
- The full 6,044-question French catalogue is validated once through the native
  first fetch, then reused by provider/worker cases. No dictionary question,
  validation rule, language scenario or real worker is removed.

FastValidation drops three references to deleted files from its nonmandatory
slow metadata; its matching size assertion changes 12→9. Every mandatory
sentinel remains. The installed private commit.sh is unchanged, including its
explicit `KEEP DELETIONS` prompt and normal final commit review.

## Measurement and limitations

See the delivered QUALIFICATION.md for before/after full-run timings and totals.
Measurements use separate clean checkouts, the same dependencies, the same
machine and the same `--progress --profile-top 1500` command. No full run was
replaced with the fast lane. Server timing and conditional assertion totals
can differ; the operator must obtain a green full suite before restart/commit.
