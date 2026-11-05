# MB1104 — Retire cooldown state after a committed channel purge

## Fault and correction

Public command cooldowns store timestamps under command:channel, for example
ai:#mixed and actualites:#mixed. purgeChannel_ctx removed only bare channel
keys from that map. The SQL purge could succeed while command reservations
remained in memory; re-registering the channel could inherit those old blocks.
The old source/mirrored tests mentioned the map but did not use its real keys.

After the existing purge transaction commits, inspect each public cooldown key.
Read the complete channel after its first colon, normalize its case and delete
only keys belonging to the purged channel. The command prefix does not decide
scope. Preserve similar names, other channels, private admission and the
historical bare-key cleanup. Names containing punctuation or additional colons
are compared as complete identities, without regex interpretation or suffix
matching against another channel.

No cleanup moves before SQL commit. Archive/cascade/commit failures, rejected
begin calls, caller-owned transactions and access/argument refusals preserve
the complete runtime state and send no PART. Existing archive fields, cascade
order, nicklist timers, other caches and success notices retain their behavior.

## Native tests and consolidation

Reuse MB933AdminFixture and its real SQLite transactions, triggers and deferred
constraints. Seed realistic composite cooldown keys in every existing failure
scenario. Strengthen the committed-purge group to compare the complete cache
projection against expected target removal and other-channel retention.

One new group runs ten purge/re-registration cycles: five channel spellings,
including punctuation and a colon, through both native facades. Reserve real
ai/news/custom cooldowns, including the news-to-actualites alias. Verify repeat
admission is blocked, purge commits, all target command reservations disappear,
and private/other-channel state remains exact. Re-register the channel row and
runtime object, then require fresh admission followed by a new normal block.
Similar channel names and a colon-containing suffix lookalike remain reserved.
No waiting, mocked cooldown calculation or new test process is introduced.

The existing failure groups now protect composite reservations as part of the
full cache snapshot. Remove ten source pins from case 386 and 23 copied cleanup
assertions from case 387; the actual purge and all those cache projections are
checked natively. Keep the unrelated Claude cleanup and PART/logout checks.
One grouped assertion replaces 33 old assertions: 32 fewer assertions, with no
new test file, dependency, schema, configuration or public command.

## Operator workflow

The delivered scripts verify the exact cumulative qualified state, run the
targeted tests, visible full suite with --progress, security/startup/inventory
checks and diff checks. Only then restart mediabot@dev.service and require a
new positive PID stable ten seconds before interactive commit.sh. VERSION is
left to its native automatic 3.8dev plan. A stable PID does not prove IRC
reconnection. No production instance is operated by this package.
