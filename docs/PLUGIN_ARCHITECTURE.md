# Mediabot plugin architecture

This document is the local, canonical entry point for Mediabot's plugin
platform. It records the MB740 baseline, the MB741 command catalogue, the
executable MB742 API v3 foundation, the MB743 event/scheduler boundary, the
MB744 channel policy, MB745's first reversible product plugin, MB746's shared
HTTP/repository boundary, MB747's first approved domain-data facade, MB748's
first reversible database-backed command migration, MB749's registry-native
built-in dispatch, MB750's read-only operator diagnostics, MB751's bounded
runtime failure history, MB752's explicit per-resource/channel quarantine,
MB753's quote-write authority, MB754's reversible `q`/`quote` adoption and
MB755's nullable anonymous-author repair, MB756's supervised short-content
pilot, MB757's namespace-safe API v3 repository cleanup, MB758's second
approved domain facade for bounded factoid reads and MB759's reversible pure
factoid-command adoption, followed by MB760's separate factoid-write authority
and MB761's reversible `learn`/`forget` adoption, MB762's bounded factoid
recall-counter authority, MB763's reversible `whatis`/`?keyword` adoption and
MB764's bounded portfolio plus first controlled development promotion.
It does not enable a plugin or grant a capability automatically.

## Current baseline

Mediabot currently supports three extension forms:

- trusted in-process Perl modules managed by `Mediabot::PluginManager`;
- trusted external Perl, Python and Tcl scripts executed without a shell across
  the `mediabot-script-v1` JSON boundary.
- experimental API v3 package directories with strict manifests, bounded
  contexts, versioned events, owned jobs and explicit load/enable lifecycle.

API v2 sidecars already have fail-closed manifests, bounded input and output,
transactional command/event mounting, lifecycle cleanup, controlled actions and
bounded JSON storage. The platform is technically substantial, but production
features still mostly live in large core modules.

The live command catalogue is generated in
[`generated/COMMAND_INVENTORY.md`](generated/COMMAND_INVENTORY.md). It shows the
public and private commands registered through `CommandRegistry`. Since MB749,
the registry entry also owns each executable built-in handler; the duplicate
public/private dispatch tables are gone. The operational rules are in
[`COMMAND_CATALOGUE.md`](COMMAND_CATALOGUE.md).

## Decision

Mediabot will evolve toward a small, stable core with first-party product
plugins. This is an incremental migration, not a rewrite.

The core owns:

- IRC connection state, wire output, pacing and flood protection;
- identity, authentication, authorization and security audit;
- command, event, scheduler and configuration registries;
- database migrations, secrets, HTTP policy and approved data services;
- plugin lifecycle, observability, quarantine and update safety.

Plugins may own optional product behavior such as games, social memory,
content, channel rituals and radio integrations. A plugin receives only the
facades and capabilities its manifest requests and the instance grants.

The effective permission model for API v3 is:

```text
manifest request
  INTERSECT instance grant
  INTERSECT channel policy
  INTERSECT runtime user authorization
```

No API v3 plugin receives the full Mediabot object, raw database access or a
general IRC socket.

## API v2 freeze

API v2 is frozen at the MB740 baseline. Its machine-readable reference is
[`../plugins/API_V2_CONTRACT.json`](../plugins/API_V2_CONTRACT.json).

Frozen means:

- existing v2 plugins remain supported during 3.6dev;
- security, lifecycle and regression repairs continue;
- v2 receives no new privileged action or broad service surface;
- new first-party plugins target API v3 after MB742;
- compatibility will be provided by an adapter before any v2 removal is
  considered.

External scripts are trusted code running with the bot account's operating
system permissions. Process separation and bounded JSON are not an operating
system sandbox.

## API v3 foundation

An API v3 package is a directory rather than a loose script pair:

```text
plugins/<slug>/
  plugin.json
  README.md
  lib/ or script/
  t/
  fixtures/          # optional
  migrations/        # official plugins only; never auto-applied at boot
```

