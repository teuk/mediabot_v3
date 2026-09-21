# Factoid Commands v3 pilot

MB759 adds the inert `factoids-v3` package and moves the side-effect-free public
readers `factoid` and `factoids` behind the reversible API v3 migration bridge.
MB761 adds the separately authorized writers `learn` and `forget`. Installing
the source still does not load, grant, enable or configure the package, and it
does not change a factoid row.

## Safety contract

- disabled and `off` dispatch the exact saved historical handlers;
- `observe` executes bounded v3 reads silently and suppresses the v3 write
  before the service; the historical handler supplies the only visible answer
  and the only mutation;
- `on` makes `factoid`, `factoids`, `learn` and `forget` authoritative on the
  selected channel;
- unload restores the exact four registry entries captured at load time;
- the package receives no SQL, DBI handle, mutable user, raw message,
  credential or cross-channel selector;
- `whatis` and `?keyword` remain historical, including all recall-counter
  behavior.

MB760 adds the separately authorized `data.factoids.write` facade. MB761 lets
`factoids-v3` request it for bounded upsert and delete operations only. Delete
uses authenticated numeric authorship, global Administrator authority or
channel level 400; matching nickname text is never authorization.

## Supervised development-channel pilot

Use an authenticated Owner Partyline session and one quiet development channel.
The first pilot target is `#test`.

```text
.plugins discoverv3
.plugins loadv3 factoids-v3 data.factoids.read,data.factoids.write,irc.notice
.plugins policy factoids-v3 #test observe
.plugins enable factoids-v3
.plugins doctor factoids-v3
.plugins permissions factoids-v3
.plugins why factoids-v3 #test
```

In `observe`, run representative existing reads and one disposable write pair:

```text
!factoid <existing-keyword>
!factoids
!factoids <literal-or-glob-pattern>
!factoids top
!learn <disposable-keyword> = <disposable-value>
!forget <disposable-keyword>
```

Each command must produce exactly one historical response sequence. The v3
shadow may read but must not emit a second answer or alter `hits`. `observe`
suppresses the v3 write before the service, so each disposable mutation is
performed once by the historical fallback, never twice.

After parity evidence, `on` may be tested on the same channel:

```text
.plugins policy factoids-v3 #test on
.plugins why factoids-v3 #test
```

Repeat detail, list, filtered-list and top reads. Then create one uniquely named
disposable factoid with `learn` and remove it with `forget`. Their visible text
must retain the historical contract, the stored value must be exact, and the
disposable factoid must be deleted before rollback. Do not exercise `whatis` or
the quick `?keyword` shortcut as part of v3 adoption; neither is mounted by
this package.

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

Rollback changes no remaining factoid row. After unload, the exact historical
`factoid`, `factoids`, `learn` and `forget` handlers must again occupy their
registry entries.
