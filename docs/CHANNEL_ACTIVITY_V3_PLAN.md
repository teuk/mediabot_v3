# Channel Activity API v3 Migration Plan 🔭📊

MB769 opens the second extraction wave with a read-only authority. It does not
move commands yet.

## Authority now available

- `compare`: two distinct bounded nicknames, an invocation-owned channel and
  `all` or a bounded day/week/month/year period.
- `heatmap`: one bounded nickname and exactly 24 hourly counters.
- Both read public/action history through the core content-retention policy.
- Both return opaque detached values and no SQL, handle or write operation.
- `observe` may read; `off` does not execute the plugin.

## Deliberate boundary

No package requests `data.channel_activity.read` in MB769. The historical
`compare` and `heatmap` commands remain the only live implementations. This
keeps authority review separate from dispatch migration and makes the next
step mechanically reversible.

## Next milestone

Create an inert `channel-activity-v3` package that requests only
`data.channel_activity.read` plus the exact IRC output capabilities needed by
`compare` and `heatmap`. Mount both commands through the saved-handler bridge,
prove singular output in `observe` and `on`, then roll back before deciding on
any retained development policy. No activity write capability is planned. 🗝️
