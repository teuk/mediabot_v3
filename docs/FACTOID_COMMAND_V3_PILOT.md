# Factoid Commands v3 pilot

MB759 adds the inert `factoids-v3` package and moves the side-effect-free public
readers `factoid` and `factoids` behind the reversible API v3 migration bridge.
MB761 adds the separately authorized writers `learn` and `forget`. MB762 adds
the exact on-only recall-counter authority. MB763 mounts `whatis`; the existing
parser-level `?keyword` shortcut reaches that same handler.
Installing
the source still does not load, grant, enable or configure the package, and it
does not change a factoid row.

## Safety contract

- disabled and `off` dispatch the exact saved historical handlers;
- `observe` executes bounded v3 reads silently and suppresses the v3 write
  before the service; the historical handler supplies the only visible answer
  and the only mutation;
- `on` makes `factoid`, `factoids`, `learn`, `forget` and `whatis`
  authoritative on the selected channel;
- unload restores the exact five registry entries captured at load time;
- the package receives no SQL, DBI handle, mutable user, raw message,
  credential or cross-channel selector;
- explicit `whatis` misses retain their teaching notice, while missing
  `?keyword` shortcuts remain silent;
- successful observe recalls increment once through the historical fallback;
  successful on recalls increment once through the core-owned v3 authority.

MB760 adds the separately authorized `data.factoids.write` facade. MB761 lets
`factoids-v3` request it for bounded upsert and delete operations. MB762 adds
one channel-and-keyword-scoped recall increment to the same on-only facade but
does not call it from the package yet. Delete
uses authenticated numeric authorship, global Administrator authority or
channel level 400; matching nickname text is never authorization.

## Supervised development-channel pilot

Use an authenticated Owner Partyline session and one quiet development channel.
The first pilot target is `#test`.

```text
.plugins discoverv3
.plugins loadv3 factoids-v3 data.factoids.read,data.factoids.write,irc.reply,irc.notice
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
!whatis <disposable-keyword>
?<disposable-keyword>
!forget <disposable-keyword>
```

Each command must produce exactly one historical response sequence. The v3
shadow may read but must not emit a second answer or alter `hits`. `observe`
suppresses v3 writes before the service, so each disposable mutation and each
recall increment is performed once by the historical fallback, never twice.

After parity evidence, `on` may be tested on the same channel:

```text
.plugins policy factoids-v3 #test on
.plugins why factoids-v3 #test
```

Repeat detail, list, filtered-list and top reads. Then create one uniquely named
disposable factoid with `learn`, recall it once through explicit `whatis` and
once through `?keyword`, and remove it with `forget`. Each recall must produce
one channel reply and advance the stored counter by exactly one. Explicit
missing lookup must teach; quiet missing lookup must emit nothing. The
disposable factoid must be deleted before rollback.

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
`factoid`, `factoids`, `learn`, `forget` and `whatis` handlers must again occupy their
registry entries.

## MB764 promotion result

The completed MB759–MB763 command set is the first API v3 package accepted for
one controlled development promotion. MB764 repeats observe/on parity with a
uniquely named disposable factoid, verifies exact recall counts, removes that
row and leaves only `factoids-v3` on `#test` active. The retained state is
instance-scoped: the explicit rollback above is immediate, and a service
restart returns API v3 to unloaded because no boot autoload was introduced.
