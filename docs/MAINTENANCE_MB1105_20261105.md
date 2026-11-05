# MB1105 — Metrics HTTP connection lifetime

The embedded metrics HTTP server already limits request headers to 16 KiB.
That cap did not help if a client sent nothing or stopped below the limit:
the accepted stream stayed in the event loop with its socket and request
state. Removing the listener also left those streams in the loop.

Each accepted stream now owns an IO::Async countdown with a fixed ten-second
deadline. It starts once, on accept, and applies through response delivery.
Normal responses still flush and close immediately. If the deadline expires,
the stream closes without waiting for any remaining writes. When a stream
leaves the loop, its child timer leaves too. The listener owns the streams
so its stop path can close each one before closing the listening socket.

The existing 16 KiB limit, HTTP status codes, response formats, endpoint
paths and configuration are unchanged. This uses the existing IO::Async
dependency and adds no timer per request chunk. The deadline limits how long
one client can hold resources; it is not a connection rate limit.

The existing metrics HTTP integration test now exercises idle and partial
clients, listener stop with a live client, restart, a fresh scrape after
expiry, and the oversized-header response on loopback. It uses a shortened
deadline on the fixture only. The idle/partial and stop assertions fail
against the original implementation. Equivalent source pins and repeated
serialization checks were removed; representative multilingual JSON, UTF-8
byte lengths, Prometheus output and exact header limits remain covered.

No configuration or data migration is needed.
