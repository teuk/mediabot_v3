# Factoids API v3 package

`factoids-v3` is the reversible API v3 home for the side-effect-free public
commands `factoid` and `factoids`.

MB759 keeps the package unloaded, disabled and channel-off by default. In
`off`, the saved built-in handlers remain authoritative. In `observe`, the v3
path performs bounded reads without visible output and the historical handler
alone answers. In `on`, the package becomes authoritative for both commands on
that explicitly selected channel. Disabling or unloading restores the exact
registry entries captured at load time.

The package receives immutable factoid records and detached list/ranking
values. It has no SQL, database handle, mutable user, raw IRC message,
credential, cross-channel selector or factoid mutation authority. Reads never
increment `hits`.

`whatis`, its recall counter, `learn`, `forget`, and the `?keyword` shortcut
remain historical and outside this package.

MB760 introduces a separate core-owned `data.factoids.write` boundary for
future adoption work. This package deliberately does not request it: its
manifest and current command set remain read-only and inert by default.

The supervised development procedure lives in
[`../../docs/FACTOID_COMMAND_V3_PILOT.md`](../../docs/FACTOID_COMMAND_V3_PILOT.md).