The manifest declares compatibility, public/private commands and aliases,
versioned events, shared jobs, configuration schema and requested capabilities.
MB742 established fail-closed packages and bounded command invocations. MB743
adds copied event envelopes, bounded deferred delivery and scheduler-owned
jobs. MB744 activates the manifest configuration schema and places every
channel behind `off`, `observe` or `on`. `PluginContext` also retains bounded
`irc.reply` and `irc.notice`. MB745 adds `irc.channel_message` for scoped job
output through the normal core transport and flood gates. MB746 implements
`http.fetch` and `storage.kv`: outbound work crosses one TLS/DNS/timeout/cache
service and small state crosses a namespaced compare-and-swap repository.
MB747 implements `data.quotes.read` through six channel-scoped prepared read
operations and immutable records; it exposes neither SQL nor a database handle.
MB748 proves that boundary with `quotes-v3`: the three pure read adapters move
through the same reversible bridge used by the playful pilot, while mixed
read-write quote dispatch stays in the core.
MB749 retires the compatibility dispatch tables without changing that bridge:
the plugin manager captures the previous registry handler when an eligible
command is mounted and restores the exact entry on unload.
MB750 makes that runtime boundary explainable through detached reports: an
operator can inspect lifecycle, effective grants, mounted resources and the
exact per-channel decision without receiving configuration values or mutating
the plugin.
MB751 gives the same operator a bounded memory of command, event, job and HTTP
callback failures. It stores fingerprints rather than exception text, resets
per-resource streaks after success and disappears with the loaded instance;
it does not quarantine or reset anything.
MB752 adds the separately gated action that evidence can inform: an Owner may
isolate one manifest-declared command, event, job or HTTP callback on one
channel. Late guards contain queued work while unrelated resources continue.
The action is never threshold-driven, never persistent and never clears the
separate failure ledger.
MB753 closes the next authority gap before any mixed quote command moves. A
command invocation now carries a detached principal derived by the core, while
`data.quotes.write` exposes only bounded add/delete methods through a distinct
service. An opaque origin rejects plugin-created invocation lookalikes. The
channel and authorization are core-owned, writes require `on`, and the existing
`quotes-v3` package remains read-only in that milestone. MB754 adds the exact
bounded recall-counter mutation and adopts the two mixed commands without
changing the default-off lifecycle. MB755 aligns both write paths with the
canonical foreign key: registered authors retain their `USER` id, anonymous
authors use SQL `NULL`, and user deletion preserves quote text.
MB756 supplies live development evidence for the MB746 proof: observe stayed
silent without repository mutation, on exercised successful and repeated
fetches, neutral error paths stayed bounded, and rollback restored the prior
state. MB757 makes the cleanup portion explicit: an Owner command derives the
private v3 namespace in the core, remains idempotent and cannot collide with
legacy same-slug storage.
MB758 leaves the Quote Vault and opens `data.factoids.read`. Exact lookup,
bounded keyword listing and top-recall ranking cross a core-owned service;
plugins receive detached values rather than SQL or a database handle. Recall
counting and every factoid mutation remain outside this read-only milestone.
MB759 adds `factoids-v3`, still unloaded, disabled and channel-off by default.
Only `factoid` and `factoids` cross the saved-handler bridge; observation is
silent, activation is channel-scoped and unload restores the exact prior
registry entries. `whatis`, `learn`, `forget` and `?keyword` do not move.
MB760 closes the next authority gap without moving them. The distinct
`data.factoids.write` service exposes bounded upsert/delete operations only in
explicit `on`, derives channel, principal and display attribution from the
runtime invocation, and rejects forged invocations. Delete authorization uses
numeric authorship or core levels rather than nickname text. Recall mutation
remains unavailable; MB760 itself granted the capability to no package.
MB761 grants that existing write capability to `factoids-v3` and mounts only
`learn` and `forget` beside the two pure readers. `observe` suppresses the v3
write before the service and invokes the saved historical handler exactly
once; `on` performs one authorized mutation. `whatis` and `?keyword` remain
historical in MB761 because their recall counter needs a separate authority.
MB762 adds that one on-only channel-and-keyword-scoped increment to the
core-owned write service. MB763 mounts `whatis`; the existing `?keyword`
parser route enters the same handler. Observe leaves the saved historical path
solely visible and mutating, while on performs one read, increment and reply.
MB764 adds a single detached operator portfolio over installed and loaded v3
packages, then accepts `factoids-v3` on `#test` as the first instance-scoped
development promotion. MB766 replaces restart-as-rollback with a core-owned
operator ledger. Successful Partyline load, policy and lifecycle changes are
restored from local packages at boot; explicit `off`, disable and unload remain
the immediate and now persistent rollback controls.

