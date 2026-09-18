# hello-v3

`hello-v3` is the inert witness package for Mediabot Plugin API v3.

It declares one public `v3hello` command, one versioned minute event and one
periodic heartbeat job. It requests only `irc.reply`, `events.subscribe` and
`scheduler.jobs`, and starts disabled. Merely discovering the package does not
load its Perl code, reserve its surfaces or change IRC behavior. An operator
must explicitly load it, grant capabilities and enable it.

The plugin receives `Mediabot::PluginContext` plus bounded command, event and
job values. It never receives the Mediabot object, IRC socket, raw message,
scheduler, configuration or database handle.
