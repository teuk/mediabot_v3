# API v3 controlled development promotions

MB764 accepted the first reversible promotion evidence with `factoids-v3` on
`#test`. MB766 then gave reviewed API v3 posture a core-owned boot ledger.
MB767 uses that durable boundary for the next deliberately narrow step:
`quotes-v3` becomes authoritative on `#test` only. No production channel or
schema changes in this milestone.

## Acceptance evidence

Use an authenticated Owner Partyline session. Start from an unloaded package,
grant only its four manifest capabilities, and enter `observe` before `on`:

```text
.plugins overviewv3
.plugins loadv3 quotes-v3 data.quotes.read,data.quotes.write,irc.reply,irc.notice
.plugins policy quotes-v3 #test observe
.plugins enable quotes-v3
.plugins doctor quotes-v3
.plugins permissions quotes-v3
.plugins why quotes-v3 #test
```

In `observe`, use uniquely marked disposable quote text. The v3 branch stays
silent and write-free while the saved historical handler remains the only
visible and mutating path. Confirm exactly one add and one cleanup, then switch
to `on`:

```text
.plugins policy quotes-v3 #test on
.plugins why quotes-v3 #test
```

The authoritative proof covers a uniquely identifiable add, exact view and
authorized delete. The view must increment `hits` exactly once. Delete the
disposable quote and verify that neither its row nor the temporary operator
identity remains. Restart the development service and confirm that the exact
grants, enabled lifecycle and `on` policy return from the MB766 ledger.

Collect the final bounded posture:

```text
.plugins overviewv3
.plugins doctor quotes-v3
.plugins permissions quotes-v3
.plugins why quotes-v3 #test
.plugins failures quotes-v3
```

The accepted final state is one enabled, ready package with one `on` channel,
zero failures and no disposable data. Package source remains default-off.
The operator ledger, not the historical `plugins.AUTOLOAD` mechanism, restores
that posture after a clean restart.

## Immediate rollback

Explicit rollback is three bounded Partyline commands:

```text
.plugins policy quotes-v3 #test off
.plugins disable quotes-v3
.plugins unload quotes-v3
```

The first command immediately restores the saved historical handlers on the
channel; disable and unload end the instance and restore the exact registry
entries. These mutations are persisted. A restart restores the last committed
state; it is no longer a rollback mechanism. Unload is the definitive rollback
because it also removes the package from the next boot ledger.
