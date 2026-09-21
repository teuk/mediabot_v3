# Factoids API v3 package

`factoids-v3` is the reversible API v3 home for the bounded public readers
`factoid` and `factoids` plus the authorized writers `learn` and `forget`.

MB759 keeps the package unloaded, disabled and channel-off by default. In
`off`, the saved built-in handlers remain authoritative. In `observe`, the v3
path performs bounded reads without visible output, suppresses writes before
the mutation service, and the historical handler alone answers or mutates. In
`on`, the package becomes authoritative for all four commands on that
explicitly selected channel. Disabling or unloading restores the exact
registry entries captured at load time.

The package receives immutable factoid records, detached list/ranking values
and only the core-owned upsert/delete facade. It has no SQL, database handle,
mutable user, raw IRC message, credential or cross-channel selector. Reads
never increment `hits`; writes require policy `on` and core-derived identity.

`whatis`, its recall counter and the `?keyword` shortcut remain historical and
outside this package.

MB760 introduced the separate core-owned `data.factoids.write` boundary.
MB761 requests it for `learn` and `forget` only. The package remains inert by
default and can neither forge write identity nor authorize deletion by
nickname text.

The supervised development procedure lives in
[`../../docs/FACTOID_COMMAND_V3_PILOT.md`](../../docs/FACTOID_COMMAND_V3_PILOT.md).
