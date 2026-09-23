# channel-activity-v3

An inert API v3 package for the first two channel-activity commands in the
second extraction wave.

It requests only:

- `data.channel_activity.read` for the core-owned comparison and 24-bucket
  heatmap aggregates;
- `irc.reply` for historical-format channel output;
- `irc.notice` for syntax and neutral database errors.

`compare` and `heatmap` use the reversible saved-handler bridge. Installation
does not load, enable or configure the package. In `observe`, v3 reads run with
all v3 output suppressed and the historical handlers remain solely visible.
In `on`, the package becomes authoritative only on that policy channel. `off`,
disable or unload restores the exact saved handlers.

No activity write capability exists. The package receives no SQL, database
handle, raw message, hostmask or caller-selected channel.

MB771 promotes this package only on development `#test`, after MB770's bounded
observe/on parity and rollback evidence. The private core ledger restores the
exact three grants, enabled lifecycle and `on` policy after restart. Manifest
activation remains default-off, production remains unchanged, and `policy
off` followed by disable and unload is the explicit persistent rollback.
