# MB930 — Opt-in Reddit previews

Base: `snap_mediabot_v3_teuk_20261023_162143.zip`,
VERSION `3.6dev-20261023_134926`.

Add `Mediabot::External::Reddit` as the owner of public Reddit URL classification,
metadata lookup, parsing, bounded rendering and async delivery. The URL router
delegates recognized Reddit hosts before its existing provider branches.
`+Reddit` is independent of `+UrlTitle`, off by default, with authorized lazy
registration in the existing chanset catalogue. There is no DDL, migration,
private configuration or VERSION change.

The black-on-orange badge, bold title and theme-neutral metadata occupy one
UTF-8-safe line of at most 400 bytes. Exact post/comment identity is checked
against the source permalink. Quoted links cannot replace attribution. An
official comment embed that omits the body is explicitly presented as a comment
on its parent title. Generic/login/error pages are not presented as content.

Reuse `Mediabot::AsyncWorker`, `Mediabot::JSON`, `IRC::Text`, `IRC::TextBudget`,
`IRC::DeliveryContext` and the common output guards. HTTP/worker sizes,
parallelism, launch rate, caches, duplicates, recipients and Retry-After are
bounded. Activation epochs and delivery context prevent stale output after
policy changes or reconnects. Media uses HEAD, never binary downloads.

One case file adds 32 grouped behavioural scenarios plus an isolated-probe
assertion. Existing case files are retained. The fixture covers URL families,
HTTP/parser boundaries, spoofed metadata, byte budgets, real authorized chanset
commands against SQLite, callback ownership, limits, revocation and native
IO::Async success/timeout/reaping. Public post/comment oEmbed and ID-only lookup
were also exercised on the real endpoint. Local community/profile pages did
not expose usable metadata; the documented unavailable path remains intentional.

See `docs/REDDIT_PREVIEWS.md` for activation, source availability and the
read-only offline/live acceptance tool. The package qualification records the
reference/candidate full-suite comparison and installer rehearsals. The server
installer still requires the complete unfiltered suite and both audits; no
existing assertion is disabled or exempted.
