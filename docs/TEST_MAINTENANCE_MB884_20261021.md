# MB884 — Smaller tests, less idle waiting

Base: `snap_mediabot_v3_teuk_20261021_162038.zip`, after MB883,
`3.6dev-20261021_141642`.

## Deliberate scope

Remove **38 test files and 744 old assertions** after review. Add six meaningful
log/history sanitation assertions to the existing real-sender case. No new case
file is introduced. The net reduction is **738 assertions**, with **1,156** case
files remaining from 1,194. The test launcher is unchanged: its default full run
still executes every remaining discovered case, without a hidden exclusion list,
quarantine, cached pass or parallel executor.

This deliberately stops automatic enforcement of selected historical prose,
comment markers, image dimensions, function-spelling/layout details and copied
reference algorithms. These are not all semantically identical duplicates: their
low-value textual constraints are intentionally retired. The table identifies
retained behavioral coverage where it exists. No claim of exhaustive coverage
or zero possible regression follows from pruning a suite.

Authentication/access, SQL binding/failure cleanup, private secrets, wire-byte
budgets, timeout/process termination, durable state, guarded updates, real
HTTP/SQLite integration and worker/async delivery checks remain. In particular,
the slow ScriptRunner timeout/symlink tests are retained. All eleven fast-lane
sentinels remain; three retired files leave its slow metadata and the matching
manifest-size assertion changes from fifteen to twelve.

## Reviewed removals

| Retired case | Decision and remaining coverage |
| --- | --- |
| `1018_mb718_debian13_readiness_roadmap.t` | Retire closed 3.5 Debian administrator roadmap evidence wording checks; operational database/update guards remain. |
| `1021_mb720_hailo_roadmap_contract.t` | Retire closed Hailo roadmap/design wording checks; actual Hailo isolation/ordering/recovery suites remain. |
| `1034_mb723_mbweb_release_contract.t` | Retire closed mbweb promotion/roadmap wording; executable mbweb security/installation contracts remain. |
| `116_readme_root_sample_path.t` | Retire README wording and installation-step spelling checks; install/release tooling still has executable contracts. |
| `117_readme_perl_conf_order.t` | Retire exact README command wording; foreground/startup behavior remains independently tested. |
| `121_mediabot_usage_spacing.t` | Retire the historical whitespace pin in the usage message. |
| `148_tmdb_result_iteration_robust.t` | Keep TMDB mixed-result and missing-metadata behavior in 1298/1301; retire old loop/comment regexes. |
| `150_youtube_search_uses_imported_uri_escape_utf8.t` | Keep URL encoding and actual search contracts in 804/544/1296; retire import/expression spelling pins. |
| `151_youtube_search_same_colors_as_link.t` | Keep actual search/link rendering in 544/546 and shared formatter checks; retire helper-call/color-layout regexes. |
| `169_youtube_search_three_results_colored.t` | Keep search ordering/result behavior in 544/1279; retire the parallel source-shape contract. |
| `171_fortnite_stats_mode_fallback.t` | Keep real overall/solo/duo/trio/squad command outputs in 1295; retire source-loop spelling checks. |
| `204_youtube_helpers_ownership_regression.t` | Keep module boundary/load contracts in 1296/1297; retire old function-ownership regexes. |
| `210_tmdb_final_message_truncate_regression.t` | Keep actual complete-message UTF-8 bounds and long prefixes in 1299; retire source truncation layout. |
| `211_tmdb_logger_no_warn_regression.t` | Retire exact internal TMDB logging statements and helper signatures; real error/route behavior remains in 1301. |
| `212_fortnite_comment_cleanup_regression.t` | Retire Fortnite comment wording; account lookup guard 74 and real command tests 1294/1295 remain. |
| `239_usercommands_wave4_subs.t` | Retire broad sub-existence/keyword tests; global export checks remain. This was not behavioral coverage of these commands. |
| `244_usercommands_poll_ops.t` | Retire poll-result keyword checks; actual poll close/winner/deadline regressions remain (396/528/646). |
| `258_helpers_db_balance.t` | Retire prepare/finish/comment counts: matching text counts do not prove resource cleanup. Targeted DB failure tests remain. |
| `259_admincommands_structure.t` | Retire broad AdminCommands sub/keyword and prepare/finish counts; global exports and command/rehash contracts remain. |
| `377_healthcheck_uptime_metric_syntax.t` | Retire the historical source-layout pin for uptime/log concatenation; metrics and startup runtime checks remain. |
| `392_mb133_outbound_private_log_redaction.t` | Retire a copied redactor and source-wiring checks; actual shared redaction/ignore tests 391 and actual senders 1304/1306 remain. |
| `393_mb134_botaction_badword_cache.t` | Keep real ACTION cache reuse and statement cleanup in 1306; retire source/cache-layout regexes. |
| `394_mb135_channel_target_and_badword_finish.t` | Keep actual target prefixes, private history rules and DB execute cleanup in 1304/1306; retire source-layout checks. |
| `402_mb222_scriptrunner_no_backtick_comments.t` | Retire comment/backtick and MB-marker pins; executable timeout/symlink tests 400/401 and repository anti-shell guard 441 remain. |
| `515_mb292_plugin_precommit_consistency.t` | Retire comment/test-text consistency pins; assertion/isolation behavior remains in 523/555/556/1283. |
| `516_mb293_active_plugin_architecture_comments.t` | Retire architecture-header wording assertions. |
| `525_mb303_external_module_test_ownership.t` | Retire a test that checks which source strings other tests inspect; current owner/import/runtime tests remain. |
| `545_mb323_youtube_search_syntax_restore.t` | Keep actual restored search behavior in 544 and module load/compatibility checks; retire recovery-comment/brace-layout pins. |
| `563_mb344_botaction_crlf_strip.t` | Keep actual ACTION control-byte sanitation in 1306; retire old source regex. |
| `579_mb360_youtube_views_shared_format.t` | Retire copied old/new view formatters; actual formatter 638 and real search metadata 1279 remain. |
| `604_mb386_outbound_log_history_sanitization.t` | Consolidate actual log/history sanitation checks into 1306; keep audit mutations 1308 and shared sanitizer contracts 1302. |
| `605_mb387_live_log_after_outbound_guards.t` | Keep actual rejected-output history/LIVE behavior in 1306; retire index/count checks of source text. |
| `620_mb402_trivia_hint_structure.t` | Retire a locally copied hint algorithm and marker check; this case did not execute the application hint implementation. |
| `636_mb421_fortnite_float_formatting.t` | Retire a locally copied number formatter; actual Fortnite formatted replies and mode behavior remain in 1295. |
| `715_mb505_changelog_truth.t` | Retire exact historical release prose and migration citations; executable migration/release/update contracts remain. |
| `722_mb516_readme_social_preview.t` | Retire historical social-preview image dimensions/README embedding checks. |
| `884_mb682_public_docs_architecture_sync.t` | Retire historical architecture-document wording and changelog pins. |
| `892_mb690_unreleased_changelog_truth.t` | Retire one changelog assertion per MB-number and historical ordering pins; future maintenance no longer grows this prose matrix. |

