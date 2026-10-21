# MB899 — Country lookup module

## Responsibility

`Mediabot::External::Country` owns the existing `whereis` country lookup and its
`whereis_async` process adapter. Both are optional exports; loading the module
does not load Helpers, the External facade or DBI, and makes no network request.
The module can be called directly. Existing callers continue through Helpers.

Helpers keeps both names, its default exports and all 98 unrelated function
bodies. Its size falls from 4,137 to 3,848 lines. The new owner has 339 lines,
including dependency bridges. This is a responsibility change, not a claim of
less total code or improved runtime performance.

## Compatibility boundaries

The synchronous function body is unchanged. The asynchronous body changes only
two calls to a compatibility relay. That relay looks up Helpers::whereis at call
time, falling back to the canonical function when Helpers is absent. Socket and
JSON relays likewise retain late overrides of the historically imported symbols.
The JSON relay forwards the original argument list without Perl prototype
coercion; cold and warm module load orders exercise this behavior.

Existing policies remain intact:

- Invalid or absent inputs return `N/A`; the existing Undernet hidden-host
  response and hostname suffix rules are preserved.
- IPv4 handling uses Socket; hostname handling uses the existing resolver.
  This round does not add IPv6 support or alter address acceptance.
- country.is is queried over HTTPS with explicit TLS verification and a
  three-second HTTP timeout. Existing response/JSON/country guards are retained.
- Without a usable event loop, the adapter calls the synchronous implementation
  and invokes the callback with its existing normalization rules.
- With a loop, the original child, pipe, timers, EOF/wait handling, TERM/KILL
  escalation and callback cleanup remain in place. The timeout defaults to five
  seconds and clamps to 0.1–15 seconds; TERM grace is 0.2 seconds. Child output
  is truncated to 128 characters and encoded as before; the parent retains at
  most 256 bytes. No decoding or Unicode policy is changed.
- WHOIS context capture, reply routing and user-visible message formatting
  retain their current owners and implementations.

The existing worker is deliberately not migrated to AsyncWorker during this
extraction. In the local native baseline, the explicit wait can report no child after pipe EOF, yielding the existing
`N/A` fallback even for a producer that returned a country. Pipe closure
collecting the child is a likely cause, rather than an established root cause. The same observation occurs on the candidate. The
native comparison establishes preservation of that lifecycle in this environment;
it does not establish successful country delivery in every scheduling order.
A future lifecycle repair must be qualified separately against these policies.

## Verification

Five existing cases follow the implementation owner: 139, 207, 536, 538 and 909.
The security audit reads Country.pm for the same country.is TLS invariant,
still failing on a missing owner or missing explicit verification. The other
36 invariants are unchanged.

Case 538 replaces its copied async function with calls to the loaded Helpers API.
Its existing five runtime assertions remain; six further assertions exercise
three fresh-interpreter load orders, late Socket/JSON/HTTP hooks, native timeout
and native TERM-to-KILL recovery. No numbered case is added or removed.

An external probe compares the real source, candidate facade and canonical
module over 477 scenarios, recording returns, scalar UTF-8 flags/bytes, logs,
DNS/HTTP calls and options, exceptions, warnings and no-loop callbacks. Ten
additional lifecycle scenarios run in 30 fresh Perl processes with real IO::Async
loops and child processes. Network producers are intercepted. All three APIs
produce identical observations for the sampled scenarios; native callbacks are
single and children are collected.

Mutation tests verify that the new runtime assertions reject a JSON relay that
forwards a coerced argument count, and that the actual audit rejects missing or
TLS-disabled country lookup code. See package QUALIFICATION.md for exact test
counts, local environment limits and installer application/rollback evidence.

No database schema, SQL, private configuration, VERSION, service or test runner
changes are part of MB899. The server installer requires the full unfiltered
suite, both audits and zero failures before a commit.
