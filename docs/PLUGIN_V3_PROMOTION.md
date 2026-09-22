# API v3 first controlled development promotion

MB764 closes the first extraction wave by promoting exactly one reviewed
package on one development channel: `factoids-v3` on `#test`. Quotes remain
stable and operator-controlled. No production channel, schema, boot autoload
or second package is changed.

## Acceptance evidence

Use an authenticated Owner Partyline session. Start from an unloaded package,
grant only its four manifest capabilities, and enter `observe` before `on`:

```text
.plugins overviewv3
.plugins loadv3 factoids-v3 data.factoids.read,data.factoids.write,irc.reply,irc.notice
.plugins policy factoids-v3 #test observe
.plugins enable factoids-v3
.plugins doctor factoids-v3
.plugins permissions factoids-v3
.plugins why factoids-v3 #test
```

In `observe`, use a unique disposable keyword. The v3 branch stays silent and
write-free while the saved historical handler remains the only visible and
mutating path. Record the row and recall count, then switch to `on`:

```text
.plugins policy factoids-v3 #test on
.plugins why factoids-v3 #test
```

The authoritative proof must cover `factoid`, `factoids`, `learn`, `forget`,
`whatis` and `?keyword`. Explicit missing recall teaches, quiet missing recall
stays silent, and each successful explicit or quiet recall increments exactly
once. Delete the disposable factoid and verify that neither its row nor a
temporary operator identity remains.

Collect the final bounded posture:

```text
.plugins overviewv3
.plugins doctor factoids-v3
.plugins permissions factoids-v3
.plugins why factoids-v3 #test
.plugins failures factoids-v3
```

The accepted final state is one enabled, ready package with one `on` channel,
zero failures and no disposable data. Package source remains default-off.

## Immediate rollback

Explicit rollback is three bounded Partyline commands:

```text
.plugins policy factoids-v3 #test off
.plugins disable factoids-v3
.plugins unload factoids-v3
```

The first command immediately restores the saved historical handlers on the
channel; disable and unload end the instance and restore the exact registry
entries. API v3 still has no boot autoload, so a service restart is also an
implicit rollback to unloaded. Re-promotion after restart always requires a
fresh explicit Owner decision.
