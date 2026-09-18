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
