# MB1064 — Latest matching karma history

## Defects

The database returned twenty votes in descending timestamp order, then
mbKarmaHist_ctx reversed them before taking five. Busy channels displayed the
oldest five of that window instead of the newest five. Filtering by nick after
the SQL limit also reported no history for a player whose votes were displaced
by twenty newer votes for other players.

The memory fallback had a different ordering contract: each channel ring was
appended oldest-first, but private history concatenated multiple rings and
reversed them without comparing timestamps. It could display older votes ahead
of newer votes from another channel. A failed database fetch could leave a
partial list advertised as a successful persistent read.

## Implementation

Bind channel and optional normalized nick in SQL before the existing twenty-row
limit. Use timestamp descending and the existing id_karma_log descending for
deterministic same-second ordering. Keep that database order for the five-entry
display. No schema or index is changed.

For memory only, sort descending by epoch after reversing insertion order;
Perl's stable sort retains last-in-first-out ties within each ring. Private
history merges all existing rings before applying its nick filter and limit.
Reuse the channel label for empty/unmatched output so private requests do not
interpolate an undefined channel or append a misleading channel suffix.

Decide read success before finish, reject prepare/execute/fetch failures and
discard partial rows. Keep the existing optional-table/empty-result memory
fallback and its [memory] label. Cleanup remains best-effort and does not
discard a complete successful read. This does not introduce new SQL writes.

## Validation and scope

Replace the existing fourteen source/prose checks in
t/cases/236_usercommands_karmahist.t with fourteen native assertions through the
real public command registry and an isolated SQLite database. Cover recent
five-entry ordering, header counts and ages, nick filtering beyond twenty
unrelated votes, channel isolation, bound quoted input, same-second ties,
persistent precedence, partial fetch failure whose finish clears the error,
throwing cleanup, absent optional table, memory ordering/ties, merged private
history, empty replies and warnings. No new case file or assertion growth.

The snapshot already contains MB1062 and MB1063. Preserve those changes and any
previous qualified pending paths. VERSION and the private commit.sh are left
unchanged; the native helper continues the 3.8dev flow. The operator modop runs
the full suite with --progress/ETA, security/startup/inventory checks, then
dev-only restart and native commit/push only after success. No production
service, application dependency, configuration, database schema or vote
accounting behavior is changed. See package qualification for local results.
