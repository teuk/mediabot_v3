# Mediabot plugin architecture

This document is the local, canonical entry point for Mediabot's plugin
platform. It records the MB740 baseline, the MB741 command catalogue and the
migration direction toward API v3. It does not enable a plugin or grant a new
capability.

## Current baseline

Mediabot currently supports two extension forms:

- trusted in-process Perl modules managed by `Mediabot::PluginManager`;
- trusted external Perl, Python and Tcl scripts executed without a shell across
  the `mediabot-script-v1` JSON boundary.

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

## Target API v3

An API v3 package will be a directory rather than a loose script pair:

```text
plugins/<slug>/
  plugin.json
  README.md
  lib/ or script/
  t/
  fixtures/          # optional
  migrations/        # official plugins only; never auto-applied at boot
```

The manifest will declare compatibility, commands, versioned events,
configuration schema and requested capabilities. A `PluginContext` facade will
expose only approved services such as bounded replies, namespaced storage,
scheduler jobs and policy-controlled HTTP.

Planned capability families include:

| Capability | Core mediation |
| --- | --- |
| `irc.reply` / `irc.notice` | wire limits, channel scope, pacing and flood gates |
| `channel.topic` | explicit instance and channel grant plus runtime authorization |
| `moderation.kick` / `moderation.ban` | strict target scope and audit trail |
| `storage.kv` | namespaced, versioned, bounded writes with conflict handling |
| `scheduler.jobs` | ownership, quotas, cancellation and reload cleanup |
| `http.fetch` | TLS, timeout, size, redirect, private-address and quota policy |
| `secrets.read:<name>` | reference-based access without manifest or log disclosure |
| `data.<domain>` | approved repository methods instead of arbitrary SQL |

## Dependency boundary matrix

| Area | Current plugin access | API v3 direction | Owner |
| --- | --- | --- | --- |
| Bot object | full object for in-process plugins | unavailable | core |
| Commands | v2 public commands only | one declarative catalogue for public/private commands and aliases | core registry |
| Events | eight unversioned routed events | named schemas with versions and channel policy | event catalogue |
| IRC output | bounded actions | capability-scoped output facade | core transport |
| Scheduler | route-v1 timers only | shared owned jobs with limits and cancellation | core scheduler |
| Storage | last-write-wins JSON document | namespaced KV with compare-and-swap/short transactions | data service |
| HTTP | no shared plugin service | bounded async client with cache and circuit breaker | HTTP service |
| Database | possible through full in-process bot | approved domain repositories only | data layer |
| Secrets | configuration may be reachable in-process | named secret references only | core configuration |
| Activation | global plugin enable/disable | `off`, `observe` or `on` per instance/channel | policy service |
| Health | lifecycle and metrics fragments | Doctor, reason, permissions, latency and quarantine | plugin runtime |

## Migration sequence

1. **MB740 — baseline:** architecture decision, v2 freeze, command inventory
   and dependency matrix. No runtime behavior changes.
2. **MB741 — command catalogue:** complete. All built-ins are registered and
   legacy tables are reachable only as frozen adapters. No new entry may be
   added to the old dispatch.
3. **MB742 — API v3:** introduce `plugin.json`, `PluginContext`, capabilities
   and the v2 adapter.
4. **MB743 — events and scheduler:** versioned event schemas, shared jobs and
   backpressure.
5. **MB744 — channel policy:** typed plugin configuration and per-channel
   `off`/`observe`/`on` activation, disabled by default.
6. **MB745 — visible proof:** move the simple fun-command pack and ship one new
   autonomous channel ritual on a single development channel.

Later milestones add the HTTP/data facades, extract richer first-party
features, improve developer tooling and retire duplicate dispatch paths only
after proven rollback.

## Extraction order

The first migration candidates are deliberately low-risk:

1. `roll`, `flip`, `choose`, `8ball`, `morse` and `abbrev`;
2. short external content after the shared HTTP service exists;
3. quotes after the approved data facade exists.

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
guide will be added with MB742, when its executable contract exists.
