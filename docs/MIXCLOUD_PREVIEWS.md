# MixCloud previews

Post a public Mixcloud show link on an explicitly enabled channel. For example:

```text
https://www.mixcloud.com/leekid/shut-up-and-dance/
```

The preview uses a white-on-navy `[🎛️ MixCloud]` badge, a bold title, the
creator's name and the duration when the API supplies it:

```text
(Listener) [🎛️ MixCloud] Shut Up And Dance ! — Leekid · 2h06m16s
```

This example uses metadata read from the public API on 29 October 2026; it is
not a claim that a bot has delivered it on a live IRC channel.

## Enable or disable

As an authorized channel administrator or global administrator, on development:

```irc
!chanset #test +MixCloud
```

Use the configured command prefix instead of `!` when it differs. Posting the
link then produces one public preview. `UrlTitle` can remain off: MixCloud has
its own independent gate. `-MixCloud` also prevents generic-title fallback for
Mixcloud hosts and revokes work already pending on that channel:

```irc
!chanset #test -MixCloud
```

The first authorized `+MixCloud` registers the name in the existing
`CHANSET_LIST` catalogue if absent, using the same opt-in mechanism as Reddit.
It then enables only the requested channel. It changes no table definition,
imports no SQL dump and activates no other channel. No provider key, password,
new Perl module or private configuration setting is required. Merely installing
this source performs no database write or activation.

Private diagnosis reports the observed `MixCloud=on/off/missing/unknown` state.
The bundled mbweb reader includes the same flag and accepts older publications
without that field as `unknown`. Updating the bot does not deploy mbweb itself.

## Scope and limits

- Supports public `mixcloud.com`, `www.mixcloud.com` and `m.mixcloud.com` show
  links of the form `/creator/show/`, with or without a trailing slash.
- Uses only `https://api.mixcloud.com/creator/show/`. Sharing queries and
  fragments are discarded; no embedded HTML, player or audio is downloaded.
- Profiles, live rooms, playlists, search and other multi-part pages are outside
  this show preview. Unsupported Mixcloud links produce no generic preview.
- Credentials, non-default ports, control characters and unsafe paths are
  refused before HTTP. API results must identify the exact requested show.
- One request has an 8-second timeout, a 256 KiB response limit, TLS verification
  and redirects disabled. A supervised worker has a 12-second deadline; HTTP
  never runs in the IRC event loop. There is no immediate HTTP retry.
- At most four workers and twelve starts per minute per instance; up to sixteen
  waiting channel deliveries share a show request. Duplicate links on the same
  channel are suppressed for five minutes, including tracking variants.
- Successful metadata is cached for five minutes, failures for thirty seconds;
  caches retain at most 128 shows and 512 recent channel/show pairs.
- Unavailable, deleted, private or rate-limited content gets a concise
  `aperçu indisponible` rather than a guessed title or provider error text.
- One sanitized IRC message is bounded to 400 wire bytes. Existing output
  filtering, NoColors and antiflood handling remain authoritative.

The HTTP timeout is the client's normal per-operation timeout; the supervised
worker provides the overall deadline. Delivery rechecks the enabled flag, its
policy epoch and the captured connection/join generation. A new connection,
part/rejoin, disable/re-enable or shutdown cannot inherit an old reply.

Official API reference: <https://www.mixcloud.com/developers/>.
