# MB1044 — Complete nicklist pages within the IRC byte budget

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_162346.zip`.
Base: `3e129827100a46817014b66b56668edbb77dcfb5` (MB1043),
VERSION `3.8dev-20261031_152332`.

The Administrator nicklist handler removed ten entries from its temporary list,
joined them, then truncated a long line. Entries beyond the cutoff were lost
instead of appearing on the next page. Its character-length check also allowed
Unicode pages to exceed the intended wire-byte budget. The final debug count
read the consumed temporary list and incorrectly reported zero users.

The handler now groups whole nicknames before numbering pages. Each page has
at most ten entries and uses a conservative 360-byte budget including its page
label. The label reserves enough counter digits for the complete result count,
including listings exceeding 99 pages. Existing valid IRC nicknames fit on an
individual page. Byte counting reuses IRC::TextBudget so character strings and
legacy UTF-8 byte strings follow the existing transport representation.

The source cache is never consumed or reordered. Ordinary short-nickname pages,
result headers, target-channel spelling/fallback, empty and unknown replies,
authentication and Administrator authorization retain their existing behavior.
Debug logging now reports the captured original count.

Sixteen assertions call the real ChannelCommands handler. Only context/user
objects, outbound notices and logging are replaced with local sinks. They check
complete ordered output, UTF-8 byte limits, page numbering beyond 99, the
ten-entry cap, access refusal, unchanged caches/counts and warnings. No SQL,
IRC connection, child worker or listener is used.

The historical pagination lint now expects the two remaining ChannelCommands
truncation sites. The nicklist site was deliberately replaced with whole-name
packing; its behavior is checked by case 1417. Every lint assertion and the
repository-wide ban on raw substr truncation remains active.

The operator flow requires the entire visible --progress suite and native
audits before restarting only dev. A new PID must remain active/stable for ten
seconds before the native interactive commit.sh performs automatic 3.8dev
commit/push. VERSION is not manually edited. Process stability does not prove
IRC reconnection. No production, schema, configuration, dependency, project
README/banner, radio or YouTube change.
