# Short Content v3

`short-content-v3` is the MB746 proof plugin for the shared API v3 HTTP and
repository services. It is discovered but never loaded or enabled at boot.

The `short` command performs one HTTPS JSON GET through the core HTTP service,
reads the configured scalar at `json_path`, emits at most one bounded IRC line,
and records only `last` and `served` through the namespaced repository facade.
It never receives a socket, resolver, filesystem path, database handle, secret,
or raw bot object.

Example Partyline pilot:

```text
.plugins discoverv3
.plugins loadv3 short-content-v3 http.fetch,irc.reply,storage.kv
.plugins policy short-content-v3 #test observe endpoint=https://example.net/item.json json_path=text language=fr cache_ttl_seconds=300 max_chars=280 prefix=✨
.plugins enable short-content-v3
.plugins policy short-content-v3 #test on endpoint=https://example.net/item.json json_path=text language=fr cache_ttl_seconds=300 max_chars=280 prefix=✨
```

Use an endpoint you operate or explicitly trust. Reset the channel policy and
disable/unload the package to roll back immediately.

MB781 retains this package as enabled/on only on development `#test`, using the
trusted GitHub repository endpoint through the shared HTTP facade. Observe
remains silent and repository-write-free; on produces one bounded scalar and
one namespaced repository revision. The exact posture survives restart while
source remains default-off and production remains untouched.

MB782 then proves a silent, repository-write-free observe posture on
production `#i/o`. MB783 promotes that exact package on production `#i/o` to
persistent enabled/on, returns one authoritative HTTPS repository name and
retains one bounded repository revision. All five production postures survive
restart with zero failures. MB784 records the evidence without widening this
manifest, changing source defaults or contacting production.
