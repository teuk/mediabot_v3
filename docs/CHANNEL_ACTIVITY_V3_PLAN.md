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
