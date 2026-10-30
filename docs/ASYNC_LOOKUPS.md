# External lookups: shared lifecycle, domain-owned results

Implemented in MB1030, on the existing 3.8dev line.

## Decision

Country and definition searches previously maintained their own child-process
protocol, stream buffering, timeout, TERM/KILL escalation and reap polling.
They now delegate those responsibilities to the existing `Mediabot::AsyncWorker`,
also used by other external providers. Fixes to that lifecycle have one owner.
The shared worker implementation itself is unchanged by this migration.

| Responsibility | Owner |
| --- | --- |
| WHOIS context and reply target | Existing IRC dispatcher and caller callback |
| Definition syntax, configured language and public/private reply routing | `Mediabot::UserCommands::mbDefine_ctx` and Context |
| DNS/country.is lookup and country fallback | `Mediabot::External::Country` |
| Wiktionary HTTP, deterministic language selection and definition fallback | `Mediabot::External::Wiktionary` |
| Fork, framed JSON bytes, timers, termination and child collection | `Mediabot::AsyncWorker` |

The async definition adapter lives with Wiktionary instead of in the command
module. Its historical UserCommands symbol is an import of the same function.
Loading the source module does not load UserCommands or open a connection.
Existing late UserCommands/Helpers source overrides still resolve at call time.

## Invocation and ownership

An accepted lookup returns 1; an invalid callback returns 0. Country completion
still receives one country string or `N/A`. Definition completion receives one
definition or its existing word-specific failure message. Normalization belongs
to each adapter; worker error records are not exposed as IRC messages.

The adapter passes an empty bot hash and captured lookup inputs into the child
source call. It does not use live database or IRC objects there. AsyncWorker's
child exit bypasses inherited object destructors, as before.

A worker launcher can fail, throw, or invoke completion synchronously. The
adapter claims completion once and detaches the caller callback before running
it. A retained late completion cannot deliver again or keep the old caller
payload alive. A callback may start a new independent lookup; consumer/logger
exceptions cannot escape into the event loop.

Only the explicit absence of a usable loop selects the compatibility synchronous
path. Source exceptions there produce the normal fallback. A failed async launch
does not fall back to blocking DNS or HTTP in the IRC parent.

## Bounds

| Lookup | Default / accepted timeout | Text bound | Framed wire budget |
| --- | --- | --- | --- |
| Country | 5 s / 0.1–15 s | 128 characters | 1 KiB |
| Definition | 10 s / 0.1–20 s | 1,024 characters | 8 KiB |

Text is truncated inside the child and validated on completion. JSON supplies a
consistent UTF-8 boundary; the wire budgets include framing and JSON escaping.
Country no longer treats UTF-8 result bytes as display characters. Definition's
wire budget accommodates its existing text limit even when escaping expands it.
Termination retains the 0.2-second TERM grace; the shared worker supplies its
one-second finalization backstop and process watch.

## Qualification and extension

Historical tests retain every assertion and exercise provider behavior, WHOIS
context, Context routing, deterministic languages, timeouts and resistant children.
Early-EOF probes now close the shared worker's dedicated result pipe, with an
assertion that EOF was observed before termination. Closing STDOUT alone would
not exercise that boundary after the migration.

Eleven additional assertions cover adapter contracts, synchronous launcher
completion/failure, malformed results, reentry, callback lifetime, failed consumers,
explicit no-loop compatibility, UTF-8/native forks, heartbeat and collected PIDs.
They make no live provider request. Full qualification is recorded in the ZIP.

Future adapters should keep provider policy outside AsyncWorker and reuse its
lifecycle. A new process protocol or reap loop needs an actual different contract;
ordinary text/result normalization is not a reason to duplicate that machinery.
