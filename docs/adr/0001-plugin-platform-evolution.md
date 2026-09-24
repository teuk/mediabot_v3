# ADR 0001: evolve Mediabot toward capability-scoped plugins

- Status: accepted for implementation
- Date: 2026-09-17
- Milestone: MB740

## Context

Mediabot has a mature plugin runtime, yet most user-facing behavior remains in
central dispatch tables and large feature modules. Trusted in-process plugins
receive the complete bot object. Sidecar API v2 is safer and declarative, but
is global, public-command oriented and lacks shared HTTP, scheduler and typed
data services.

Continuing to add features to both the legacy dispatch and isolated modules
would increase the number of authorities for command routing, access policy and
documentation. Rewriting Mediabot would discard proven IRC, security and
operational behavior.

## Decision

Adopt an incremental microkernel direction:

- keep IRC, identity, authorization, wire safety, registries, migrations,
  secrets and plugin lifecycle in the core;
- provide API v3 plugins with a capability-scoped `PluginContext` instead of
  the full bot object;
- converge built-in and plugin commands on one catalogue before extracting
  product features;
- version public events and mediate scheduler, HTTP, storage and data access;
- make plugin activation an explicit per-channel policy, disabled by default;
- freeze API v2 and preserve it through a compatibility adapter;
- prove the platform with low-coupling first-party plugins before extracting
  AI, radio or moderation behavior.

## Consequences

Positive:

- optional features become independently testable, observable and reversible;
- permissions are explicit and can differ by instance and channel;
- command help, dispatch and plugin metadata can share one source of truth;
- failures can be contained and repeatedly failing plugins quarantined;
- new features can be delivered without expanding the central modules.

Costs:

- API v2 and v3 coexist during the migration;
- facades must be designed before coupled features can move;
- parity and rollback tests are required for every extraction;
- registry names and executable handler catalogues must remain exactly in sync;
  the deterministic inventory enforces this after MB749 retires compatibility
  dispatch.

## Rejected alternatives

- **Rewrite in another language:** too much operational and behavioral risk.
- **Expose the full bot to v3 plugins:** defeats least privilege and makes the
  API impossible to stabilize.
- **Start with AI, radio or moderation:** combines too many dependencies for a
  useful platform proof.
- **Install plugins automatically from remote repositories:** incompatible
  with the project's trust and rollback requirements.
- **Apply plugin DDL at startup:** unsafe for production and rollback.

## Compliance

MB740 itself changes no IRC behavior. Subsequent milestones must retain an
explicit old-path rollback until parity has been demonstrated on the
development instance.

MB741 makes `CommandRegistry` authoritative for all 238 public and 94 private
built-ins. The historical hashes remain exact, frozen handler adapters during
the migration; they are no longer alternate discovery or fallback paths.

MB742 establishes the executable API v3 boundary. Package discovery reads
strict manifests without loading code; explicit loading still leaves a plugin
disabled; activation invokes a bounded lifecycle. Plugins receive only
`PluginContext` and copied invocation data, while command authorization and IRC
output remain core-owned. API v1/v2 execution remains unchanged and its adapter
is descriptive only.

MB743 gives that boundary core-owned time and observation services. Eight
events have explicit versioned schemas and copied payloads; delivery uses a
bounded deferred queue with a deterministic overflow policy. Declarative jobs
are namespaced in the central scheduler and follow the plugin enable, disable
and unload lifecycle. Neither service activates a package automatically, and
both require an effective capability grant.

MB744 makes activation channel-scoped without weakening the explicit package
lifecycle. The core validates bounded string, integer and boolean configuration,
applies defaults, RFC1459-folds channel keys and intersects every command,
event, job and output attempt with `off`, `observe` or `on`. `observe` executes
bounded handlers while suppressing IRC output; `off` also revokes deferred work.

MB745 proves the boundary with `playful-v3`. Six frozen public adapters can be
replaced only through a named fallback migration mode: legacy remains visible
in `off` and `observe`, v3 becomes authoritative only in `on`, and unload
restores exact registry entries. Autonomous job output gains a separate
`irc.channel_message` capability whose target is the current policy channel.
Partyline control is explicit, Owner-gated and never connected to AUTOLOAD.

