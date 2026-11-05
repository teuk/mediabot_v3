# MB1109 — Karma history follows channel identity

Karma scores and durable history are associated with the registered channel
ID. The in-memory ring was instead keyed by the spelling received in each
message. Two spellings of the same channel could have separate rings, and
queries or a channel purge could miss either one.

Writers and scoped readers now use the lowercase channel key already used by
the channel cache and karma admission. This applies to the IRC views, the
achievement fallback, Partyline history, and the report consumers in
SocialHistory, Radar and Affinity. The existing purge already addresses the
lowercase key. Original channel spelling remains available for replies and
logs. Global readers still combine distinct channels. No extra punctuation
equivalence is introduced.

The ring remains in memory and retains its 500-entry limit. No data migration,
configuration change or SQL update is required for deployment.

The native fixture writes through both the explicit and automatic vote paths,
with two spellings of the same channel and a vote for the same nick in another
channel. It checks durable scores and ring keys, six IRC views including
fallback after the log table is made unavailable, and Partyline history.
The checks fail against the original code. The duplicate per-target Bob check
was removed where a separate assertion already requires that only the intended
row changes.
