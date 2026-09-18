# Playful v3 pilot

`playful-v3` is MB745's deliberately small visible proof for the plugin
platform. It owns `8ball`, `abbrev`, `choose`, `flip`, `morse` and `roll` when
the selected channel policy is `on`.

The package is never loaded or enabled at startup. While it is disabled or a
channel policy is `off`, the frozen built-in adapter remains authoritative. In
`observe`, the plugin executes with output suppressed and the built-in command
still answers. Unloading the package restores the original registry entries.

The `quiet_magic` job can publish an occasional self-contained comic line. It
does not ask a question or require a reply. It is disabled by typed channel
configuration until an Owner explicitly sets `ritual_enabled=1`.

See `docs/PLAYFUL_V3_PILOT.md` for the staged operator procedure and rollback.
