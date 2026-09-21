# Factoid Commands v3 pilot

MB759 adds the inert `factoids-v3` package and moves only the side-effect-free
public readers `factoid` and `factoids` behind the reversible API v3 migration
bridge. Installing the source does not load, grant, enable or configure the
package, and it does not change a factoid row.

## Safety contract

- disabled and `off` dispatch the exact saved historical handlers;
- `observe` executes bounded v3 reads silently, then the historical handler
  supplies the only visible answer;
- `on` makes only `factoid` and `factoids` authoritative on the selected
  channel;
- unload restores the exact two registry entries captured at load time;
- the package receives no SQL, DBI handle, mutable user, raw message,
  credential, cross-channel selector or write capability;
- `whatis`, `learn`, `forget` and `?keyword` remain historical, including all
  recall-counter behavior.

MB760 adds a separately authorized `data.factoids.write` facade, but
`factoids-v3` does not request it and this read-only pilot does not exercise it.
No factoid command or channel policy is promoted by that authority milestone.

## Supervised development-channel pilot

Use an authenticated Owner Partyline session and one quiet development channel.
The first pilot target is `#test`.

```text
.plugins discoverv3
.plugins loadv3 factoids-v3 data.factoids.read,irc.notice
.plugins policy factoids-v3 #test observe
.plugins enable factoids-v3
.plugins doctor factoids-v3
.plugins permissions factoids-v3
.plugins why factoids-v3 #test
```

In `observe`, run representative existing reads:

```text
!factoid <existing-keyword>
!factoids
!factoids <literal-or-glob-pattern>
!factoids top
```

Each command must produce exactly one historical response sequence. The v3
shadow may read but must not emit a second answer or alter `hits`.

After parity evidence, `on` may be tested on the same channel:

```text
.plugins policy factoids-v3 #test on
.plugins why factoids-v3 #test
```

Repeat detail, list, filtered-list and top reads. Their visible text must retain
the historical contract. Do not exercise `whatis`, `learn`, `forget` or the
quick `?keyword` shortcut as part of v3 adoption; they are not mounted by this
package.

## Immediate rollback

The channel rollback is one policy change:

```text
.plugins policy factoids-v3 #test off
```

Global lifecycle rollback remains:

```text
.plugins disable factoids-v3
.plugins unload factoids-v3
```

Rollback changes no factoid row. After unload, the exact historical `factoid`
and `factoids` handlers must again occupy their registry entries.