MB746 gives plugins a mediated outbound window and a small notebook. HTTPS
requests run in owned asynchronous workers with public-address validation, DNS
pinning, TLS verification, redirect revalidation, hard bounds, cache, circuit
and lifecycle cancellation. Small plugin state uses detached revisioned
snapshots and compare-and-swap commits through the existing atomic disk
boundary. `short-content-v3` proves both services but remains explicitly
unloaded, disabled and channel-off until an operator runs an observe-first
pilot.

MB747 opens the first database-backed capability without opening the database.
`data.quotes.read` consists of six core-owned, channel-scoped prepared read
operations returning detached immutable records. Reads are permitted during
observe-first parity work, but no write, delete or recall-counter mutation is
available and no visible quote command is migrated by this milestone.

MB748 converts that capability into a deliberately narrow product migration.
`quotes-v3` owns only `quotecount`, `topquote` and `halloffame`, which are pure
reads and already have frozen public adapters. The existing fallback bridge
keeps the old result visible in `observe`, makes the package authoritative only
for an explicit `on` channel, and restores the exact adapter on unload. The
core adds a bounded escaped author-prefix count mode for historical parity.
The mixed `q` and `quote` dispatch remains untouched until a separate decision
defines quote-write authorization and rollback.

MB749 closes the compatibility-dispatch phase. All 238 public and 94 private
built-ins carry executable CODE handlers in `CommandRegistry`; public and
private dispatch call only the resolved registry entry. The duplicate
`%command_map` and `%command_table` paths are removed. The manifest protocol
name `legacy-public-fallback` remains stable for MB745/MB748 packages, but its
implementation now captures the eligible built-in registry handler at mount
time and restores the exact entry on unload. This changes no command output,
activation policy, private configuration or database state.

MB750 opens the stabilization phase with read-only operational truth. The core
derives detached doctor, permission and channel-decision reports from the same
entry, capability intersection and policy objects used at dispatch time.
Partyline never receives configuration values or privileged runtime objects,
and the diagnostic path performs no automatic remediation. Quarantine and
reset controls remain a later, separately gated decision.

MB751 records the evidence needed before that decision. Each loaded API v3
instance owns a bounded in-memory ledger for command, event, job and HTTP
callback outcomes. Failure reports expose only runtime coordinates, streaks,
timestamps and short instance-salted SHA-256 fingerprints; raw exceptions
never cross the operator boundary. A success resets its matching streak, while
unload destroys the complete ledger. Readiness is unchanged, and MB751
introduces neither automatic quarantine nor a reset control.

MB752 adds manual containment without coupling it to that evidence. An Owner
may quarantine or release one manifest-declared command, event, job or HTTP
callback on one channel. The 64-entry registry is instance-local, idempotent
and checked again at deferred dispatch and completion so queued work cannot
outlive the operator decision. Disable/enable preserves it; unload/reload
discards it. Release preserves failure history, and no count, streak or
fingerprint triggers quarantine automatically. Global disable, restart,
persistence and bulk reset remain outside this decision.

MB753 establishes write authority before moving any mixed quote command. The
core derives an immutable scalar principal from the authenticated command
context and attaches it to `InvocationV3`; plugins receive neither the mutable
user object nor credentials or host identity. The distinct
`data.quotes.write` service accepts only bounded add/delete operations, chooses
the channel from current policy, rejects invocation lookalikes without the
runtime's opaque origin, and reuses historical author, Administrator and
channel-level deletion rules. Writes are impossible in `observe`, and no package
requests the capability in this milestone. Consequently MB753 changes no
command routing, activation, database schema, private configuration or live
quote data.

