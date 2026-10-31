# MB1047 — Pending AI answers belong to their current conversation

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_211846.zip`.
Exact public base: `50807d017f6997f3fe0a4bd59403af4b191ff17b` (MB1046),
VERSION `3.8dev-20261031_200453`.

Previously, reset/forget removed conversation data without retiring the pending
Claude request. The user remained blocked until its worker completed, and a
successful completion could still publish an obsolete answer, append detached
history and populate the answer cache. Merely deleting the old lock would also
let that old completion release a new request's lock.

The parent now assigns each asynchronous conversation a distinct reference
identity. Reset and forget retire only their exact raw-nickname/channel owner,
including the existing private-conversation scope. A fresh prompt can start
immediately. The callback adapter checks ownership before accepting a result,
so obsolete successes and failures cannot alter history, cache, output or
current-conversation error metrics. Completion releases a lock only while it
still owns it. Duplicate callbacks are ignored before accepting their result.
Reference identity avoids timestamp collisions and needs no permanent generation
registry. The private adapter's optional ownership predicate defaults to the
existing behavior for direct compatibility callers.

The provider-neutral client continues to own transport and bounded worker
cleanup. This retires a conversation result; it does not terminate a request
already sent to the provider or guarantee cancellation of provider charges.
Output already accepted and queued before a reset is outside this pending-result
boundary. Completed cache entries keep MB1046's exact-context keys and existing
sixty-second lifetime. Normal current failures still remove their orphan user
message and permit a retry. Reset preserves persona/pin settings, while forget
clears the same existing persona/pin/activity scope.

Twenty-four assertions exercise the native command handlers and callback adapter
with delayed AI::Client boundary completions. They cover old-first/new-first
completion order, obsolete errors, exact user/channel/private isolation,
detached history, cache exclusion, immediate replacement requests, duplicate
callbacks, current failure rollback/retry, operator callbacks and warning-free
execution. Seventeen fail on the untouched original runtime. Requests, metrics,
logs and output use local doubles; no paid API, HTTP/IRC/SQL call or worker fork
is made by the new case. Historical tests remain enabled and unchanged.

The operator script requires the entire visible --progress suite, security and
startup checks, inventory and whitespace validation before restarting dev only.
A new positive PID must remain active/stable ten seconds before interactive
native commit.sh performs automatic 3.8dev commit/push. VERSION is not manually
edited. Process stability does not prove IRC reconnection. No production,
schema, configuration, project README/banner, radio or YouTube change.
