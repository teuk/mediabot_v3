# Short Content v3 pilot

MB746 introduces `short-content-v3` as a deliberately small proof of the API
v3 HTTP and repository boundaries. It is not loaded at boot, it has no default
endpoint and no channel is active automatically.

## What the proof does

The public `short` command asks the shared core service for one HTTPS JSON
document. The channel policy selects a dotted path of at most four object keys,
for example `slip.advice`. The plugin emits at most one 400-byte IRC line and
stores only the last parsed value plus a served counter.

The plugin cannot choose a network peer after DNS validation, use HTTP, select
a non-443 port, follow an unchecked redirect, inherit proxy credentials, open a
socket, see the storage path or run SQL. Timeout, response size, concurrency,
cache, circuit breaking, persistence and late revocation belong to the core.

## Preconditions

- use the development bot only;
- choose an HTTPS JSON endpoint you operate or explicitly trust;
- ensure the response contains one short scalar at the configured path;
- keep the first channel limited to `#test` or another development room;
- load only the three requested capabilities.

## Observe first

On the authenticated Owner Partyline:

```text
.plugins discoverv3
.plugins loadv3 short-content-v3 http.fetch,irc.reply,storage.kv
.plugins policy short-content-v3 #test observe endpoint=https://example.net/item.json json_path=text language=fr cache_ttl_seconds=300 max_chars=280 prefix=✨
.plugins enable short-content-v3
.plugins info short-content-v3
```

Invoke `short` on `#test`. Observe mode performs validation, fetch and parsing,
but the core suppresses both IRC output and repository commits. Check logs and
metrics for bounded outcomes before changing the policy.

## Turn on one channel

Repeat the complete policy so the typed configuration remains explicit:

```text
.plugins policy short-content-v3 #test on endpoint=https://example.net/item.json json_path=text language=fr cache_ttl_seconds=300 max_chars=280 prefix=✨
.plugins info short-content-v3
```

Test a successful response, a malformed document and an unavailable endpoint.
The channel must see one short item or one neutral error, never transport or
filesystem detail. Repeated success may be served from cache.

## Immediate rollback

```text
.plugins policy short-content-v3 #test off
.plugins disable short-content-v3
.plugins unload short-content-v3
```

`off` blocks new work. Disable cancels owned requests and revokes late
callbacks. Unload removes the command and runtime entry. The namespaced state
file is inert and may be cleared separately through the existing operator
storage procedure if desired; rollback does not require a database migration or
configuration edit.

## Evidence expected before wider use

- `observe` produces no IRC line and no repository write;
- `on` produces one bounded line and one revisioned commit;
- cache hits do not start a second outbound request;
- timeout and circuit-open outcomes are neutral on IRC and visible in metrics;
- switching to `off` or disabling during a request suppresses late delivery;
- unload removes `short` and leaves historical commands unchanged.
