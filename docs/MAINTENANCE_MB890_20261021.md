# MB890 — Exact retention bounds for Chromium pipes

## Reference state

No new post-MB889 snapshot was supplied. The reference is reconstructed from
`snap_mediabot_v3_teuk_20261021_193550.zip` plus the exact MB889 payload whose
full server validation passed 30,171 assertions. Every original and overlaid
file is checked against its archive or manifest before reconstruction.
The resulting reference has 1,742 files. Its existing VERSION is retained for
local qualification and is not part of this delivery; a subsequent server
commit's VERSION does not need to match it.

## Reproduced fault

The Chromium driver checked whether a retained buffer was below its limit,
then appended the entire next `sysread` chunk. A chunk can contain up to 65,536
bytes, so crossing a positive cap could retain up to 65,535 excess bytes.
Both stdout and stderr used the same faulty pattern.

Controlled native fixtures reproduce the problem: a one-byte stdout cap can
return the complete 33-byte sample DOM; a seven-byte stderr cap can still
produce a diagnostic with 500 retained `e` bytes. The cap applies to retained
stream data, not the diagnostic prefix surrounding that data.

## Correction and boundaries

A private `_append_bounded_chunk` computes the remaining raw-byte allowance
and appends at most that much data. Both stream branches call it. Reading,
select membership and EOF handling remain unchanged after the retained buffer
fills, so the child can finish writing and be reaped. Retention is bounded;
the temporary IO chunk and other process memory remain separate costs.

Defaults remain 2 MiB for stdout and 256 KiB for stderr. Existing option
normalization and zero/negative retention behaviour remain unchanged. There is
no new export, configuration setting, failure shape or whole-response rejection.
A successful nonempty retained stdout prefix is still returned. When an exact
cap cuts inside a UTF-8 sequence, the existing decoder error and raw-prefix
fallback apply; no replacement characters or new clipping policy are added.

The HTTP(S) argument guard, binary/profile hooks and defaults, argv, profile
cleanup, concurrent pipe draining, request deadline, TERM/KILL escalation,
exit-status handling, logging levels and provider/worker call sites are kept.
All original functions other than the two append sites in the fetch body are
unchanged. No URL parser, provider cache, SQL statement, database schema,
migration, private configuration, VERSION, service or sender is modified.

## Native regression evidence and fixture correction

The existing Chromium case receives four native checks through its existing
shared fixture: a 200,000-byte stdout with a 1,000-byte cap, 200,000-byte stderr
with a seven-byte cap, a 17-byte prefix ending inside an accented character,
and zero caps on both streams. The first three fail against MB889's canonical
driver. All twelve native checks pass against the corrected driver. The zero
case verifies retained behaviour and continued drain/reaping.

Review also found a fixture issue: a final `grep` in list context can yield no
argument at all, allowing the diagnostic label to become the callback's truthy
first argument. Each fixture condition now explicitly uses scalar context.
Before/after native evidence contains named boolean results for every check.
This strengthens the existing eight conditions as well as the four additions.

No numbered case or new fixture is introduced. The targeted twenty-file lane
passes **543/543 assertions**. Separate native comparisons execute the actual
reference and candidate modules in fresh interpreters with isolated executable
and profile paths: 24 retained scenarios are identical, while five cap-crossing
scenarios change as intended. Temporary paths, PID and profile names are
normalized; text/byte flags, argv, logs, warnings and child reaping are compared.

The probes use real open3/select/read/wait/kill with a local Perl executable.
No installed Chromium, public site or production database is used. These are
sampled checks of driver behaviour, not a statement about all Chromium versions.
Exact full-suite results and installer rehearsal are recorded in the package's
qualification report. The server installer requires the unfiltered full suite,
security audit and startup integrity to pass with zero failing assertions.
