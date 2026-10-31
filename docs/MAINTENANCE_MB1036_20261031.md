# MB1036 — Operator cooldown identity

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_104544.zip`.
Base: `e2a8aa519d1249069b5c72b3d6fec7bdc8f15cbc` (MB1035),
VERSION `3.8dev-20261031_094035`.

The parent cooldown guard groups actualites/actualite/actu/news under actualites,
but the partyline setter previously stored and reset the typed alias. A setting
such as `.cmdcooldown #test news 0` therefore claimed removal while the default
45-second guard still applied. Channel case variants could similarly leave a
setting under a different key from its live admission check. Finally, the
no-argument listing existed in the command handler but was unreachable through
the dispatcher, which required arguments.

The setter and guard now share one small command-key function and lowercase
channel identity. Configuration and active-timestamp reset address the admitted
group; confirmation retains the typed channel and alias. The dispatcher accepts
the existing no-argument listing. Defaults, explicit caller overrides, 0..3600
range handling, authentication flow, other commands and channels are preserved.
Zero remains an explicit disabled override, not deletion that restores a default.

Sixteen assertions exercise real partyline lines through the dispatcher and
native Helpers admission checks with a controlled clock. Ten fail before the
fix; all sixteen pass afterward. They cover four aliases, channel case, reset,
exact deadlines, zero, listing, range/priority, malformed input and no warnings.
They open no listener and call no IRC provider or database.

These operator overrides are process-local, as before. The dev restart in the
delivery starts fresh state; operators can reapply their chosen overrides.
There is no migration of old mixed-case/alias keys during hot code reload.
No change to SQL/schema, configuration files, radio/YouTube or released assets.
The native commit flow retains automatic 3.8dev VERSION handling.
