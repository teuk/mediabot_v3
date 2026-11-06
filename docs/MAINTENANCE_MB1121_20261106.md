# MB1121 — Quotegame channel identity

IRC channel names can arrive with different letter case in commands and
messages. A round started on `#Test` could ignore an answer on `#test`,
allow a duplicate start, or show an empty scoreboard for the same channel.

Quotegame now uses the lowercase channel key used by the channel cache for
its round, countdown and scores. Each command still replies to its original
target, and the countdown announces expiry on the channel spelling used to
start the round. The quote query keeps its original channel parameter.

The existing SQLite integration test exercises a duplicate start, a correct
answer, the scoreboard, stop and timer expiry with mixed-case channel names.
No configuration, schema or persisted data changes are needed.
