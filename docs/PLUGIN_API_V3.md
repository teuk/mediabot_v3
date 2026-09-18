# Plugin API v3 author guide

Plugin API v3 is experimental in MB742. This milestone makes packages
discoverable and explicitly loadable, but never activates them at startup.
Events, scheduling, channel policy, typed configuration and production rollout
belong to later milestones.

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
package and [`../plugins/API_V3_CONTRACT.json`](../plugins/API_V3_CONTRACT.json)
for the machine-readable boundary.

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
  "capabilities": ["irc.reply"],
  "commands": {
    "hello": {
      "source": "public",
      "help": "Say hello.",
      "level": 0,
      "handler": "command_hello",
      "aliases": []
    }
  },
  "events": [],
  "config_schema": {}
}
```

Every field is validated fail-closed before plugin code is loaded. MB742 accepts
Perl entrypoints only. Declared events and configuration schemas are validated
metadata; no event subscription or plugin configuration service is active yet.

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

The plugin never receives the Mediabot object, `Mediabot::Context`, the raw IRC
message, socket, database handle or configuration object.

API v3 Perl packages are trusted in-process code, not an operating-system
sandbox. The facade prevents accidental coupling and gives the core one policy
boundary; it does not protect the host from deliberately hostile Perl code.
Command failures are contained, logged and emit no IRC output.

## Capabilities and activation

Effective permissions are the intersection of what the manifest requests and
what the operator grants. A grant not requested by the manifest is rejected.
In MB742 only `irc.reply` and `irc.notice` have executable facades; the other
names are reserved for later mediated services.

Discovery reads manifests only. Loading is explicit, leaves the package
disabled and mounts silent commands. Enabling is a second explicit operation.
There is no `plugins.AUTOLOAD` path for API v3 and no automatic migration.

The programmatic development flow is:

```perl
my @available = $bot->plugin_manager->discover_v3_packages;
my $entry = $bot->plugin_manager->load_package_v3(
    'my-plugin',
    grants => ['irc.reply'],
);
$bot->plugin_manager->enable('my-plugin');
```

Do not enable the witness package on a production instance. MB745 will define
the first supported development-channel rollout after channel policy exists.

## Compatibility

API v1/v2 execution is unchanged. `v2_adapter_for()` provides a normalized,
read-only descriptor for migration tooling; it does not run v2 code through the
v3 facade and does not expand v2 permissions.
