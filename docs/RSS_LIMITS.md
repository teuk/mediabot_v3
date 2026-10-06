# RSS news at a quiet pace

Control a registered destination from the console channel:

```text
!rss #35+ans limit gap=180 daily=3
!rss #35+ans add LeMonde https://www.lemonde.fr/rss/une.xml interval=30 max=1
!rss #35+ans limit
!rss #35+ans info LeMonde
```

If the feed already exists, apply only `limit` and inspect it with `info`.
Changing limits does not require deleting and recreating the feed.

`gap=180` means at least 180 minutes between automatic RSS news on **the whole
channel**, regardless of feed. `daily=3` allows at most three attempts in any
rolling 24-hour window, rather than resetting at midnight. These are ceilings,
not a promise of three news every day. A recent pending item from a successful
poll is needed; the first successful poll remains silent.

`interval=30` checks the feed every 30 minutes. It does not promise publication
every 30 minutes. With channel limits active, only one recent candidate per
feed is kept, even when a feed's historical `max` setting exceeds one. The
remaining new entries and superseded pending entries are suppressed durably.
No backlog is drained in a burst when the gap expires or the bot restarts.

With channel limits active, available feeds take turns in a stable circular
rotation. The feed label, SQL polling order and HTTP response speed do not give
a source priority. The scheduler waits for that channel's in-flight polls to
finish, then selects the next ready feed after the previous reserved turn.
Empty, failed, deleted or disabled feeds do not hold a turn. A ready candidate
can be selected even when its feed's next poll is not yet due.

The rotation cursor is saved with the existing private pacing state, alongside
the quota history. Restarting, updating or changing limits does not reset it.
Existing state without a cursor is accepted and keeps its limits and history;
its first turn establishes the cursor. After a restart, candidates are prepared
again by successful polls. Only the newest known pending article per feed is
eligible; a refreshed article replaces that feed's previous candidate.

No extra command or database migration is required. With four continuously
ready feeds and `gap=180 daily=6`, successive allowed slots cycle through those
four sources, rather than letting the fastest source take every slot. A feed
without news is skipped, so equal shares are conditional on availability.

A slot is recorded before attempting the IRC send. A rejected send therefore
consumes a slot conservatively. The item remains pending until replaced or a
later allowed scheduler attempt; acknowledgements still happen only after output acceptance.
Paced announcements use a single payload of at most 400 UTF-8 bytes; titles are
trimmed to fit. If an unshortened URL cannot fit, the article is skipped rather
than split into several lines. Paced announcements never enter the deferred
AntiFlood queue. Missing/corrupt/busy initialized pacing state holds RSS output.
Manual `show` and `probe` previews on protected channels are private, so they do
not bypass the public news cap.

## Preview the latest article

```text
!rss latest LeMonde
!rss #35+ans latest LeMonde
!rss latest #35+ans LeMonde
```

`latest` reads the selected feed afresh and displays exactly one article with
its title and link. It compares usable zoned publication dates among the first
100 readable entries; ties preserve feed order. Without usable dates, it uses
the first readable entry. The automatic per-poll `max` setting does not affect
this preview, and disabled subscriptions can be tested without enabling them.

The response goes to the **issuing channel**, even when the feed belongs to
another destination. Thus `!rss #35+ans latest LeMonde` in the console replies
in the console, not on #35+ans. If the issuing channel itself has RSS limits,
the preview goes privately to the requester. Private commands also stay
private. Feed/HTTP/format errors are private. Private `latest`, `show` and `probe`
previews use ordinary NOTICE text with IRC styling, without a CTCP ACTION
envelope; WeeChat displays them as normal notices. Public announcements keep
their existing ACTION format.

Identify to Mediabot as User or higher. A 15-second cooldown applies to latest
in the issuing channel, shared across feed choices. News fit in one IRC line.
Fetching/parsing/shortening uses the existing asynchronous and safe HTTP path.
The preview does not insert/acknowledge items, set polling timestamps, reserve
news slots, or reset counters/baselines; the next automatic poll still uses
its own durable deduplication and limits.

## Adjust, inspect, pause

```text
!rss #35+ans limit gap=240 daily=2
!rss #35+ans limit
!rss #35+ans set LeMonde enabled off
!rss #35+ans set LeMonde enabled on
```

The first command allows at most one news every four hours, and two per rolling
24 hours. The second privately reports the policy, attempts in the last 24
hours, and the remaining wait. Setting only `gap` or only `daily` preserves the
other value and the recorded history. Disabling/re-enabling a feed or changing
limits never clears the channel history.

- `gap`: `0` disables the minimum gap; otherwise `5` to `10080` minutes.
- `daily`: `0` disables the 24-hour cap; otherwise `1` to `24`.
- Both zero restore the historical per-feed behavior, including multiple news
  per poll. Use this only when that behavior is desired.
- Existing channels remain on their existing per-feed settings until limits
  are explicitly configured.

Both command orders work:

```text
!rss #35+ans add LeMonde https://www.lemonde.fr/rss/une.xml interval=30 max=1
!rss add #35+ans LeMonde https://www.lemonde.fr/rss/une.xml interval=30 max=1
!rss #35+ans limit gap=180 daily=3
!rss limit #35+ans gap=180 daily=3
```

`list`, `info`, `add`, `del`, `set`, `show`, `latest` and `limit` accept the channel-first
form. `probe` remains URL-only. Without a channel, channel commands use the
issuing channel. An explicit destination uses that channel's access rules,
not the console's: identify to Mediabot and have destination channel level
400+ or global Administrator privileges to change subscriptions or limits.
Console acknowledgements stay in the console; policy status is private.

## Instance state and promotion

The core keeps `.rss-pacing.json` and its lock in `plugins.DATA_DIR` (default:
`plugin-data`, relative to the bot's working directory). They are private
instance data, not Git source or a plugin. The existing updater already keeps
this directory during `m update now`. Limits and history survive a restart or
an update of the same instance. No SQL migration is required.

Dev and production keep their own data. Testing a limit on dev does not set
production limits. After promoting code with `m update now`, issue the desired
`limit` command on the production bot **before** adding/enabling the feed.
Do not run two bots publishing this feed to the same production channel.

## Dev checks

Test on a dedicated dev salon, avoiding unsolicited test articles on #35+ans.
You can temporarily use `gap=5 daily=2` there. Confirm that the baseline is
silent, no second feed publishes inside five minutes, and restart the dev
instance while waiting to confirm its remaining wait is retained. Restore the
intended `gap=180 daily=3` on the real destination after validation.

Targeted automated checks:

```bash
perl t/test_commands.pl --filter '1171|1172|1173' --progress
```

Before committing, run the full suite visibly:

```bash
perl t/test_commands.pl --progress
```

Use the local `commit.sh` for VERSION, commit and push. This change does not
update production; promotion remains the operator's `m update now` step.
