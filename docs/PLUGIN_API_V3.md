# Plugin API v3 author guide

Plugin API v3 remains experimental in MB744. Packages are discoverable and
explicitly loadable, but never activate at startup. MB744 adds strict typed
configuration and core-owned per-channel `off`, `observe` and `on` policy.
Production rollout remains a later milestone.

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
package, [`../plugins/API_V3_CONTRACT.json`](../plugins/API_V3_CONTRACT.json)
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
MB744 implements `irc.reply`, `irc.notice`, `events.subscribe` and
`scheduler.jobs`. Other capability names remain reserved for later mediated
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

Do not enable the witness package on a production instance. MB745 will define
the first supported development-channel rollout after channel policy exists.

## Compatibility

API v1/v2 execution is unchanged. `v2_adapter_for()` provides a normalized,
read-only descriptor for migration tooling; it does not run v2 code through the
v3 facade and does not expand v2 permissions.
