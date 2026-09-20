# Plugin API v3 author guide

Plugin API v3 remains experimental in MB748. Packages are discoverable and
explicitly loadable, but never activate at startup. MB748 uses the first
core-owned domain-data facade for a reversible migration of three pure-read
quote commands, without exposing database handles or arbitrary SQL.

## Package layout

```text
plugins/my-plugin/
  plugin.json
  README.md
  lib/MyPlugin.pm
```

The directory name and manifest `name` must be the same lowercase slug. The
manifest and entrypoint must be regular files inside that directory; symlinks,
path traversal, unknown manifest fields and manifests over 16 KiB are rejected.

See [`../plugins/hello-v3`](../plugins/hello-v3) for the inert reference
package, [`../plugins/playful-v3`](../plugins/playful-v3) for the first pilot,
[`../plugins/short-content-v3`](../plugins/short-content-v3) for the HTTP/data
proof,
[`../plugins/quotes-v3`](../plugins/quotes-v3) for the first database-backed
command migration,
[`../plugins/API_V3_CONTRACT.json`](../plugins/API_V3_CONTRACT.json)
for the machine-readable boundary and
[`../plugins/API_V3_EVENTS.json`](../plugins/API_V3_EVENTS.json) for the event
schema catalogue.

## Minimal manifest

```json
{
  "api": 3,
  "name": "my-plugin",
  "version": "0.1.0",
  "description": "A small example.",
  "runtime": {
    "kind": "perl",
    "entrypoint": "lib/MyPlugin.pm",
    "class": "MyPlugin"
  },
  "activation": { "default": "off" },
  "capabilities": [
    "events.subscribe",
    "irc.reply",
    "scheduler.jobs"
  ],
  "commands": {
    "hello": {
      "source": "public",
      "help": "Say hello.",
      "level": 0,
      "handler": "command_hello",
      "aliases": []
    }
  },
  "events": [
    {
      "name": "scheduler.minute",
      "version": 1,
      "handler": "event_minute"
    }
  ],
  "jobs": {
    "heartbeat": {
      "handler": "job_heartbeat",
      "interval_seconds": 300,
      "first_delay_seconds": 30
    }
  },
  "config_schema": {
    "greeting": {
      "type": "string",
      "default": "Hello.",
      "min_length": 1,
      "max_length": 160
    },
    "mention_nick": {
      "type": "boolean",
      "default": false
    }
  }
}
```

Every field is validated fail-closed before plugin code is loaded. MB744 accepts
Perl entrypoints only. Event name/version pairs must exist in the core catalogue
and job handlers, intervals and namespace lengths are checked before any
registration. Configuration schemas are executable core contracts rather than
plugin-owned parsing hints.

## Typed channel configuration

`config_schema` accepts at most 32 named fields. Names are lowercase identifiers
and each field declares exactly one of `string`, `integer` or `boolean`.
Strings may use length bounds and an enum; integers may use minimum/maximum;
all types may declare a typed default or be required. Unknown schema properties,
unknown configured values and implicit string-to-number/boolean coercion fail
before plugin code runs. One effective channel configuration is capped at 4096
encoded bytes.

Defaults and operator overrides are normalized by the core. Every invocation
receives a detached snapshot through `config()` and `config_value($name)`; a
plugin cannot mutate the stored policy by changing that snapshot.

## Runtime boundary

Construction receives named arguments only:

```perl
sub new {
    my ($class, %args) = @_;
    return bless { context => $args{context} }, $class;
}
```

The object may implement `start(context => $context)` and
`stop(context => $context)`. Constructors must be side-effect free. `start`
runs only after an explicit enable; `stop` runs before disable or unload.

A command handler receives exactly:

```perl
sub command_hello {
    my ($self, $context, $invocation) = @_;
    return $context->reply($invocation, 'Hello.');
}
```

`Mediabot::PluginContext` exposes the plugin identity, capability inspection
and capability-checked services. `Mediabot::Plugin::InvocationV3` exposes only
bounded copies of nick, channel, command, arguments, source and private/public
state. It contains private output sinks that the plugin cannot inspect.

The invocation also exposes `activation_mode`, `config`, `config_value` and
`output_allowed`. In `observe` mode the handler executes, but reply/notice sinks
return without writing to IRC. The sink checks current policy again at emission
time, so a late switch to `off` or `observe` revokes output.

Event and job handlers receive equally narrow values:

```perl
sub event_minute {
    my ($self, $context, $event) = @_;
    my $minute = $event->get('minute');
}

sub job_heartbeat {
    my ($self, $context, $job) = @_;
    my $sequence = $job->sequence;
}
```

A job that requests and is granted `irc.channel_message` may emit only to its
own policy channel:

```perl
$context->channel_message($job, 'One bounded autonomous line.');
```

