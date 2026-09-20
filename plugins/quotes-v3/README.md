# Quotes API v3 package

`quotes-v3` is the first reversible migration of quote commands onto the
approved `data.quotes.read` facade. It owns only the purely read-only public
commands `quotecount`, `topquote` and `halloffame`.

The package is never loaded or enabled automatically. In `off` and `observe`,
the historical adapters remain visible. In `on`, these three commands use the
API v3 service. Disabling or unloading restores the exact historical registry
entries.

The mixed `q` and `quote` commands remain in the core because they contain add,
delete and recall-counter writes. They require a later, separately authorized
write milestone.
