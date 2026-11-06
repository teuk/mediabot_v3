# MB1122 — RSS announcement acknowledgement

Without a channel pacing policy, RSS could treat acceptance into the volatile
AntiFlood queue as a successful announcement. If that queue was lost before
delivery, the article was no longer pending in the database. The legacy path
could also attempt a send while IRC was disconnected.

The automatic RSS publisher now checks for a connected transport before each
send and requests immediate delivery in both pacing modes. A refusal does
not update `announced_at`; the existing polling schedule can pick up the
pending article again. This is local acceptance, not an acknowledgement from
the IRC server.

The change preserves pacing intervals, quotas, rotation and the global
AntiFlood policy. No database migration or configuration change is required.
The existing repository test combines SQLite with the real IRC sender to
verify both refusal cases and exactly one successful retry.