Discovery reads manifests without loading entrypoints. Loading is explicit and
leaves the package disabled. Enabling separately invokes `start`, while disable
or unload invokes `stop`. API v3 is not connected to historical plugin AUTOLOAD;
its validated operator ledger is a separate boot stage after legacy loading.
MB772 carries the same ownership rule through release rotation: an internal
`plugins.DATA_DIR` is instance state and is copied only after the old process
stops, before the staged release becomes active. An absolute external data
directory remains outside the release tree. Candidate source may never supply
or merge plugin state, and internal symlink paths fail closed.
The complete executable contract is in
[`PLUGIN_API_V3.md`](PLUGIN_API_V3.md).

Planned capability families include:

| Capability | Core mediation |
| --- | --- |
| `irc.reply` / `irc.notice` | wire limits, invocation scope, pacing and flood gates |
| `irc.channel_message` | current policy channel only, late revocation and no stale deferred send |
| `events.subscribe` | version catalogue, copied fields, bounded queue and overflow accounting |
| `channel.topic` | explicit instance and channel grant plus runtime authorization |
| `moderation.kick` / `moderation.ban` | strict target scope and audit trail |
| `storage.kv` | namespaced, versioned, bounded writes with conflict handling |
| `scheduler.jobs` | ownership, quotas, cancellation and reload cleanup |
| `http.fetch` | TLS, timeout, size, redirect, private-address and quota policy |
| `secrets.read:<name>` | reference-based access without manifest or log disclosure |
| `data.channel_activity.read` | bounded compare/heatmap aggregates using the invocation channel |
| `data.quotes.read` | eight bounded channel-scoped reads returning detached records |
| `data.quotes.write` | on-only bounded add/delete/recall with a core-derived principal |
| `data.factoids.read` | exact lookup plus bounded list/top views without recall mutation |
| `data.factoids.write` | on-only bounded upsert/delete plus exact recall increment with core-owned scope and identity |
| `data.<domain>` | future approved repository methods instead of arbitrary SQL |

## Dependency boundary matrix

| Area | Current plugin access | API v3 direction | Owner |
| --- | --- | --- | --- |
| Bot object | full object for in-process plugins | unavailable | core |
| Commands | v2 public commands only | one declarative catalogue for public/private commands and aliases | core registry |
| Events | eight legacy routed events | eight versioned schemas, copied envelopes and bounded deferred queues | event catalogue |
| IRC output | bounded actions | capability-scoped output facade | core transport |
| Scheduler | core tasks plus route-v1 timers | shared owned jobs with quotas and lifecycle cancellation | core scheduler |
| Storage | v2 last-write-wins JSON document | MB746 namespaced KV with compare-and-swap/short transactions | data service |
| HTTP | per-feature clients outside v3 | MB746 bounded async client with cache and circuit breaker | HTTP service |
| Database | possible through full in-process bot | approved quote/factoid/activity reads and distinct authorized quote/factoid write services | data layer |
| Secrets | configuration may be reachable in-process | named secret references only | core configuration |
| Activation | global plugin lifecycle plus MB744 channel policy | `off`, `observe` or `on` per instance/channel | policy service |
| Health | lifecycle and metrics fragments | Doctor, reason, permissions, bounded failure history and explicit scoped quarantine | plugin runtime |

## Migration sequence

1. **MB740 — baseline:** architecture decision, v2 freeze, command inventory
   and dependency matrix. No runtime behavior changes.
2. **MB741 — command catalogue:** complete. All built-in names, sources and
   metadata are registered through one authoritative catalogue.
3. **MB742 — API v3:** complete. Strict `plugin.json` packages, bounded
   `PluginContext`/invocations, requested-intersect-granted capabilities,
   explicit lifecycle, an inert witness and a read-only v2 adapter are present.
4. **MB743 — events and scheduler:** complete. Eight versioned event schemas,
   immutable envelopes, deferred queues with backpressure and centrally owned
   jobs now follow the API v3 lifecycle.
5. **MB744 — channel policy:** complete. Typed configuration is validated by
   the core and per-channel `off`/`observe`/`on` activation is disabled by
   default, with late revocation for queued work and IRC output.
6. **MB745 — visible proof:** complete. `playful-v3` owns the six low-risk fun
   commands only where policy is `on`, shadows them in `observe`, restores the
   saved built-in handler in `off` or on unload, and adds one opt-in autonomous
   ritual for a single development channel.
