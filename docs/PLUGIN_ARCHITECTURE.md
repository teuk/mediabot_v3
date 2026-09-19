# Mediabot plugin architecture

This document is the local, canonical entry point for Mediabot's plugin
platform. It records the MB740 baseline, the MB741 command catalogue, the
executable MB742 API v3 foundation, the MB743 event/scheduler boundary, the
MB744 channel policy, MB745's first reversible product plugin, MB746's shared
HTTP/repository boundary and MB747's first approved domain-data facade. It does
not enable a plugin or grant a capability automatically.

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
features still mostly live in central dispatch tables and large modules.

The live command catalogue is generated in
[`generated/COMMAND_INVENTORY.md`](generated/COMMAND_INVENTORY.md). It shows the
public and private commands registered through `CommandRegistry`, plus the
frozen legacy implementation adapters that remain during incremental handler
migration. The operational rules are in
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

Discovery reads manifests without loading entrypoints. Loading is explicit and
leaves the package disabled. Enabling separately invokes `start`, while disable
or unload invokes `stop`. API v3 is not connected to historical plugin AUTOLOAD.
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
| `data.quotes.read` | six bounded channel-scoped reads returning detached records |
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
| Database | possible through full in-process bot | MB747 approved quote reads; future domain repositories only | data layer |
| Secrets | configuration may be reachable in-process | named secret references only | core configuration |
| Activation | global plugin lifecycle plus MB744 channel policy | `off`, `observe` or `on` per instance/channel | policy service |
| Health | lifecycle and metrics fragments | Doctor, reason, permissions, latency and quarantine | plugin runtime |

## Migration sequence

1. **MB740 — baseline:** architecture decision, v2 freeze, command inventory
   and dependency matrix. No runtime behavior changes.
2. **MB741 — command catalogue:** complete. All built-ins are registered and
   legacy tables are reachable only as frozen adapters. No new entry may be
   added to the old dispatch.
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
   historical adapter in `off` or on unload, and adds one opt-in autonomous
   ritual for a single development channel.
7. **MB746 — HTTP and repository proof:** complete. One core service validates,
   pins, bounds, caches and cancels plugin HTTPS requests; a namespaced
   revisioned repository mediates small state. `short-content-v3` proves both
   while remaining unloaded, disabled and channel-off by default.
8. **MB747 — first domain-data facade:** complete. `data.quotes.read` provides
   `by_id`, `random`, `search`, `by_author`, `count` and `top` through the
   invocation channel. Results are detached, reads work in `observe`, and no
   quote command or write path moves yet.

Later milestones migrate quote reads through the reversible command bridge,
separate quote writes behind stronger authorization, improve developer tooling
and retire duplicate dispatch paths only after proven rollback.

## Extraction order

The first migration candidates are deliberately low-risk:

1. `roll`, `flip`, `choose`, `8ball`, `morse` and `abbrev`;
2. short external content through the MB746 shared HTTP proof;
3. quote reads through the MB747 facade, then writes as a separate gate.

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