The preflight lists in `commit.sh` drop only the three retired comment/meta cases
402/515/516 and duplicate references to already-listed cases. Other required
preflight files still fail closed when missing. The helper's explicit tracked
file deletion confirmation is unchanged. It is ignored by this snapshot's git
configuration; installation updates the local helper, and the commit instructions
stage it only if it is already tracked. It is never force-added.

## Faster fixture shutdown and protocol completion

Two network-statistics test fixtures now use a 10ms HTTP-server shutdown polling
interval instead of the default 500ms. Requests still traverse the real local
HTTP server, history SQLite and rollback machinery. Request timeouts, tested
application intervals and production servers are unchanged. The shared fixture
also speeds up its observatory consumers.

The radio loopback metadata test used to accept only the push connection, then
leave two subsequent queue-observation requests waiting until the actual
client's two-second deadlines. The fixture now serves all three real connections
and checks both queue readbacks plus the observed position. It preserves the
actual TCP push, metadata bytes, numeric acknowledgement and file-integrity
checks, while eliminating the unrelated timeouts. All 166 Python test methods
remain; no production timeout is shortened or mocked away.

Measured before/after results and environment limits are recorded in the
package's `QUALIFICATION.md`. Use the normal server qualification command with
`--progress --profile --profile-top 20` to measure the result on the target host.

## Policy for future test changes

- Extend the existing behavior test for the owning module before adding a new
  numbered file for a maintenance patch.
- Add coverage for a distinct failure, boundary or security property. Do not
  add a regression merely for a comment, MB marker or exact helper spelling.
- Exercise the real implementation. Avoid reproducing its algorithm inside a
  test and treating agreement with that copy as production coverage.
- Use representative equivalence classes and boundaries. Avoid multiplying every
  input variant by every facade when shared ownership is already tested.
- Keep tests that fail under a realistic fault. Retire superseded form checks
  with an explicit mapping, and profile elapsed time rather than counting
  assertions as a measure of quality.

No Mediabot application module, schema, migration, private configuration,
VERSION or runtime service is changed. Existing history remains recoverable
from git; the installer also backs up each removed file with its original mode.
Validation failure or explicit guarded rollback restores the retired files.
