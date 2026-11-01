# MB1059 — Keep behavioral tests, remove structural repetition

Source: `snap_mediabot_v3_teuk_20261101_135555.zip`, already containing MB1058.
Snapshot VERSION: `3.8dev-20261101_125511` (not edited).

## Execution stays complete

The unchanged default `perl t/test_commands.pl --progress` discovers every
remaining case. No default filter, fast-lane substitution, skipped failed test,
subtest counter compression, cached result or parallel executor is introduced.

Twenty-five old cases are removed. Their exact prose, historical implementation
placement, expression spelling and source-name existence constraints deliberately
stop being enforced. This is a reviewed reduction, not a claim that deleting
assertions can guarantee zero regression. The native export tests, startup
integrity checks, authentication/security boundaries and executable behavior
regressions stay. The duplicate private-command key guard moves from 84 into
383, alongside its existing public-key guard.

The module sanity case keeps duplicate subroutine and duplicate export checks.
It drops two constraints for every module: joined `;use` spelling (valid Perl)
and a literal `1;` line (which does not prove a module loads). Native imports
and the startup integrity check still verify actual loading.

## Retired cases

| Deleted case | Decision and remaining checks |
| --- | --- |
| `100_conf_pod_real_config_keys.t` | Retire configuration POD/debug-hint wording and source-comment requirements; native configuration/DCC and empty-secret/default guards remain. |
| `101_sample_conf_dcc_debug_hints.t` | Retire configuration POD/debug-hint wording and source-comment requirements; native configuration/DCC and empty-secret/default guards remain. |
| `159_external_ctx_args_defensive.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `160_admin_debug_ctx_args_defensive.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `161_channelcommands_ctx_args_defensive.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `162_logincommands_userpass_userident_ctx_args.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `164_helpers_echo_resolve_ctx_args_defensive.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `177_dbcommands_ctx_args_parenthesized.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `178_dbcommands_remaining_ctx_args_style.t` | Retire exact argument-expression/parenthesis spelling, body-location and syntax-message pins. Context, actual command/authentication regressions and module loading remain; no claim that every old expression pin had a one-to-one runtime equivalent. |
| `662_mb447_release_doc_truth.t` | Retire historical release prose, migration/readme hints and source-expression spelling. Actual artifact/release, migration, version-plan and update rehearsals stay. |
| `714_mb504_prerelease_improvements.t` | Retire historical release prose, migration/readme hints and source-expression spelling. Actual artifact/release, migration, version-plan and update rehearsals stay. |
| `716_mb506_release_consistency.t` | Retire historical release prose, migration/readme hints and source-expression spelling. Actual artifact/release, migration, version-plan and update rehearsals stay. |
| `718_mb508_release_workflow_consistency.t` | Retire historical release prose, migration/readme hints and source-expression spelling. Actual artifact/release, migration, version-plan and update rehearsals stay. |
| `1024_mb720c_hailo_runtime_contract.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `1026_mb720d_hailo_runtime_wiring_contract.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `917_mb699_openai_async_transport.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `918_mb699_shared_ai_transport.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `859_mb675_claude_async_transport.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `915_mb699_anthropic_provider_adapter.t` | Retire provider/Hailo import/function-placement and internal-call spelling constraints. Native client/provider, worker IPC, limits, cancellation and Hailo isolation tests stay; secret-content boundary case 922 is retained. |
| `1047_mb731_development_line_contract.t` | Retire historical release prose, migration/readme hints and source-expression spelling. Actual artifact/release, migration, version-plan and update rehearsals stay. |
| `1037_mb723c_readonly_dev_pilot.t` | Retire mbweb CI/pilot/promotion source/document wording matrices. Node authorization/session/quote tests and the real CI lane remain unchanged. |
| `1038_mb723d_operational_promotion.t` | Retire mbweb CI/pilot/promotion source/document wording matrices. Node authorization/session/quote tests and the real CI lane remain unchanged. |
| `1035_mb723a_mbweb_test_lane.t` | Retire mbweb CI/pilot/promotion source/document wording matrices. Node authorization/session/quote tests and the real CI lane remain unchanged. |
| `1134_mb765_conversation_exclusion_contract.t` | Retire conversation-exclusion source/prose constraints. Executable exclusion, cancellation/authority and runtime interaction cases remain (including 1133 and later AI regressions). |
| `84_dispatch_dead_handlers.t` | Retire the namespace-blind search for function names anywhere in all modules. Native exports 85 and startup integrity remain. Preserve the private duplicate-key check in 383; its public counterpart was already there. |

## Fewer interpreter starts, unchanged ordinary assertion counting

Twenty-three standalone regression files move into `t/scenarios/` and execute
through three isolated domain suites. They keep their independent file lexical
scopes, distinct fixture packages and scoped overrides. None installs a BEGIN
or CORE override or leaves its own TAP plan. Every file returns true after
execution; each suite dies if any listed fragment is absent or fails to finish.
There is one final Test::More plan per suite, with all assertions counted
individually (no Test::More subtests).

The grouped tests still use actual DBI/SQLite, constraints, independent peer
connections, native handlers and registered commands. These suites remain fresh
Perl processes. Tests that need their own clock/random/process-global isolation
or cold-import order checks keep it. The wrappers explicitly carry DBI and
filesystem touchpoints so classification never silently treats them as PURE.

| Previous standalone case | Executed scenario |
| --- | --- |
| `1341_mb965_notes_storage_consistency.t` | `t/scenarios/community/1341_mb965_notes_storage_consistency.pl` |
| `1342_mb966_factoid_forget_identity.t` | `t/scenarios/community/1342_mb966_factoid_forget_identity.pl` |
| `1343_mb967_factoid_fetch_error.t` | `t/scenarios/community/1343_mb967_factoid_fetch_error.pl` |
| `1344_mb968_factoid_write_confirmation.t` | `t/scenarios/community/1344_mb968_factoid_write_confirmation.pl` |
| `1346_mb970_factoid_learn_identity.t` | `t/scenarios/community/1346_mb970_factoid_learn_identity.pl` |
| `1347_mb971_native_factoid_reads.t` | `t/scenarios/community/1347_mb971_native_factoid_reads.pl` |
| `1348_mb972_native_factoid_store.t` | `t/scenarios/community/1348_mb972_native_factoid_store.pl` |
| `1349_mb973_factoid_recall_identity.t` | `t/scenarios/community/1349_mb973_factoid_recall_identity.pl` |
| `1345_mb969_quote_fetch_confirmation.t` | `t/scenarios/quotes/1345_mb969_quote_fetch_confirmation.pl` |
| `1350_mb974_native_quote_duplicate_read.t` | `t/scenarios/quotes/1350_mb974_native_quote_duplicate_read.pl` |
| `1351_mb975_quote_add_registry_context.t` | `t/scenarios/quotes/1351_mb975_quote_add_registry_context.pl` |
| `1352_mb976_native_quote_count_reads.t` | `t/scenarios/quotes/1352_mb976_native_quote_count_reads.pl` |
| `1353_mb977_native_topquote_reads.t` | `t/scenarios/quotes/1353_mb977_native_topquote_reads.pl` |
| `1354_mb978_quote_stats_author_key.t` | `t/scenarios/quotes/1354_mb978_quote_stats_author_key.pl` |
| `1355_mb979_native_quote_insert_confirmation.t` | `t/scenarios/quotes/1355_mb979_native_quote_insert_confirmation.pl` |
| `1356_mb980_native_quote_search_reads.t` | `t/scenarios/quotes/1356_mb980_native_quote_search_reads.pl` |
| `1357_mb981_native_quote_view_reads.t` | `t/scenarios/quotes/1357_mb981_native_quote_view_reads.pl` |
| `1375_mb1000_birthday_write_errors.t` | `t/scenarios/users/1375_mb1000_birthday_write_errors.pl` |
| `1377_mb1002_greet_read_errors.t` | `t/scenarios/users/1377_mb1002_greet_read_errors.pl` |
| `1379_mb1004_user_statistics_reads.t` | `t/scenarios/users/1379_mb1004_user_statistics_reads.pl` |
| `1380_mb1005_userinfo_read_errors.t` | `t/scenarios/users/1380_mb1005_userinfo_read_errors.pl` |
| `1402_mb1029_activity_counter_consistency.t` | `t/scenarios/users/1402_mb1029_activity_counter_consistency.pl` |
| `1424_mb1051_seen_channel_prefix_scope.t` | `t/scenarios/users/1424_mb1051_seen_channel_prefix_scope.pl` |

Suite selectors: `1432_mb1059` (notes/factoids), `1433_mb1059` (quotes),
`1434_mb1059` (user reads). A fragment is not a standalone TAP entry point;
select its suite when running a targeted check.

## Smaller behavior matrices

- Quotes compatibility imports are checked by exact native reference identity
  in 1431 instead of repeating their healthy/fault matrices. Genuine registry
  commands/aliases still execute end to end.
- Notes exercise every loader fault in both DBI RaiseError modes through the
  listing path. All five caller operations still reject a partial read before
  output or mutation. The old write matrix's warm=0 and warm=1 cases were both
  explicitly warmed by a listing before the fault; only that duplicate is cut.
- Quote counts keep all driver failures in both error modes once, and a failed
  author-filter fetch. All author/channel/case/wildcard/zero healthy scopes stay.
- Factoid commands retain each implementation's full fault matrix. Additional
  quiet/wildcard/order variants keep a failing fetch, all normal syntax/scopes
  and genuine absence in both error modes. Healthy rendering is not repeated
  solely to change RaiseError when no failure occurs.

## Less wall-clock waiting

The real ScriptRunner timeout cases and native Chromium closed-pipe/TERM-ignore
probe use the supported one-second timeout rather than two seconds. They still
launch the hanging child and exercise actual timeout/termination/reaping, with
existing failure margins and subsequent healthy operations.

The script-bridge timer cases use a bounded native event-loop pump that stops
when the expected resource finishes, rather than always waiting 1.2 or 1.6
seconds. Their one-second application timers and complete output/accounting
assertions are unchanged. The actual cooldown wait and the post-cancellation
observation period remain real. No production timeout or interval is changed.

## Scope and validation

Only tests/helpers, this note and CHANGELOG change. The runner, application,
VERSION, project README, configuration, schemas and private installed commit.sh
are unchanged. No service, commit or push is performed during preparation.
See package QUALIFICATION.md and the complete before/after profiler JSON for
measured results. Server timings and conditional counts may differ. The operator
script requires a fully green `--progress` run before restarting dev or committing.
