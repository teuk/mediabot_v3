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

MB770 deliberately did not retain another promotion. The inert
`channel-activity-v3` package was exercised on `#test` through `observe` and a
bounded `on` window, then returned through `off`, disable and unload. That
proved singular `compare` and `heatmap` output while keeping the ledger
unchanged.

## MB771 channel-activity development promotion

MB771 reuses that exact MB770 output and rollback evidence, including the
CommandAsync completion-barrier regression. An authenticated Owner performs
the persistent posture change with only the manifest grants:

```text
.plugins overviewv3
.plugins loadv3 channel-activity-v3 data.channel_activity.read,irc.reply,irc.notice
.plugins policy channel-activity-v3 #test observe
.plugins enable channel-activity-v3
.plugins doctor channel-activity-v3
.plugins permissions channel-activity-v3
.plugins why channel-activity-v3 #test
.plugins policy channel-activity-v3 #test on
.plugins why channel-activity-v3 #test
.plugins failures channel-activity-v3
```

Before and after a clean restart, `doctor` must report two mounted commands,
two saved handlers, one `on` policy and zero failures. `permissions` must expose
exactly the three approved capabilities. `overviewv3` must show both the
pre-existing `quotes-v3` promotion and `channel-activity-v3` as ready; MB771
must not replace, reload or otherwise disturb Quotes.

The final development posture is persistent `on` for `#test`. Source remains
default-off and the immediate rollback is:

```text
.plugins policy channel-activity-v3 #test off
.plugins disable channel-activity-v3
.plugins unload channel-activity-v3
```

No production channel is included. A production `observe` pilot remains a
separate decision.

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

## MB768 production observe pilot

Nbot repeated the same observe-first reasoning on production `#i/o` without a
write probe. In `observe`, one `!q stats` request produced exactly one response
from the saved historical handler. A bounded `on` window produced exactly one
response from `quotes-v3`, after which policy returned to `observe`.

The two existing quote rows were identical before and after the window.
Permissions were complete, failures stayed at zero, and a clean service
restart restored the enabled/`observe` posture. The final production state is
therefore evidence-backed but non-authoritative: the historical handler
remains visible, while `policy off`, disable and unload remain explicit
rollback.
