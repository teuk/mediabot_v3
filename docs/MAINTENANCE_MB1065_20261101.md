# MB1065 — Partyline authentication boundary

## Defects and scope

The partyline identity query fetched a row without checking DBI's fetch error.
A failed fetch looked like an unknown user and consumed both session and IP
brute-force attempts. Prepare/execute/fetch exceptions escaped the method;
finish exceptions could discard a valid read before authentication continued.

The role guard accepted any defined value numerically less than or equal to
one. A negative role could authenticate, while empty or nonnumeric values could
be coerced to Owner. The supported privileged roles are exactly Owner=0 and
Master=1, consistent with the partyline shell's existing authorization checks.

## Implementation

Guard the identity query as a complete read. Test statement err before finish
can clear it, then perform cleanup best-effort. A failed read returns the
established internal-authentication-error reply, logs a fixed bounded code
without the raw exception/SQL error and leaves both failure counters unchanged.
No verifier, success publication, welcome, presence or login metric runs.

Call the shared verifier through an exception guard. A verifier exception uses
that same unavailable path; an ordinary false return retains its historical
credential-rejection meaning. This does not change the shared Auth API, password
lookup, password formats or lazy hash migration. SQL errors reported only as
a false result by that existing verifier remain governed by its boolean API.

Require a plain scalar role exactly matching ASCII 0 or 1. Unknown users,
genuine credential rejections and insufficient roles still consume the same
single session/IP attempt. Healthy logins still clear those counters, cancel
their auth timeout, publish status, update metrics and announce once. A session
can retry after the backend recovers without being falsely locked out.

## Validation and delivery

Replace the existing eight source/prose checks in
t/cases/197_partyline_login_no_password_select.t with eight native assertions.
The actual imported partyline method executes a real isolated SQLite join;
the identity fixture has no password column. A boundary spy verifies delegation
of credentials while transport, logger, metrics and status hooks are observed.

Cover Owner, Master with throwing cleanup, negative/absent/malformed/ordinary
roles, absent user, credential rejection, false and throwing prepare/execute/
fetch, a returned row carrying an error cleared by finish, a throwing verifier
and logger, and recovery in the same session. Existing IP/window/cap helpers,
dispatcher and wire tests remain active. No test file or assertion growth.

Preserve MB1062/63/64 and previous qualified pending paths. VERSION and the
private commit.sh stay unchanged; the helper continues native 3.8dev versions.
The operator script runs the visible full suite with --progress/ETA, audits and
inventory before dev-only restart and native commit/push after success. No
production service, schema, credential, configuration or dependency is changed.
Package qualification records the actual local outcomes and limits.