7. **MB746 — HTTP and repository proof:** complete. One core service validates,
   pins, bounds, caches and cancels plugin HTTPS requests; a namespaced
   revisioned repository mediates small state. `short-content-v3` proves both
   while remaining unloaded, disabled and channel-off by default.
8. **MB747 — first domain-data facade:** complete. `data.quotes.read` provides
   `by_id`, `random`, `search`, `by_author`, `count` and `top` through the
   invocation channel. Results are detached, reads work in `observe`, and no
   quote command or write path moves yet.
9. **MB748 — reversible quote readers:** complete. `quotecount`, `topquote`
   and `halloffame` can shadow their built-in handlers in `observe`, become
   authoritative per channel in `on`, and restore exact handlers on unload.
   Literal author-prefix parity is mediated by the core. `q` and `quote` remain
   historical because their dispatch also contains writes.
10. **MB749 — registry-native built-ins:** complete. All 238 public and 94
    private built-ins store their executable CODE handler in `CommandRegistry`.
    The duplicate `%command_map` and `%command_table` paths are retired;
    reversible v3 migrations capture and restore registry entries directly.
11. **MB750 — operator diagnostics:** complete. Read-only Partyline views show
    readiness, capability intersection and the effective `off`/`observe`/`on`
    decision, including migration fallback visibility, without exposing typed
    configuration values or applying automatic remediation.
12. **MB751 — bounded failure history:** complete. One in-memory ledger per
    loaded package records command, event, job and HTTP-callback failures as
    non-sensitive fingerprints with bounded recent/resource cardinality.
    Partyline can inspect the history without changing readiness or lifecycle.
13. **MB752 — manual scoped quarantine:** complete. Owner-only controls isolate
    and release one declared runtime resource on one channel. A 64-entry
    instance-local registry and late guards contain queued work without global
    disable, automatic thresholds, durable state or evidence deletion.
14. **MB753 — quote-write authorization gate:** complete. Command invocations
    carry a detached core-derived principal and `data.quotes.write` exposes only
    bounded add/delete operations. Mutations require policy `on`; no package,
    quote command or live data adopts the capability yet.
15. **MB754 — reversible mixed quote commands:** complete. `q` and `quote`
    join `quotes-v3` behind the saved-handler bridge. Parity reads remain
    bounded, visible recalls use one explicit write operation, `observe`
    suppresses all v3 mutations, and the package remains inactive by default.
16. **MB755 — anonymous quote identity repair:** complete in source. The saved
    handler and v3 write service bind SQL `NULL` for anonymous authors; fresh
    schema and an idempotent migration use a nullable FK with `ON DELETE SET
    NULL`. Migration and a disposable anonymous live write were verified on
    the development service without promoting the channel.
17. **MB756 — supervised short-content pilot:** complete operationally.
    `observe` was silent and write-free; `on` exercised bounded success,
    repeated fetch, malformed-document and unavailable-endpoint paths. The
    prior repository state was restored and temporary identities were removed.
18. **MB757 — API v3 repository cleanup:** complete in source. Owner-only
    `clearv3data` derives the exact private key for short and hashed package
    names, is idempotent and preserves legacy same-slug storage.
19. **MB758 — factoid read authority:** complete in source. The distinct
    `data.factoids.read` capability provides exact lookup, a 60-key bounded
    list and a 10-entry top view through the invocation channel. Reads work in
    `observe`, never increment `hits`, expose no SQL and adopt no command.
20. **MB759 — pure factoid command adoption:** complete in source. The inert
    `factoids-v3` package adopts only `factoid` and `factoids`; `off`, disable
    and unload preserve the saved built-ins, while `observe` shadows without a
    second visible answer or recall mutation.
21. **MB760 — factoid-write authorization gate:** complete in source. The
    distinct `data.factoids.write` service accepts only bounded upsert/delete
    operations from runtime-issued invocations in policy `on`. Numeric author
    identity and core levels authorize deletion; no package, command, recall
    counter or live factoid adopts the capability.
22. **MB761 — reversible factoid-write commands:** complete in source.
    `factoids-v3` adopts `learn` and `forget` through the saved-handler bridge.
    `observe` cannot double-write, `on` uses one authorized core mutation, and
    rollback restores all four mounted handlers. Recall remains historical.
