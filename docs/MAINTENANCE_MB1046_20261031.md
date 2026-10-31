# MB1046 — Context-correct AI answer caching

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_203218.zip`.
Base: `a474b7f451e7f225c80ffbaf98a644357ac4a8e8` (MB1045),
VERSION `3.8dev-20261031_193152`.

The AI/Claude cache keyed responses by the lowercased last prompt and effective
system text. Previous conversation messages, conversation identity, model and
generation settings were absent. Two different conversations asking "continue"
could therefore receive the same cached answer. A model change could also reuse
the previous model's response, while case-sensitive prompts were merged.

AI::Request now owns an internal request_cache_key helper. It validates the
portable request and hashes canonical UTF-8 JSON containing its complete fields
and an opaque caller-owned scope. The result is a versioned SHA-256 key; no
serialized prompt or scope is returned. Hash-key order is canonicalized, while
message order and text case remain significant. Inputs are not mutated. Invalid
requests/scopes or serialization failure produce no key. No new request fields,
exports, credentials, network endpoints or cache service are introduced.

Claude builds its existing copied request before consulting the cache, then
uses the request fingerprint with its existing raw-nick/channel history scope.
The same copied request continues to the provider-neutral client on a miss.
The pre-completion key is retained while the assistant response updates history.
Sync and async paths share this order. Missing keys bypass caching safely.

Identical validated replays still hit the cache for sixty seconds. Context,
model, temperature, output budget, system instructions or session changes miss.
Legacy short keys cannot alias the new namespace. Permission/rate checks,
history limits, persona/pin handling, async ownership, expiry/pruning, provider
selection, model defaults and output formatting retain their existing owners.
This delivery uses the shared primitive for AI/Claude; it does not add new
caching to OpenAI/Gemini or change reset/forget cancellation semantics.

Twenty-two assertions exercise the real request/cache/conversation/rendering
code. A local AI::Client boundary double records requests and returns controlled
answers or delayed callbacks; transport and IRC output are local sinks. Cases
cover context changes, repeated turns, session separation, generation settings,
exact prompt case, canonical ordering/immutability, valid replay, sync/async
validation, cache-hit completion, in-flight cleanup, expiry and warnings.
Fifteen fail on the untouched original runtime. No paid API, HTTP/IRC/SQL
connection or worker process is used by the new case.

The operator flow requires the entire visible --progress suite and native
audits before restarting dev only. A new positive PID must remain active/stable
ten seconds before native interactive commit.sh performs automatic 3.8dev
commit/push. VERSION is not manually edited. Process stability does not prove
IRC reconnection. No production, schema, configuration, project README/banner,
radio or YouTube change.
