# Quotes API v3 package

`quotes-v3` is the reversible API v3 home for the public quote commands
`q`, `quote`, `quotecount`, `topquote` and `halloffame`.

MB754 keeps the package unloaded, disabled and channel-off by default. MB755
repairs anonymous additions in both the saved handler and the v3 write service:
an unauthenticated author is stored as SQL `NULL`, never as a fake user id.
In
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

Existing databases must apply
`install/migrations/20260921_quotes_anonymous_author.sql` before repeating the
write pilot or promoting a channel to `on`.

MB767 accepts the first persistent development promotion for this package on
`#test`. The operator posture is observe-first, then authoritative `on`, and is
restored from the core-owned API v3 boot ledger after a clean restart. Package
source stays default-off; no production channel is part of the promotion.
