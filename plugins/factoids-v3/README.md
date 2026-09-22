# Factoids API v3 package

`factoids-v3` is the reversible API v3 home for the bounded public readers
`factoid` and `factoids`, the authorized writers `learn` and `forget`, and the
mixed read/recall command `whatis`. The existing parser-level `?keyword`
shortcut reaches that same mounted handler.

MB759 keeps the package unloaded, disabled and channel-off by default. In
`off`, the saved built-in handlers remain authoritative. In `observe`, the v3
path performs bounded reads without visible output, suppresses writes before
the mutation service, and the historical handler alone answers or mutates. In
`on`, the package becomes authoritative for all five commands on that
explicitly selected channel. Disabling or unloading restores the exact
registry entries captured at load time.

The package receives immutable factoid records, detached list/ranking values
and only the core-owned upsert/delete/recall facade. It has no SQL, database
handle, mutable user, raw IRC message, credential or cross-channel selector.
Reads never increment `hits`; writes require policy `on` and core-derived
scope.

MB763 adopts `whatis`; the unchanged `?keyword` parser route follows it through
the registry. A successful recall emits one bounded channel reply and requests
one exact core-owned counter increment. An explicit missing `whatis` keeps its
teaching notice, while a missing `?keyword` remains completely silent.

MB760 introduced the separate core-owned `data.factoids.write` boundary.
MB761 requests it for `learn` and `forget`. The package remains inert by
default and can neither forge write identity nor authorize deletion by
nickname text. MB762 added the core recall operation; MB763 consumes it without
changing the default-off lifecycle or granting the package any direct SQL.

The supervised development procedure lives in
[`../../docs/FACTOID_COMMAND_V3_PILOT.md`](../../docs/FACTOID_COMMAND_V3_PILOT.md).
