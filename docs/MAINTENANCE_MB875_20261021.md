# MB875 — Fortnite response status and scalar display fields

Base: `snap_mediabot_v3_teuk_20261021_113748.zip` with the exact five MB874
payloads applied. MB874 installation and all 28,957 server assertions were
confirmed before this round. No new server snapshot was supplied; the package
guards the before/after contents of its six files and does not assume a new
VERSION value or replace unrelated files.

## Validate a declared API status before comparison

The response root was already checked as an object, but its `status` leaf
was compared numerically without a type or spelling check. Objects/arrays
were coerced and appeared in diagnostics; null/text values could warn, and
`200oops` could be accepted as success. A supplied status must now be a
defined scalar with three ASCII digits before the existing status comparison.
Malformed declarations receive the existing unexpected-response reply.

Integer and string `200` remain successful. Responses without a status field
retain their existing compatibility. Ordinary non-success statuses retain the
API error path. A reference-valued error uses `API error`, the existing default
for missing/null errors; valid scalar text, including zero and empty strings,
is preserved. Diagnostics do not interpolate the rejected references.

## Keep display values scalar

The nested account, battle-pass and statistics objects were already guarded.
Their leaf values could still be arrays, objects or JSON booleans, causing
Perl reference markers or boolean pseudo-stats to appear in the IRC reply.

Each displayed leaf now accepts defined scalars only. A malformed account
name uses the requested nickname; a malformed numeric field uses the same
zero default as a missing/null field. Other usable fields remain visible.
This does not add numeric range validation or change the existing behavior
of non-numeric scalar values. K/D and win-rate rounding remain unchanged.

## Offline executable regressions

- `1294_mb875_fortnite_status_contract.t`: malformed declarations, no numeric
  prefix coercion, safe API errors, valid/missing status compatibility, no
  extra attempts, authentication/level/syntax/user refusal and success logging.
- `1295_mb875_fortnite_display_scalars.t`: all eleven displayed leaves with
  arrays, objects and both JSON booleans; exact complete replies, missing/null
  defaults, overall/solo/duo/trio/squad selection, private target, scalar zero,
  non-numeric compatibility, HTTP timeout, TLS and authorization header.
- `MB875FortniteFixture.pm`: the actual built-in `f` handler, actual Context
  and account lookup queries against an isolated in-memory SQLite database.
  Only external IO, configuration and the caller identity use fixtures.

No API, IRC server or production database is contacted by these regressions.
The runtime change is confined to the Fortnite section of YouTube.pm.
The current ten-second HTTP timeout, verified TLS, account endpoint, request
count, authorization, mode preference, routing and access checks are retained.
No schema, migration, private configuration, VERSION or service change.

Executed results and any local limitations are recorded in the package's
`QUALIFICATION.md`. The delivered installer requires the full server suite
without exclusions and restores this attempt if validation fails.