The core re-checks enablement and current `on` policy at emission time, then
uses Mediabot's normal sanitisation, pacing and flood path. `observe` suppresses
the line. The plugin receives no arbitrary target or IRC socket.

`EventEnvelopeV3` exposes `name`, `version`, `occurred_at`, `get` and a
detached `data` copy plus `policy_channel`, `activation_mode` and the typed
configuration snapshot. `JobInvocationV3` exposes `name`, `sequence`,
`scheduled_at`, `fired_at`, `lateness_seconds`, `channel`, `activation_mode`
and the same configuration accessors. Neither exposes a bot, socket, database,
raw IRC message or scheduler object.

The plugin never receives the Mediabot object, `Mediabot::Context`, the raw IRC
message, socket, database handle or configuration object.

API v3 Perl packages are trusted in-process code, not an operating-system
sandbox. The facade prevents accidental coupling and gives the core one policy
boundary; it does not protect the host from deliberately hostile Perl code.
Command failures are contained, logged and emit no IRC output.

## Shared HTTPS service

A package requesting and receiving `http.fetch` may submit a scoped GET through
`PluginContext::http_fetch($invocation, \%request, $callback)`. This is an
asynchronous service: the command handler returns while a core-owned worker
performs DNS resolution and network I/O away from the IRC event loop. The
callback receives an immutable `HTTPResponseV3`, never an HTTP client or
socket.

The service accepts HTTPS on port 443 only. It rejects credentials, fragments,
control characters, loopback, private, link-local, documentation and multicast
addresses. Every DNS result must be public, connections are pinned to the
validated address while preserving TLS hostname verification, ambient proxy
variables are cleared, and every redirect is revalidated. Bounds are two
redirects, ten seconds, 64 KiB and two concurrent requests per plugin.

Successful responses may enter a 128-entry process cache using a plugin-scoped
key and a caller TTL capped at one hour. Three transport, rate-limit or server
failures open a 60-second circuit. Disable or unload cancels owned workers and
changes a generation token; even an uncooperative late completion is discarded.
The current channel mode is checked again before the plugin callback. Observe
therefore exercises fetch and parsing while the invocation sink still suppresses
output.

Only a bounded `Accept` value is plugin-controlled. Arbitrary methods, headers,
cookies, credentials, proxy selection and request bodies are not part of MB746.

## Namespaced repository

A package requesting and receiving `storage.kv` may call
`storage_snapshot($invocation)` and `storage_commit($invocation, ...)`.
Snapshots contain a monotonic revision and at most 64 scalar values. A value is
limited to 2048 encoded bytes. Commits supply `expected_revision` plus bounded
changes/deletes; a stale revision returns `conflict` without writing.

The core writes the entire document through the existing 0600 atomic
temporary-file-and-rename boundary. The plugin sees no pathname or filehandle.
Reads are allowed in `observe` so behavior can be compared, while commits are
suppressed unless current policy is `on`. Repository errors are contained and
counted. This generic state is intentionally small; later `data.<domain>`
facades expose approved domain methods rather than SQL.

## Approved quote reads

A package requesting and receiving `data.quotes.read` may use six explicit
`PluginContext` methods: `quote_by_id`, `quote_random`, `quote_search`,
`quotes_by_author`, `quote_count` and `top_quotes`. Every method also receives
the current invocation. The core derives the database scope exclusively from
that invocation's current channel policy; the plugin cannot name another
channel, submit SQL or receive a database handle.
The service resolves the core's current handle for each operation, so a normal
database reconnect does not leave plugins attached to an obsolete connection.

Search text and authors are capped at 256 encoded bytes, searches accept at
most eight literal words, SQL wildcard characters are escaped, and list limits
range from 1 to 20. Results are immutable `QuoteRecordV3` objects containing
only `id`, `text`, `author`, `author_id`, `created_at` and `hits`. Lists and
hashes returned to plugin code are detached copies.

`quote_count` accepts an optional core-validated `author_match` value of
`exact` or `prefix`. Prefix mode lowercases the supplied author and treats SQL
wildcards as literal characters before adding its own trailing wildcard. It
exists solely to preserve the historical `quotecount <nick>` contract; it is
not a general query interface.

Reads are allowed in `observe` so a future migrated command can be compared
with its historical implementation. `off` remains inert. MB748 exposes no add,
delete, update or recall-counter operation; merely reading a record does not
change its `hits` value. Database failures are logged and counted by the core,
then returned as `{ ok => 0, error => "unavailable" }` without leaking a query
or driver diagnostic.

## Reversible quote-read migration

MB748 ships `quotes-v3`, disabled and channel-off by default. It declares only
`quotecount`, `topquote` and `halloffame`, each through
`legacy-public-fallback`. In `observe`, the plugin performs the bounded read
and suppresses its reply while the historical adapter remains visible. In
`on`, the plugin owns those three commands for the selected channel. Switching
the channel to `off`, disabling the package or unloading it restores the old
path; unload reinstates the exact saved registry handlers.

