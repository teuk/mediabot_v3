# Reddit previews

`+Reddit` enables a dedicated Reddit preview on a channel. It is **off by
default**, including when the catalogue entry is absent. It is independent of
`+UrlTitle`: Reddit links are routed to this provider and do not also produce
a generic title preview. Other link providers retain their existing routing.

After the bot has loaded the new code, an authenticated Administrator or a user
with the usual channel level 450 can run:

```text
!chanset #channel +Reddit
```

Use `!chanset #channel -Reddit` to disable it. The first authorized activation
registers `Reddit` in the existing `CHANSET_LIST` catalogue if needed, then
enables only the requested channel. There is no schema change, migration,
new API key or private configuration setting. Installing the files alone does
not activate a channel or write to the database.

## Presentation

One compact line, for example (illustrative content):

```text
(Alice) [reddit] Une aurore au-dessus des montagnes · r/space · u/Astro · 42 pts · 7 commentaires · 23/10/2026 · image
```

The `[reddit]` badge uses the same IRC black on orange, with an immediate formatting
reset. The title is bold; separators and metadata use the client's normal
foreground and background. The complete line is limited to 400 UTF-8 bytes,
including IRC formatting. Long text is truncated without cutting a character;
formatting is closed at the end. No background colour extends beyond the badge.
The common output path still applies NoColors, badword filtering and antiflood.

The preview displays the public title and available community/author. A second,
optional request reads the static public iframe rendered by Reddit's own embed
widget. When provided, it adds the score, comment count, publication date (UTC),
content type and NSFW/spoiler labels. For a comment, its own score, date and reply
count are used; parent-post counters are not substituted. A hidden/absent count
is omitted rather than displayed as zero. Singular/plural labels are adjusted.
The date comes from the identified post/comment, never the embed generation date.
Low-priority details are omitted when necessary to preserve the title and the
400-byte total limit. Counts and labels are not guaranteed by oEmbed.

For a comment, use its own prose when the official embed provides it. The
optional iframe can supply prose even when the oEmbed envelope omits it. Code,
ASCII art and quoted-only bodies are not flattened into a misleading single
line. Some Reddit responses provide only a link to that comment, its author
and the parent post's title. Those are displayed explicitly as
`Commentaire sur « parent title »`, not as the comment's text. A response that
only identifies the parent post cannot stand in for the requested comment.

## Links and availability

Recognized links include:

| Link | Treatment |
| --- | --- |
| Posts, galleries, `redd.it/ID`, `/comments/ID`, user posts | Exact post ID; public oEmbed title and attribution |
| Comment permalinks, `?comment=ID`, `#t1_ID` | Separate post/comment identity and explicit comment presentation |
| `/r/name/s/token`, `/s/token`, `reddit.app.link` | Up to two redirects, validated at each hop; public metadata when resolvable |
| Communities, profiles, wiki and other public Reddit pages | Public HTML title/metadata when available |
| `i.redd.it`, `preview.redd.it`, `external-preview.redd.it`, `v.redd.it` | HEAD request only; media type/format, without downloading binary content |
| `/media?url=...` | Only an explicitly selected Reddit-owned media URL is unwrapped |

Old, new, mobile and language Reddit host variants share post/comment
identity. Tracking parameters do not create duplicate announcements. Media
URLs do not identify the parent post: no title or author is invented for them.
The existing router's first HTTP(S) link per message behaviour is preserved.

This is a public metadata preview, not a guarantee of access to every Reddit
page. Deleted/private content, login pages, rate limits, generic application
shells and network restrictions can prevent a rich preview. The bot then
produces one concise, correctly labelled unavailable preview. It does not
execute embedded scripts, fetch a login session or use a proxy to bypass a
restriction.

Posts/comments first use the public `www.reddit.com/oembed` endpoint. For an ID-only
link, the public `/r/all/comments/ID/` lookup route is used; the returned
permalink must still identify that exact post/comment, and supplies the real
community. A usable preview can then be enriched from the corresponding
`embed.reddit.com` iframe, the same source constructed by the official
`widgets.js`. It requires an exact-ID wrapper, matching structured entity and
matching event permalink. Bound counter elements are read without executing
scripts. This optional request does not follow redirects. A rejected,
unavailable, malformed or slow iframe leaves the basic preview usable; an
explicitly removed comment suppresses its stale body. A 429 response still
starts the instance cooldown. Public HTML is used for other pages. This provider does not call
Reddit's authenticated Data API or unauthenticated `.json` listing routes.
The User-Agent identifies Mediabot; TLS verification stays enabled. No Reddit
cookies or credentials are sent.

Official references:

- [Reddit embeds](https://support.reddithelp.com/hc/en-us/articles/360043033532-How-do-I-embed-a-Reddit-post-or-comment-in-an-article-or-other-publication)
- [Reddit's oEmbed announcement](https://www.reddit.com/r/redditdev/comments/34c0pm/devs_reddit_now_supports_oembed_for_comment_embeds/)
- [Reddit Data API requirements](https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki)

## Runtime limits

All HTTP runs in `AsyncWorker` children, outside the IRC event loop. Per
instance: at most four pending lookups and twelve launches per minute, sixteen
recipients per lookup, 128 cached results and 512 recent-delivery identities.
HTTP responses are capped at 512 KiB, worker output at 8 KiB, HTTP operations
at six seconds per operation, and the whole worker at thirty seconds. Optional
enrichment has an additional absolute six-second maximum and stops by the
twenty-sixth second of collection, leaving time to return the basic result.
An existing caller-owned alarm is preserved and optional enrichment is skipped.

Successful metadata is cached in memory for sixty seconds, unavailable results
for thirty seconds. Canonical duplicates are suppressed for five minutes per
channel. Nothing is cached on disk. A 429 response observes Retry-After, with
a sixty-second default and a one-day maximum, before launching more lookups.

Before sending, the provider rechecks the live channel flag, activation epoch
and IRC delivery context. Disabling/re-enabling the feature cannot revive an
old response. Reconnects, stale channel generations and shutdown also suppress
obsolete output. Replies use the common output guards with no deferred retry;
antiflood can therefore omit a preview instead of sending it much later.

## Acceptance tool

Classification only, with no network, configuration, database or IRC access:

```bash
perl tools/reddit_preview_check.pl --url 'https://redd.it/34c0pm'
```

Add `--live` to request public metadata and show a plain-text version of the
rendered preview. It still sends nothing to IRC and changes no configuration
or database data. Exit status is zero for usable metadata and one for
unavailable metadata. Invalid inputs and command-line errors return nonzero.

```bash
perl tools/reddit_preview_check.pl --live \
  --url 'https://www.reddit.com/r/redditdev/comments/34c0pm/'
```

Availability depends on the network running this tool; a successful local
probe does not prove the production IP has the same access to Reddit.
