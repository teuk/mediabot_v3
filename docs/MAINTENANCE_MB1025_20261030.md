# MB1025 — Reproducible compatibility and the 3.8dev opening

The operator requested the next development line on 30 October 2026, after
publication of stable 3.7 at `204100217df9aec33da9438b507c0c83a498f917`.

## Runtime change

`!compat Alice Bob` keeps the 100 most frequent words for each participant
before computing vocabulary overlap. With more than 100 equally frequent
words, the old comparison returned equality and inherited Perl's randomized
hash iteration order. A restart or another insertion order could select a
different vocabulary and change both overlap and the final percentage.

Frequency now remains the primary ordering key and lexical word order resolves
equal counts. The cutoff, byte-safe tokenization, archive sampling, SQL, hourly,
karma and co-presence components, formatting and accounting stay unchanged.

Six native-handler assertions exercise multiple real Perl hash seeds, reversed
insertion order, higher-frequency words and small/empty vocabularies. Five fail
against the unmodified runtime. The fixtures use offline history rows rather
than an IRC connection or a live database.

## Source identity

The native format is `3.8dev-YYYYMMDD_HHMMSS`, opened with
`bash ./commit.sh --development 3.8`. It is not the unsupported literal
`3.8-dev` in VERSION. The delivery fixes one timestamp, obtains the native
version plan, tests that exact VERSION and passes the same timestamp to the
native commit helper. No manual post-commit VERSION adjustment is needed.

README body, security support table, command inventory and the existing
release identity guards follow 3.8dev. Stable 3.7 remains the supported release;
its README header/banner, published tag, assets and dedicated publisher are
preserved. Debian CI selects a non-publishable 3.9 rehearsal for 3.8dev, not a
stable 3.9 release. Existing stable-specific lineage checks keep their original
scope and the general fresh/3.3 upgrade gates continue.

The operator procedure runs the full Perl suite with visible `--progress`,
publication tests, mbweb tests, audits and inventory checks before restarting
only `mediabot@dev.service` and invoking native commit/push. A new stable PID
is process evidence; actual IRC reconnection is not inferred from that check.

No schema, migration, private configuration, plugin policy or production
instance changes are included.
