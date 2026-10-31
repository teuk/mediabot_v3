# MB1035 — Consistent seven-day karma graphs

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_101949.zip`.
Base: `16e8871c8a59e280652f5a879722fb7d554027a8` (MB1034),
VERSION `3.8dev-20261031_090327`.

The public `karmgraph [nick]` command confused a zero daily net with no votes.
It also rounded negative ages toward zero before excluding future timestamps,
so a vote one second in the future appeared in today's bucket. Its separate
net calculation accepted every future timestamp, including entries that the
graph itself omitted. Missing cached deltas could create a phantom negative
bucket while being excluded from the displayed net.

The graph now counts included observations separately, tests the exact rolling
seven-day interval before bucketing and computes its net from the rendered
buckets. A balanced history produces a zero-net graph. Cached entries missing
a timestamp or delta are ignored consistently. This is a read-only projection;
it does not remove history or modify a vote, database score or timestamp.

Thirteen assertions exercise the actual command registry, Context and handler.
Six fail on the unchanged source; all thirteen pass after correction. They
cover cancellation, future seconds/days, exact seven-day and daily boundaries,
case-insensitive nickname targeting, channel isolation, incomplete records,
optional arguments, the public-channel guard, warnings and immutable history.

The seven positions remain rolling 24-hour buckets rather than calendar days.
No SQL/schema, provider, configuration, dependency or radio/YouTube change.
The delivery uses the full --progress suite, native audits and dev-only restart
before the native automatic 3.8dev commit flow. VERSION is not edited manually.