MB754 adopts the mixed commands only after that authority exists. `quotes-v3`
declares `q` and `quote` through the same saved-handler migration bridge as its
read-only commands. The read facade grows only the bounded parity operations
needed by their historical public behavior, while `data.quotes.write` gains a
single channel-scoped recall-counter operation. In `observe`, every v3 write
is suppressed before DB access and the historical handler remains visible; in
`on`, the package becomes authoritative only for an explicitly selected
channel. Loading, grants, enablement and channel policy remain manual.

MB755 repairs the anonymous-author representation exposed by that first live
pilot. Both the saved historical handler and the v3 write service bind SQL
`NULL` instead of the invalid `id_user=0` sentinel. The fresh schema and an
idempotent migration make `QUOTES.id_user` nullable, convert zero or orphaned
references and use `ON DELETE SET NULL` so quote history survives account
removal. The `on` promotion remains paused until this migration and an
anonymous live write pass; MB755 does not promote any channel automatically.

MB756 records the supervised live proof of the earlier HTTP/repository design.
On the development channel, `short-content-v3` stayed silent and write-free in
`observe`, delivered bounded success and neutral errors in `on`, and returned
to its prior revisioned state after rollback. The exercise also exposed that
the historical `.plugins cleardata` command addresses the v1/v2 namespace and
therefore cannot be used as an API v3 repository cleanup contract.

MB757 resolves that operational ambiguity without changing storage semantics.
The Owner-only `.plugins clearv3data <package>` action validates the runtime
slug and derives the private short-or-hashed v3 key inside `PluginManager`. It
is idempotent, works independently of package lifecycle or installation, never
reveals a path, and cannot delete legacy same-slug storage. It adds no startup
activation, automatic cleanup or plugin-visible filesystem authority.

MB758 deliberately moves to a new product domain instead of extending Quotes.
`data.factoids.read` offers only exact lookup, bounded keyword listing and a
bounded top-recall view through the channel selected by the invocation policy.
Exact results are immutable detached records; list/top results are copied
scalars. Reads may run in `observe` but never update `hits`. No package requests
the capability yet, no command moves, and `learn`, `forget` and recall
accounting remain unavailable until separate write authority is reviewed.

MB759 adopts only the two operations already proven physically read-only.
`factoids-v3` mounts `factoid` and `factoids` through the same exact saved-entry
bridge used by Quotes. It requests only `data.factoids.read` and `irc.notice`,
remains unloaded/disabled/off by default, shadows silently in `observe`, and is
authoritative only for an explicitly selected `on` channel. `whatis` is
excluded because it increments `hits`; `learn`, `forget` and `?keyword` remain
historical. Lifecycle rollback restores the exact two prior registry entries.

MB760 establishes factoid write authority before any mutating command moves.
The distinct `data.factoids.write` service exposes only bounded upsert and
delete operations. A runtime-issued invocation supplies the policy channel,
detached principal and bounded IRC nickname; plugin-created invocation
lookalikes are rejected. Upsert preserves the existing creator on update.
Delete trusts an authenticated numeric author, Administrator or channel level
400, never nickname text alone. Writes require `on`, are suppressed before the
service in `observe`, and expose no recall mutation. No package requests this
capability, no command moves and no factoid data changes in MB760.

MB761 adopts only the two commands covered by that authority. `factoids-v3`
requests `data.factoids.write` and mounts `learn` plus `forget` through the
saved-entry bridge. `observe` executes parsing but the core suppresses the v3
write before the service; the historical fallback then remains the single
visible mutation. `on` performs exactly one bounded core-authorized write.
`whatis` and `?keyword` remain historical because their recall increment still
has no dedicated capability. The package remains unloaded, disabled and off by
default, and rollback restores all four saved command entries.

MB762 closes that remaining authority gap without moving a command. The
existing `data.factoids.write` service gains one `factoid_recall` operation
that normalizes a bounded keyword and increments `hits` only for the current
policy channel and matching factoid. It accepts no caller-provided counter,
factoid id or channel. Runtime invocation provenance and explicit `on` policy
remain mandatory; `observe` is suppressed before the service. `whatis` and
`?keyword` stay historical until MB763 can prove visible and quiet recall
parity through the reversible bridge.