23. **MB762 — factoid recall-counter authority:** complete in source. The
    existing on-only factoid-write facade gains one exact normalized-keyword
    increment scoped by the invocation channel. Observe is suppressed before
    SQL, forged invocations remain rejected, and no command adopts it yet.
24. **MB763 — reversible factoid recall commands:** complete in source.
    `factoids-v3` mounts `whatis`; the unchanged `?keyword` parser route reaches
    the same saved-handler bridge. Explicit misses teach, quiet misses remain
    silent, and successful on-policy recalls answer and increment exactly once.
25. **MB764 — portfolio and controlled promotion:** complete operationally.
    `.plugins overviewv3` reconciles installed packages with live lifecycle,
    readiness and policy counts in one bounded read-only report. A disposable
    observe/on proof promotes only `factoids-v3` on `#test`; no boot autoload or
    production channel is changed, and explicit rollback remains immediate.
26. **MB766 — persistent v3 operator posture:** complete in source. A bounded,
    atomic core ledger restores exact grants, typed policies and enabled state
    after legacy plugin loading. Invalid whole-state input loads nothing;
    package failures are isolated; explicit unload removes the boot entry.
27. **MB767 — persistent quote promotion:** complete operationally. The full
    `quotes-v3` command set is authoritative on development `#test`, survives
    restart through the core ledger and retains explicit rollback.
28. **MB768 — production quote observation:** complete operationally. Nbot
    keeps `quotes-v3` enabled in `observe` on `#i/o`; one bounded read-only
    `on` request proved response parity without changing a quote row.
29. **MB769 — second extraction wave activity authority:** complete in source.
    `data.channel_activity.read` exposes only bounded, read-only `compare` and
    24-bucket `heatmap` aggregates. No package requests it and no command moves.
30. **MB770 — reversible activity adoption:** complete in source.
    The inert `channel-activity-v3` package adopts `compare` and `heatmap`
    through the saved-handler bridge. Observe keeps historical output solely
    visible; on is singular; off, disable and unload restore exact handlers.
31. **MB771 — persistent activity promotion:** complete operationally. The
    reviewed `channel-activity-v3` package remains enabled and authoritative
    only on development `#test`. Exact grants, lifecycle and policy survive a
    clean restart, zero failures are retained, and the quote promotion remains
    unchanged.
32. **MB772 — updater plugin-state preservation:** complete in source. IRC
    release rotation now preserves the configured internal plugin state,
    including the API v3 ledger, after shutdown and before activation. External
    state remains in place; traversal, symlinks and candidate merges fail
    closed.
33. **MB778 — persistent playful promotion:** complete operationally.
    `playful-v3` remains enabled and authoritative only on development `#test`.
    Exact grants, six saved handlers, the dormant autonomous job and zero
    failures survive restart while every existing ledger entry stays unchanged.

The first extraction wave and durable promotion mechanics are complete. MB778
opens the next functional tranche with the already reviewed playful command
pack while leaving production and autonomous output untouched.

## Extraction order

The first migration candidates are deliberately low-risk:

1. `roll`, `flip`, `choose`, `8ball`, `morse` and `abbrev`;
2. short external content through the MB746 shared HTTP proof;
3. pure quote reads through the MB747 facade and MB748 bridge, then writes as a
   separate gate.
4. pure factoid reads through the MB758 facade and MB759 reversible package,
   followed by MB760's separate upsert/delete authority, MB761's reversible
   `learn`/`forget` adoption, MB762's recall-counter authority and MB763's
   reversible `whatis`/`?keyword` adoption.

AI conversation, radio, central moderation, authentication, updater and IRC
transport are not first-wave extraction candidates.

## Delivery and rollback rules

- Plugins are inactive by default.
- The first activation is limited to a development channel.
- Enable, reload, disable and rollback must preserve historical behavior.
- Intermediate work runs syntax, targeted tests and the fast lane.
- The full suite runs once, immediately before the final commit.
- No plugin migration is applied automatically at bot startup.
- No remote catalogue may install executable code automatically.

The detailed v2 author guide remains in
[`../plugins/scripts/README.md`](../plugins/scripts/README.md). The v3 author
guide and executable contracts are in [`PLUGIN_API_V3.md`](PLUGIN_API_V3.md),
[`../plugins/API_V3_CONTRACT.json`](../plugins/API_V3_CONTRACT.json) and
[`../plugins/API_V3_EVENTS.json`](../plugins/API_V3_EVENTS.json).