The mixed `q` and `quote` commands deliberately do not move. Their read forms
share dispatch with add, delete and recall-counter mutations, so migrating
them requires a later write capability, stronger authorization and its own
rollback gate. See [`QUOTE_READ_V3_PILOT.md`](QUOTE_READ_V3_PILOT.md) for the
single-channel operator sequence.

## Versioned events and backpressure

MB743 publishes version 1 schemas for:

- `command.public.observed`;
- `irc.channel.join`, `irc.channel.part`, `irc.channel.topic` and
  `irc.channel.kick`;
- `irc.nick.change` and `irc.user.quit`;
- `scheduler.minute`.

The core maps existing observations into field-whitelisted copies. References,
unknown fields and out-of-range integers are discarded. A plugin must request
and receive `events.subscribe`; otherwise its declared subscriptions remain
inert.

Delivery never runs a plugin handler inside the original EventBus callback.
Each plugin owns one deferred queue capped at 32 envelopes. Drains process at
most eight envelopes per turn. When full, the newest event is dropped and the
loss is logged and counted. Disable or unload clears pending work and
invalidates already deferred callbacks.

Channel-bearing events are delivered only to the matching non-`off` policy.
Global observations such as `scheduler.minute` are fanned out once for each
configured `observe` or `on` channel. Policy and configuration are re-read when
the deferred item drains; switching a channel to `off` revokes queued work.

## Shared jobs

Jobs are declarative, periodic and owned by the core scheduler. A plugin may
declare at most eight jobs. Intervals range from 5 to 86,400 seconds and the
optional first delay ranges from 0 to 86,400 seconds. Core task names use the
`plugin.v3.<plugin>.<job>` namespace and must fit the scheduler's 64-character
limit.

Loading reserves granted jobs without starting them. Enabling starts all owned
jobs transactionally; a failure rolls back already started jobs and the plugin
`start` hook. Disable stops them, and unload removes them. Job exceptions are
contained and recorded without stopping the scheduler. A declared job requires
the requested and granted `scheduler.jobs` capability.

Each scheduler firing fans out one bounded invocation per non-`off` channel.
All channel invocations for a firing share the same monotonic sequence number.
An enabled package with no opted-in channel therefore owns its timer but runs
no plugin job handler.

## Capabilities and activation

Effective permissions are the intersection of what the manifest requests and
what the operator grants. A grant not requested by the manifest is rejected.
MB748 implements `irc.reply`, `irc.notice`, `irc.channel_message`,
`events.subscribe`, `scheduler.jobs`, `http.fetch`, `storage.kv` and
`data.quotes.read`. Other capability names remain reserved for later mediated
services.

Discovery reads manifests only. Loading is explicit, leaves the package
disabled and mounts silent commands. Enabling is a second explicit operation,
but it still opts in no channel. Channel policy is a separate core-owned gate:

- `off` (default): no command, event or job handler runs;
- `observe`: bounded handlers run and IRC output is suppressed;
- `on`: bounded handlers and granted output may run.

Channel keys use RFC1459 casemapping. Policies are limited to 128 channels per
plugin and may be supplied transactionally at load or changed through
`set_v3_channel_policy`. `reset_v3_channel_policy` removes the override and
returns that channel to `off`.
There is no `plugins.AUTOLOAD` path for API v3 and no automatic migration.

The programmatic development flow is:

```perl
my @available = $bot->plugin_manager->discover_v3_packages;
my $entry = $bot->plugin_manager->load_package_v3(
    'my-plugin',
    grants => ['events.subscribe', 'irc.reply', 'scheduler.jobs'],
    channel_policies => {
        '#development' => {
            mode => 'observe',
            config => { greeting => 'Hello.' },
        },
    },
);
$bot->plugin_manager->enable('my-plugin');
$bot->plugin_manager->set_v3_channel_policy(
    'my-plugin', '#development', mode => 'on');
```

The Owner-operated flow is also available on Partyline through `discoverv3`,
`loadv3`, `policy` and `resetpolicy`. No v3 package is loaded at boot.

## Reversible built-in migration

An official command may declare `"migration": "legacy-public-fallback"` only
for a public level-0 command that currently resolves to a frozen built-in
adapter. The runtime rejects every other replacement.

- disabled or `off`: the historical adapter answers;
- `observe`: the v3 handler runs with output suppressed, then the historical
  adapter answers;
- `on`: the v3 handler owns the command in that channel;
- unload or failed multi-command mount: the exact registry entry is restored.

This bridge exists for measured migrations; new command names must register
normally and cannot use it.

## Compatibility

API v1/v2 execution is unchanged. `v2_adapter_for()` provides a normalized,
read-only descriptor for migration tooling; it does not run v2 code through the
v3 facade and does not expand v2 permissions.
