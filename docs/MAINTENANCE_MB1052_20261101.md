# MB1052 — Nonblocking shared-state locks for URL presentation

Private ShortURL and legacy TinyURL clients share an instance-local cache and
failure circuit across workers. Their exclusive state lock also spans the HTTP
request, preventing simultaneous writers and repeated provider attempts. The
old blocking `flock(LOCK_EX)` had no wait budget: a caller could stall behind
another process before even starting its own bounded HTTP request.

Both clients now attempt `LOCK_EX | LOCK_NB`. A busy lock returns the existing
original-URL fallback immediately; no state is read or written and no HTTP call
bypasses the owner. Contention is classified separately as `state_lock_busy`,
with a `state_busy` debug-level event and a fixed message. Other lock/state
failures retain their existing error classification. A later request after the
owner releases its lock uses the ordinary cache/circuit/HTTP path.

The exclusive lock still spans ordinary state and HTTP work when acquired.
This does not remove serialization or add retries, timers, lock stealing or an
unlocked cache fast path. Even a previously cached URL returns its original
form while the state is busy. Real provider failures still open their existing
circuits. State files, lock files, atomic writes and owner-only modes retain
their existing format and behavior. No endpoint or credential policy changes.

## Validation

`1425_mb1052_shortener_lock_contention.t` runs each real public client against
a local HTTP double and private temporary files. A forked process takes the
actual OS lock and announces readiness through a pipe. It holds the lock until
the parent signals release. A one-second alarm bounds the old blocking behavior
for regression proof; the test does not guess when the lock holder will sleep.

Thirty-five assertions cover busy original/cached URLs, exact URL preservation,
no extra HTTP call, unchanged state bytes, independent lock ownership, private
modes, observer exceptions, clean child exit, successful recovery, persistent
cache reuse and unchanged provider-failure circuits. Eight fail on the unchanged
public runtime, twenty-seven pass. All thirty-five pass after correction.
The test contains no live HTTP, provider account, IRC connection or SQL server.
No historical assertion is modified, skipped or removed.

Targeted/full results, baseline environmental failures and a public patch
apply/test/reverse round trip are recorded in the delivery qualification.

## Operator flow

The package applies idempotently. The visible full suite with `--progress`,
security audit, startup integrity, generated command inventory and whitespace
checks must all pass before restarting only `mediabot@dev.service`. A new
positive PID must remain active and stable for ten seconds before native
interactive `commit.sh --skip-preflight` handles commit/push and the next 3.8dev
VERSION. The patch does not edit VERSION or the project README. No production
deployment, schema, configuration or dependency change is included. The private
commit helper remains installed locally and is not shipped.
