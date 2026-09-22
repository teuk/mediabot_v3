# Quote Commands v3 pilot

MB754 moves `q` and `quote` into the existing `quotes-v3` package while
preserving the exact saved built-in fallback. The package remains unloaded,
disabled and channel-off by default. No schema, private configuration or live
quote row changes merely by installing MB754.

MB755 is a required rollout repair discovered by the first `#test` observation:
anonymous additions used the historical `id_user=0` sentinel even though the
canonical schema enforces a foreign key to `USER`. Apply
`install/migrations/20260921_quotes_anonymous_author.sql` and deploy the MB755
code before resuming the write pilot. Anonymous attribution is SQL `NULL` in
both the saved handler and API v3 service.

## Safety contract

- `off` and disabled use the saved historical handler;
- `observe` executes bounded v3 reads, suppresses v3 IRC output and blocks
  `add`, `delete` and `recall` before the mutation service;
- the historical handler stays visible in `observe` and is therefore the only
  path that may mutate quote data during comparison;
- `on` makes all five package commands authoritative only on the selected
  channel;
- unload restores the exact five registry entries captured at load time;
- the plugin receives no SQL, DBI handle, mutable user, raw message, password
  or hostmask.
- anonymous quote authors use nullable attribution; account deletion preserves
  quote text and clears only its attribution.

## Supervised development-channel pilot

Use an authenticated Owner Partyline session. Replace `#development` only if a
different single quiet channel has been selected deliberately.

```text
.plugins discoverv3
.plugins loadv3 quotes-v3 data.quotes.read,data.quotes.write,irc.reply,irc.notice
.plugins policy quotes-v3 #development observe
.plugins enable quotes-v3
.plugins permissions quotes-v3
.plugins why quotes-v3 #development
```

In `observe`, exercise representative reads and writes:

```text
!q view <existing-id>
!q search <literal text>
!q random
!q stats
!quote <nick>
!quote count
!q add <unique disposable text>
```

Only historical answers must be visible. The v3 path must report suppressed
writes, with no duplicate add and no extra `hits` increment from the shadow.
Do not test deletion in `observe` unless the selected quote is explicitly
disposable: the visible historical handler remains authoritative there.

If an anonymous `add` returns `Database error while adding quote.`, stop before
promotion: the MB755 schema/code pair is missing or incomplete.

After comparing logs, counters and output, an operator may choose `on` for the
same channel:

```text
.plugins policy quotes-v3 #development on
.plugins why quotes-v3 #development
```

Repeat the reads, then add one uniquely identifiable disposable quote. Record
its returned id, view it once, confirm its `hits` rises once, delete that exact
id with an authorized account, and verify that it is gone. Do not promote any
other channel in this milestone.

## Immediate rollback

The channel rollback is one policy change:

```text
.plugins policy quotes-v3 #development off
```

Global lifecycle rollback remains:

```text
.plugins disable quotes-v3
.plugins unload quotes-v3
```

After unload, `q`, `quote`, `quotecount`, `topquote` and `halloffame` must use
the exact handler references saved before the pilot. Quote rows created during
an intentional `on` test are application data and must be removed explicitly
by their recorded ids; lifecycle rollback does not rewrite data.

## MB767 accepted persistent development promotion

MB767 promotes `quotes-v3` on `#test` only after an observe-first parity pass.
The authoritative proof uses disposable text, verifies one add, one exact view,
one recall increment and one authorized delete, then confirms that no probe row
or temporary identity remains.

The final accepted posture is `quotes-v3` enabled with exactly its four
manifest capabilities and policy `on` for `#test`. A clean service restart must
restore the package as ready with all five commands mounted and zero failures.
This state is held by the core-owned API v3 boot ledger; source installation
remains default-off and no production channel is promoted.
