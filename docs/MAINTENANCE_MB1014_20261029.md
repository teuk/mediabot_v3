# MB1014 — Revelio: recover namespaced feed articles 📰🪄

## Problem

The feed reader recognized a prefixed Atom root such as `<a:feed>`, but its
article loop only recognized unprefixed `<entry>` elements. A successful HTTP
fetch therefore returned an empty article list. The native poller could record
that empty result as a successful baseline or later poll, without announcing
the articles. Renaming a prefix to the default namespace could then reveal
old articles as if they were new, because the initial baseline stored none.

RDF/RSS had the same gap for prefixed `<r:item>` elements, and prefixed
`<r:channel>` elements bypassed the normal source-title boundary.

## Change

Only `Mediabot/RSS.pm` changes at runtime:

- Recognize optional prefixes on `item`, `entry` and `channel` structural tags.
- Match their closing tag to the opening qualified name.
- End the Atom feed-header scan before either prefixed or unprefixed entries,
  so an article title cannot become the source title when the latter is absent.

This extends the existing bounded reader; it does not introduce a general XML
parser, resolve external entities or change namespace-URI validation policy.
Existing DOCTYPE/ENTITY and NUL rejection remains in place.

No changes to HTTP destinations or DNS validation, conditional requests,
article identity, SQL schema, durable announced flags, quotas, automatic
rotation, output formatting, acknowledgements or retry policy are needed.
No private configuration or dictionary data is included.

## Regression coverage

`t/cases/1389_mb1014_rss_prefixed_entries.t` adds seven assertions; six fail
against the unmodified runtime:

- Prefixed Atom feeds match their default-namespace equivalents, including
  fields, article keys and absent source-title handling.
- Prefixed RDF/RSS channel and item structures retain titles and identity.
- Mixed namespace aliases preserve entry ordering, item bounds and latest
  article selection.
- The real fetch/decode/parser/poller path stores initial prefixed articles as
  already announced, without publishing historical articles.
- Renaming or removing prefixes does not duplicate or reannounce those items.
- Later polling announces only the eligible new article, suppresses overflow,
  retains validators and formats the complete matching title and URL.
- Ordinary RSS and the existing document rejection guards are preserved.

The integration fixture substitutes DNS/HTTP and the repository boundary;
production fetch, decoding, parsing, polling and formatting code runs locally.
No external server, production database or IRC connection is used.

## Validation and deployment

Run the focused RSS tests and then the full native suite with `--progress`.
Also run the security audit, startup integrity check and command inventory.
The delivery README records the actual local results and any failures also
reproduced on the unchanged snapshot.

Apply the patch to the supplied snapshot, validate it on teuk, restart only
`mediabot@dev.service`, then use the native `commit.sh` after all checks pass.
This delivery itself performs no remote deployment, commit or push.
