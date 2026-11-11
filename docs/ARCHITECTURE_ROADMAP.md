# Mediabot architecture roadmap

Accepted by the maintainer on 2026-11-11, after review of MB1207
(`d2efb58ddea9c370505b92639e2973233d2d02e0`).

This is the durable continuation plan. Read it before proposing the next
structural change and update its progress in the same patch as that change.
Use small reversible deliveries; do not bundle every phase into one migration.
Existing plugin architecture and API v2/v3 compatibility remain authoritative.

## Progress and sequence

| Phase | Objective and bounded first increment | Status |
| --- | --- | --- |
| A | Isolate Partyline `.plugins` administration behind explicit dependencies; keep historical entry points. | MB1208 accepted on host: 39,323 assertions; committed/pushed as `5fd3d59`. |
| B | Reduce Helpers' responsibilities and bidirectional dependencies. Map one output-policy path, give it a single owner, retain compatibility delegates. | MB1209 bounded increment accepted: 39,347 assertions; committed/pushed as `492a23b`. Further Helpers boundaries remain incremental. |
| C | Separate domain data access from commands and IRC transport. Pilot channel output rules, retaining cache freshness, last-known-good data and failure policy. | MB1210 R2 accepted: 39,386 assertions; committed/pushed as `97ced23`. |
| D | Make timer/worker/resource ownership and shutdown order explicit. Inventory existing resources first; migrate one family with idempotent cleanup. Distinguish shutdown, IRC reconnect and rehash. | MB1214 AntiFlood retirement committed/pushed as `b321e17`; three-family output pilot delivered. Detailed MB1214 host test report not supplied. |
| E | Reduce PluginManager responsibilities. Extract runtime-state persistence and diagnostics separately while keeping lifecycle/security authority explicit. | MB1215 file-persistence boundary implemented; host acceptance pending. |
| Throughout | Replace source-body reconstruction with actual component tests and injected clock/transport/storage dependencies; retain native integration tests. | MB1208 (412, 1110), MB1209 (337, 627, 1538). |

## Phase A / MB1208

`Mediabot::Partyline::PluginAdmin` owns parsing, operator permission checks and
presentation for `.plugins`. It loads only core Perl dependencies and receives:

- the plugin manager, through its existing method interface;
- a writer exposing `write`;
- lazy providers for session level, optional autoload state and metrics.

`Partyline::Commands::_cmd_plugins` supplies those dependencies. Existing
Partyline methods and rendering helper aliases remain compatible. The manager
still owns plugin lifecycle, capabilities, storage namespaces and persistence.
This component is trusted operator code, not a sandbox or plugin capability API.

The command cases now invoke the real component without loading the entire bot.
Native Partyline lifecycle, config, storage and alias tests remain in the host
acceptance lane. The remaining large command body can later be separated into
parsing and rendering if concrete tests justify another increment.

Acceptance: exact wire responses, level gates, delegated operations, redaction,
compatibility aliases and command routing preserved; no additional repository
test file; full suite once before commit. Do not mark host acceptance complete
merely because the patch has been prepared or uploaded. Record the successful
host result/commit in the next delivery.

## Phase B / MB1209 — output admission

Before: Helpers owned the admission algorithm, SQL parameter cache, global
window and channel state; Sender and DeferredOutput reached it through the
historical helper. After: `IRC::OutputPolicy` owns that policy, with explicit
wall-clock, config and notification callbacks. Helpers remains the adapter;
Sender and DeferredOutput retain their established entry points and overrides.
The policy does not load Helpers or any transport. `IRC::OutputBudget` retains
monotonic refill ownership. Shared bot state and invalidation keys are unchanged.

Existing cases 337 and 1538 now call the real component rather than recompiling
its source; 627 tests its actual negative-cache behavior rather than a copied
algorithm. Native wiring remains in the host integration lane. The SQL cache
and its failure policy deliberately remain together until phase C; this bounded
increment does not complete all of phase B. No speedup is claimed.

Host acceptance of MB1209: 918 targeted and 39,347 full-suite assertions passed;
committed and pushed as `492a23b`. Boundary review: Helpers already delegates
command throttling, output transport and admission; cache invalidation still
shares `_af_params` with ChannelCommands. Keep that shared state intact while
piloting the adjacent read-only data-access boundary before broader extraction.

## Phase C / MB1210 — channel flood rules reader

`Channel::FloodRules::read` receives only a DBI-compatible handle and channel ID.
It owns the parameter SELECT and returns distinct found/missing/error results;
DBI exceptions propagate unchanged. It has no bot, transport, clock or cache.
`IRC::OutputPolicy` retains defaults, positive/negative cache freshness, channel
lookup, diagnostics and admission fallback. ChannelCommands keeps writes and
existing cache invalidation. No second cache is introduced.

This pilot preserves the existing anti-flood failure policy: false prepare or
execute logs and falls back to global admission without refreshing the cache.
Previously confirmed entries and their age remain stored, but stale entries are
not enforced on that failed read. Missing rows create the existing negative
cache. This differs from the badword filter's last-known-good enforcement;
those policies must not be merged. Statement cleanup and thrown errors are
unchanged, including no explicit finish on false execute. Further cleanup work
must be a separately tested behavior change.

MB1210 R2 host acceptance: 956 targeted and 39,386 full-suite assertions passed;
committed/pushed as `97ced23`. The DBI fault fixture now isolates its scalar slot
without writing to DBI's special variable; native diagnostic restoration passed.

## Phase D / MB1211 — inventory before migration