MB763 completes that adoption. `factoids-v3` mounts `whatis`, and the existing
parser-level `?keyword` route enters the same registry handler with the quiet
sentinel intact. In observe, v3 output and recall mutation are suppressed and
the saved historical handler remains the only visible counter writer. In on,
one bounded lookup, one core-owned increment and one channel reply execute.
Explicit misses retain their teaching notice; quiet misses emit nothing. Off,
disable and unload restore the exact saved `whatis` entry.

MB764 closes the first extraction wave without broadening plugin authority.
`.plugins overviewv3` exposes one bounded detached reconciliation of installed
packages and live v3 instances. The first retained activation is
`factoids-v3` on the development channel `#test`, after disposable observe/on
evidence and cleanup. It remains an instance-local promotion: no API v3 boot
autoload is added, restart fails closed to unloaded, and `off`, disable or
unload remains the immediate operator rollback. Quotes receive no new scope
and no production channel is activated.

MB766 makes that operator decision durable without reviving broad boot
autoload. One core-owned, bounded and private JSON ledger records only loaded
API v3 package names, exact grants, typed channel policies and enabled state.
The entire document is validated before any restore; corrupt or unknown state
loads nothing, while a package-specific runtime failure is isolated and
logged. Partyline `off`, disable and unload remain immediate rollback and now
survive restart. Manifests stay default-off and no package gains authority from
installation alone.

MB767 performs the first promotion that depends on that ledger. `quotes-v3`
is loaded with exactly its four manifest capabilities, shadows on `#test`
before becoming authoritative, and uses disposable add, view and delete
evidence with one recall increment and exact cleanup. A clean restart must
restore the enabled lifecycle and `on` policy. Source remains default-off,
rollback is `off`, disable or unload, and production remains unchanged.

MB768 applies the same gate to production without promoting authority.
`quotes-v3` is persistent in `observe` on nbot `#i/o`; one bounded read-only
`on` request proves single-response parity, changes no quote row and returns to
observe before restart verification.

MB769 begins the second extraction wave with
`data.channel_activity.read`. The core offers only `compare` and `heatmap`,
derives the channel from the invocation, validates bounded periods and returns
opaque detached aggregates over the existing content-retention scope. Reads
may execute in observe, writes do not exist, and no package or command adopts
the authority in this milestone.

MB770 adopts that reviewed surface without widening it. The default-off
`channel-activity-v3` package requests only the activity read and IRC
reply/notice capabilities. `compare` and `heatmap` use the saved-handler
bridge, so observe retains one historical answer, on produces one v3 answer,
and off, disable or unload restores exact registry state. The development
pilot rolls back and persists no package posture.

MB771 accepts the separate promotion decision. The exact MB770 parity,
rollback and CommandAsync completion evidence is reused before
`channel-activity-v3` is loaded with only its three manifest grants and moved
from observe to on for development `#test`. The core ledger must restore that
enabled/on posture after restart while leaving the existing `quotes-v3`
promotion unchanged. Source stays default-off; production receives no policy.

MB772 records that restart persistence is insufficient if release rotation
drops the directory that owns it. The IRC updater now resolves
`plugins.DATA_DIR` from the selected instance configuration. Internal plugin
state is copied as one post-shutdown snapshot before activation; absolute
external state remains outside the rotating tree. Internal traversal,
symlinks and candidate/state merges are rejected. The updater preserves
operator intent but never creates it when the ledger is already absent.

MB778 starts the next functional promotion tranche with the already reviewed
`playful-v3` command pack. The development ledger retains its enabled/`on`
posture for `#test` across restart, while `quiet_magic` stays disabled and all
existing package entries remain unchanged. Source stays default-off and no
production policy is created.

MB781 continues that tranche with `short-content-v3`. The development `#test`
policy names one trusted HTTPS JSON endpoint while the core retains DNS,
transport, cache, size, timeout and repository authority. Observe remains
silent and write-free; on emits one bounded value and commits one revision.
The persistent posture survives restart, source stays default-off and
production remains unchanged.
