# Quote Reads v3 pilot

MB748 moves the first database-backed public commands through API v3 without
moving a write path. The `quotes-v3` package owns `quotecount`, `topquote` and
`halloffame` only after an operator explicitly loads it, grants its three
capabilities, selects one development channel and enables it.

`q` and `quote` remain historical. They combine reads with add, delete and
recall-counter writes, so they are outside this milestone.

## Safety properties

- the package defaults to `off` and is never autoloaded;
- the core supplies the invocation channel and prepared query;
- the package receives detached quote records, never DBI or SQL;
- author-prefix matching is literal, escaped and capped at 256 bytes;
- `observe` runs the v3 read silently while the legacy answer stays visible;
- `on` changes only the three declared commands on the selected channel;
- `off`, disable or unload restores legacy behavior immediately;
- unload restores the exact registry handler references;
- no configuration file, database schema or quote row is modified.

## Supervised development-channel pilot

Use an authenticated Owner Partyline session. Replace `#development` with the
single quiet development channel selected for the pilot.

```text
.plugins discoverv3
.plugins loadv3 quotes-v3 data.quotes.read,irc.reply,irc.notice
.plugins policy quotes-v3 #development observe
.plugins enable quotes-v3
.plugins info quotes-v3
```

While policy is `observe`, run representative IRC commands:

```text
!quotecount
!quotecount Al
!topquote
!topquote 10
!halloffame 3
```

Only the historical answers should be visible. The v3 path performs the same
bounded reads but its IRC output is suppressed. Confirm that the service stays
active, the bot remains connected, errors do not rise and no quote `hits`
value changes merely because of the comparison.

If parity is satisfactory, change only that channel:

```text
.plugins policy quotes-v3 #development on
.plugins info quotes-v3
```

Repeat the five commands. Counts, ordering, limits, identifiers, authors,
recall singular/plural and the empty-channel guidance should remain familiar.
Long UTF-8 quote text may be shortened to respect the API v3 400-byte output
gate.

## Rollback

The fastest channel rollback is:

```text
.plugins policy quotes-v3 #development off
```

To stop the package globally or remove every mounted adapter:

```text
.plugins disable quotes-v3
.plugins unload quotes-v3
```

After unload, `quotecount`, `topquote` and `halloffame` use the exact handler
objects saved before the pilot. No data or configuration restoration is
required because MB748 creates neither.

## Acceptance gate

The milestone may proceed to its final full-suite gate only after syntax,
contract, targeted and fast-lane validation pass, the Git surface is exact,
and the development service remains connected. The final workflow runs one
full suite immediately before commit and push.
