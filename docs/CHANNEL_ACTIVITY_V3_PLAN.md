# Channel Activity API v3 Migration Plan 🔭📊

MB769 opened the second extraction wave with a read-only authority. MB770
adopts its first two commands without expanding that authority.

## Authority now available

- `compare`: two distinct bounded nicknames, an invocation-owned channel and
  `all` or a bounded day/week/month/year period.
- `heatmap`: one bounded nickname and exactly 24 hourly counters.
- Both read public/action history through the core content-retention policy.
- Both return opaque detached values and no SQL, handle or write operation.
- `observe` may read; `off` does not execute the plugin.

In MB769, no package requests this authority; `compare` and `heatmap` remain
historical until the separate MB770 adoption below.

## MB770 reversible adoption

The inert `channel-activity-v3` package requests only
`data.channel_activity.read`, `irc.reply` and `irc.notice`. It mounts `compare`
and `heatmap` through the `legacy-public-fallback` bridge. Installation changes
no lifecycle or channel policy.

The supervised development proof begins in `observe`: the v3 aggregate runs
without output while the saved historical handler remains solely visible. In
`on`, the package emits the same bounded comparison or heatmap and suppresses
the fallback. `off`, disable and unload form the immediate rollback path and
restore the exact saved handlers.

The pilot uses disposable nicknames with no retained activity, proves singular
output parity on `#test`, records zero failures and rolls back completely. No
package, policy, identity or data remains. No activity write capability exists
or is planned. 🗝️

## MB771 controlled development promotion

MB771 retains the already-proven package posture on development `#test`.
It reuses MB770's exact live evidence: one historical answer in `observe`, one
v3 answer in `on`, bounded five-line empty heatmaps, zero failures and complete
rollback. The CommandAsync reap/EOF barrier from MB770 is part of that accepted
evidence rather than a timing workaround.

An authenticated Owner loads the package with exactly its three manifest
capabilities, enters `observe`, then moves only `#test` to `on`. The core boot
ledger must contain the exact grants, enabled lifecycle and single policy. A
clean restart must restore both mounted commands, the authoritative decision
and zero failures. The existing `quotes-v3` development promotion must remain
ready and unchanged throughout.

The accepted final posture is therefore `channel-activity-v3` enabled with
`#test` in `on`. Source activation remains `off`; immediate rollback remains
`policy off`, disable and unload. Production is untouched, and any production
observation requires its own milestone. 🔐🔭
