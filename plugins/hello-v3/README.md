# hello-v3

`hello-v3` is the inert witness package for Mediabot Plugin API v3.

It requests only `irc.reply`, declares one public `v3hello` command and starts
disabled. Merely discovering the package does not load its Perl code, register
its command or change IRC behavior. An operator must explicitly load it, grant
`irc.reply` and enable it.

The plugin receives `Mediabot::PluginContext` and a bounded invocation. It never
receives the Mediabot object, the IRC socket, a raw message or a database handle.
