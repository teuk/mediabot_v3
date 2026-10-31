# MB1034 — Poll channel-case identity

The poll cache previously indexed every command with the raw channel spelling.
A poll created on `#TeSt` was therefore absent for `vote`, `pollstatus`,
`pollresult`, `pollvoters`, `unvote`, `pollextend` and `pollstop` on `#test` or
`#TEST`. Starting a poll through another spelling could also leave two slots
for the same channel, splitting the active question and ballots.

All eight poll cache operations now use the same lc-based channel key as the
project's channel cache. Replies and audit entries retain their original target.
The change does not assume a negotiated RFC1459 punctuation mapping or merge
punctuation-distinct cached names. Vote identity, weights, timeouts, expiry
rules, public/Master command policy and SQL are unchanged.

Thirteen assertions exercise the actual native command registry and Context,
including all eight handlers, weighted ballots, canonical cache cardinality,
original reply target, denied creation and other-channel independence. Eight
fail before correction; all thirteen pass afterward, without warnings.

The cache is process-local and not persisted. Install through the normal
development restart procedure; the patch does not migrate existing in-memory
polls during a hot code reload. No database schema/configuration or dependency
change is required. Delivery validation and its environment limits are recorded
in the package's QUALIFICATION.md.
