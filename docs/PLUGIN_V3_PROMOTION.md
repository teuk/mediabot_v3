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

## MB778 playful development promotion

MB778 reuses MB745's reviewed six-command migration and promotes
`playful-v3` on development `#test` only. The Owner sequence is observe-first:

```text
.plugins loadv3 playful-v3 irc.reply,irc.notice,irc.channel_message,scheduler.jobs
.plugins policy playful-v3 #test observe language=fr ritual_every=4 ritual_style=subtle
.plugins enable playful-v3
.plugins doctor playful-v3
.plugins permissions playful-v3
.plugins why playful-v3 #test
.plugins policy playful-v3 #test on language=fr ritual_every=4 ritual_style=subtle
.plugins why playful-v3 #test
.plugins failures playful-v3
```

The omitted boolean retains the typed `ritual_enabled=false` default, so the
registered `quiet_magic` job remains dormant. Before and after restart,
`doctor` must show six commands, six saved handlers, one job, one active `on`
policy and zero failures. Every existing ledger package is fingerprinted and
must remain unchanged.

Rollback remains explicit and persistent:

```text
.plugins policy playful-v3 #test off
.plugins disable playful-v3
.plugins unload playful-v3
```

Source remains default-off and production remains untouched.

## MB781 short-content development promotion

MB781 reuses the supervised MB756 proof and promotes `short-content-v3` on
development `#test` only. The channel policy names one trusted HTTPS endpoint,
one scalar JSON path and bounded output/cache settings:

```text
.plugins loadv3 short-content-v3 http.fetch,irc.reply,storage.kv
.plugins policy short-content-v3 #test observe endpoint=https://api.github.com/repos/teuk/mediabot_v3 json_path=name prefix=MB781- language=en cache_ttl_seconds=0 max_chars=80
.plugins enable short-content-v3
.plugins doctor short-content-v3
.plugins permissions short-content-v3
.plugins why short-content-v3 #test
.plugins policy short-content-v3 #test on endpoint=https://api.github.com/repos/teuk/mediabot_v3 json_path=name prefix=MB781- language=en cache_ttl_seconds=0 max_chars=80
.plugins why short-content-v3 #test
.plugins failures short-content-v3
```

Observe must produce no public line and no repository change. The first `on`
request must produce one exact `MB781-mediabot_v3` line and one repository revision
containing only `last` and `served`. Doctor then reports one command,
zero failures and the complete three-capability grant before and after a clean
restart. Every pre-existing ledger entry remains byte-for-byte equivalent.

Rollback is explicit and persistent:

```text
.plugins policy short-content-v3 #test off
.plugins disable short-content-v3
.plugins unload short-content-v3
```

Source remains default-off, the endpoint is operator-owned typed policy and no
production channel is included.

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

## MB782 and MB783 short-content production gates

MB782 begins with `short-content-v3` absent from production, loads only
`http.fetch`, `irc.reply` and `storage.kv`, and enters `observe` on `#i/o`.
The observe request is silent and repository-write-free. One bounded `on`
request returns `MB782-mediabot_v3`, after which the repository is restored,
policy returns to observe and the exact posture survives restart.

MB783 reuses that acceptance, repeats the silent observe request and promotes
`short-content-v3` on production `#i/o` to persistent `on`. The authoritative
request returns `MB783-mediabot_v3` and retains exactly one bounded repository
revision. Quotes, Channel Activity, Factoids and Playful remain byte-for-byte
equivalent; all five enabled/on postures return after restart with zero
failures.

The package-scoped rollback is unchanged:

```text
.plugins policy short-content-v3 #i/o off
.plugins disable short-content-v3
.plugins unload short-content-v3
```

MB784 records those two accepted gates in source and tests only. It contacts no
production service and grants no additional authority.
