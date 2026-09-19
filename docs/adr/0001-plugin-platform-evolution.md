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
- some duplication remains until MB749 retires compatibility dispatch.

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
