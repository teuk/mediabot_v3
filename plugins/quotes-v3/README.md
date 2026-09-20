# Quotes API v3 package

`quotes-v3` is the reversible API v3 home for the public quote commands
`q`, `quote`, `quotecount`, `topquote` and `halloffame`.

MB754 keeps the package unloaded, disabled and channel-off by default. In
`off`, the saved built-in handlers remain authoritative. In `observe`, the v3
path performs bounded reads but the core suppresses every add, delete and
recall-counter write; the historical handler alone remains visible and is the
only path allowed to mutate data. In `on`, the package becomes authoritative
for all five commands on that one explicitly selected channel.

The package receives detached quote records and a detached invocation
principal. It has no SQL, database handle, mutable user object, credentials or
raw IRC message. The core chooses the channel and enforces the existing quote
deletion rules. Disabling or unloading restores the exact registry entries
captured at load time.