See [Runtime resource ownership](RUNTIME_RESOURCE_OWNERSHIP.md) for the bounded
source inventory, reconnect/rehash/final-exit distinctions and observed gaps.
The first runtime migration selected is explicit retirement of paced NOTICE
callbacks and notifiers on transport replacement. Existing registry identity
already prevents stale sends; physical removal and payload revocation need an
explicit contract, including inline expiry, reentrancy and cleanup failures.

MB1211 documentation checkpoint was accepted and pushed as `a29a67f` after
reference/patch checks; no runtime suite was required for that docs-only change.

### MB1212 — explicit NOTICE retirement

`IRC::Timer::cancel_countdown` revokes the callback and its captured payload before
attempting stop/remove independently. Weak-key registrations do not own notifier
lifetimes. A cleanup exception returns 0; repeated calls are inert and do not
retry failed physical removal. The existing countdown return value is preserved.
`PacedOutput::retire_notice_timers` empties only the detached registry and reports
incomplete cleanup. `setIrc` publishes the new transport before retirement, so
nested replacement/sends cannot be overwritten or cancelled by the old cleanup.
Late timers returned after a transport change during add/start are retired too.

Same-transport assignments and rehash retain their behavior. PRIVMSG and flood
queues keep existing identity invalidation; no global shutdown coordinator or
child-process migration is introduced. Existing tests cover cancellation faults,
retained callbacks, native notifier removal, inline expiry and reentrant wiring.
MB1212 host acceptance: 798 targeted and 39,423 full-suite assertions passed;
committed/pushed as `62f83c0`.

### MB1213 — explicit paced PRIVMSG retirement

`PacedOutput::retire_privmsg_queues` revokes all detached target states before
notifier cleanup: current and waiting batches, send guards, pump/schedule closures
and notifier slots. `setIrc` publishes the new transport before calling it.
Dormant queues retained after a failed arm are also released on replacement.
Same-transport assignments and ordinary setup-failure recovery remain intact.

Each arm has an identity token so an inline expiry cannot overwrite a successor
notifier with its late return value. Late timers from a retired connection are
cancelled. Stop/remove faults retain callback revocation and emit a diagnostic;
cleanup reentry cannot retire new work. Existing isolated and native paced tests
cover these contracts. MB1213 host acceptance: 837 targeted and 39,462 full-suite
assertions passed; committed/pushed as `52e250e`.

### MB1214 — explicit AntiFlood drain ownership and retirement

`DeferredOutput` now owns a countdown handle and an arm identity per target queue.
Expiry releases these slots before the legacy drain hook. Inline expiry and late
setup failure cannot overwrite or clear a successor arm. An explicit drain also
retires any still-pending arm before processing its item.

`retire_flood_queues` clears every detached queue's payload and arm slots before
cancelling countdowns. `setIrc` publishes the replacement transport first;
cleanup reentry preserves new queues. Dormant failed-arm/no-loop queues are
cleared too. Cleanup failure is reported without restoring permission to send.
Existing line costs, FIFO/retry order, response expiry, queue cap, target spelling
and dynamic Helpers hooks remain unchanged. No global shutdown migration.

MB1214 is present on GitHub as `b321e17` and matches the supplied snapshot.
Its detailed host test report was not supplied; no assertion total is inferred.
The three-family output pilot is delivered. Remaining worker/final-shutdown
questions in phase D stay explicitly deferred.

## Phase E / MB1215 — runtime-state file persistence

`Plugin::RuntimeStateFile` owns JSON encoding/decoding, bounded file reads,
private exclusive temporary-file creation, cleanup and rename publication.
It loads core dependencies only and receives the size bound, a lazy path resolver
and a read validator. It does not receive a bot or manager and has no lifecycle,
capability, scheduler or plugin-loading authority.

PluginManager retains snapshot construction, schema/grant/policy validation,
trusted directory selection, restore order and rollback after persistence errors.
Its existing methods/globals remain compatible adapters. Encoding and size
checks still precede directory creation; return tuples, messages, file mode,
symlink handling and historical JSON decoding are preserved. This extraction
does not claim to add fsync durability or change file-system race policies.

Existing 1135 exercises the real component and existing manager round trips;
1136 retains restore/failure isolation; 1137 follows the new file owner for its
publication contract. No new repository case. MB1215 host acceptance pending.
Next: inspect the diagnostics boundary independently; do not combine diagnostics
with capability authority or persistent-mutation rollback.

## Rules for subsequent phases

1. Record the base revision and compare supplied source snapshots explicitly.
2. Describe ownership and dependencies before and after each change; fewer lines
   in a file alone are not evidence of architectural improvement.
3. Preserve commands, permissions, wire output and default behavior. Any intended
   behavior change needs its own explanation and tests.
4. Keep SQL failure policies domain-specific: authorization, optional archives,
   output rules and writes must not share an indiscriminate fallback policy.
5. Keep security checks at an identified authority; avoid a second inconsistent
   copy in a generic service container.
6. Use explicit dependencies at the extracted boundary, preserving lazy access
   when timing matters. Retain compatibility facades until callers are migrated.
7. No database schema, production configuration or service changes in this plan
   unless separately requested. Radio and YouTube behavior remain sensitive.
8. Validate focused contracts and native wiring, then the full suite once with
   visible progress on the host. Commit/push with the existing commit.sh flow.
9. Record measured test/startup effects when available; do not promise a speedup
   from extraction alone. Never delete coverage only to reduce the test count.

## Completion criteria

- Components can be loaded/tested without unrelated runtime dependencies.
- Each cache, worker and timer has an identifiable owner and lifecycle policy.
- Domain SQL operations live behind named interfaces with explicit error rules.
- The runtime coordinates services; transport and commands do not accumulate
  unrelated business rules.
- Integration tests cover compatibility facades and native runtime wiring.
