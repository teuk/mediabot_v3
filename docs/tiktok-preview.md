# TikTok previews

TikTok previews use the existing channel `+UrlTitle` setting. No API key,
new chanset, database migration, cookies or external mirror is required.

A public post can produce this single-line IRC preview (counts are examples):

    (Vincent) [TikTok] 🎬 @ramish.art (Artramish) — #goldenbrown #knight #medieval #loveyou #viral · 0:16 · 👁 298.6k · ♥ 33.2k

The badge is white on black, the author is bold, and the remaining text uses
normal client colours. Text is sanitized and truncated on UTF-8 boundaries
within a 400-byte envelope. Normal IRC output policy still applies.

## Links and metadata

- Direct `/@author/video/id` and `/@author/photo/id` posts, including shared
  links with tracking parameters; desktop and mobile host aliases.
- Short links on `vm.tiktok.com`, `vt.tiktok.com` and `/t/token`.
- Profiles and live pages, player/embed links and legacy `/share/video/id`
  or `/v/id.html` links.
- Other public main-site paths (such as music and tags) use useful page
  description metadata when available.

The public page is read first. Matching post IDs in hydration data provide
caption, author, duration and counters; profile data supplies biography and
followers. Open Graph descriptions and oEmbed metadata are fallback sources.
Only fields actually returned by TikTok are displayed. The `Make Your Day`
landing title and common login/challenge text are never used as captions.

A blocked, private, deleted or unavailable post displays `aperçu indisponible`,
with the author from the link when known. This does not diagnose whether the
post was deleted: regional restrictions, anti-bot checks or temporary network
errors can have the same outcome. Metadata availability is not guaranteed.
Non-public TikTok subdomains and malformed URLs are not fetched.

## Runtime limits

All requests run in an AsyncWorker child, never synchronously in the IRC loop.
Redirects are checked against the public TikTok host allowlist at every hop:
maximum four page requests, then at most one fixed oEmbed request. HTTP bodies
are capped at 1 MiB, each request at five seconds and the whole worker at
16 seconds. TLS verification remains enabled; page scripts are not executed.

The bot allows at most four concurrent TikTok workers and twelve starts per
minute. Concurrent requests for the same canonical link share a fetch across
up to sixteen recipients. Metadata cache: 128 entries maximum, five minutes
for useful captions, thirty seconds for missing captions. Same-channel repeat
suppression lasts five minutes, independently of the metadata cache. The
original sender nickname is never stored in the shared metadata cache.

Delivery rechecks `UrlTitle`, connection identity and channel generation.
Old work is discarded after a disconnect, departure/rejoin or shutdown.
Existing message URL extraction is unchanged; this feature does not turn
multi-link messages into a burst of previews. Other providers, including
YouTube and radio playback, are unchanged.

## Validation

    prove -I. -It/lib t/cases/1539_mb1195_tiktok_preview.t

This suite covers URL identities, metadata formats, Unicode/IRC cleaning,
redirect rejection, fallback, rate/capacity limits, shared requests, stale
recipients, the actual router body and a real AsyncWorker/IO::Async round trip.
HTTP responses in automated tests are fixtures; no live network is required.
The three supplied video pages were also fetched manually and parsed during
qualification. Live checks are observations, not permanent availability tests.
