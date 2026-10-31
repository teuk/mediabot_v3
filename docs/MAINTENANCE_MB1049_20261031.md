# MB1049 — Shared AI boundary budgets

Source snapshot: `snap_mediabot_v3_teuk_20261031_230511.zip`.
Public base: `e5ecd8cc2602cedd22fdeaa42fe7d701b9e34754` (MB1048).
VERSION: `3.8dev-20261031_212723`.

The shared request validator capped messages but exempted system text. The
transport did not set a size cap for its default HTTP::Tiny factory, although
the existing External factory already used 512 KiB. The client returned success
results without checking their encoded size. A valid response could therefore
exceed the 256 KiB asynchronous pipe and emerge only as worker_failed, losing
its provider and useful diagnosis. Escaping, UTF-8 and metadata all affect the
wire size; character count alone cannot defend that boundary.

AI::Limits now owns four internal constants:

| Boundary | Limit | Unit |
|---|---:|---|
| Aggregate system plus message text | 250,000 | characters |
| AI HTTP response | 512 KiB | UTF-8/raw response bytes |
| Complete normalized success result | 240 KiB | encoded JSON bytes |
| Existing asynchronous worker pipe | 256 KiB | encoded protocol bytes |

The 16 KiB reserve separates the normalized result from the worker's terminal
envelope/newline. The worker ceiling is not raised. Result validation is shared
by execute and submit. An oversized answer is rejected whole, never clipped:
MetaAI must receive intact structured text or a failure. New failures retain
provider/model/attempt metadata with response_too_large and response_size.
OpenAI model retries and Gemini transient retries do not retry known size
failures. Only callers explicitly requesting auto can cross providers.

The transport forwards max_size, recognizes HTTP::Tiny's fixed 599 size-abort
diagnostic and checks custom-client results before retaining Base64 data.
Upgraded content is encoded as UTF-8 before its byte check. A custom client that
ignores max_size may allocate its response before this post-check; the transport
still prevents that body from being retained/decoded by the AI pipeline.
Ordinary successful text matching the diagnostic is not mistaken for an abort.

OpenAI/Claude/Gemini give the same size-specific user explanation. MetaAI's
provider log whitelist retains the new code/category, and its existing
degradation path can synthesize from the remaining usable contributors. No
provider payload format, model, token setting, routing or public command changes.
Other HTTP consumers, including radio and YouTube, keep their own limits.

Thirty-six assertions exercise native validators, all three adapters, shared
transport/client, real worker pipes, MetaChat and caller error presentation.
Twenty-four fail on the original runtime. Six actual AsyncWorker children use
local fake HTTP responses: ordinary Unicode and oversized Unicode for each
provider. A separate inline worker boundary exercises the real client inside a
collective with one oversized contributor. No paid API or external HTTP/IRC/SQL
connection is used by the new case. Existing assertions remain unchanged.

The operator script requires the full visible --progress suite and native
audits before restarting dev only. A new positive PID must remain active/stable
ten seconds before interactive commit.sh calculates the native 3.8dev VERSION
and commits/pushes. VERSION is not edited manually. Process stability is not
proof of IRC reconnection. No production, schema/configuration, project README
or banner, dependency, radio or YouTube change.
