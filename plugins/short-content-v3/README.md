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
