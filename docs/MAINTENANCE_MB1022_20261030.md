# MB1022 — Qualification before deciding on stable 3.7

The supplied 30 October snapshot includes MB1020/MB1021 and remains
`3.6dev-20261029_203328`. This lot changes release tooling, CI, its tests and
preparation documents, not application behavior or the published release.

## Reproduced blockers

The actual Debian workflow selector accepts 3.6dev only as a 3.7 rehearsal and
rejects exact VERSION=3.7. The 3.5 upgrade qualifier also rejects that final
version and requires a rehearsal-only extraction path. Several source-identity
tests hardcode development even when a future final commit is intended.

The corrected path distinguishes the two defined states. Stable-shaped
qualification requires a dated committed 3.7 changelog heading, a matching
VERSION, immutable stable migrations and the exact CI checkout/archive root.
SQL still cannot run through a local --lineage-only check or outside the
restricted disposable CI path. Old 3.3/3.5 paths and all prior migration checks
remain. Tests enforce coherent public metadata for either source phase;
historical 3.5 evidence is not rewritten or counted as 3.7 acceptance.
The full final-state simulation also exposed the old Quip changelog placement
assertion: it now requires the entry in the correct development or 3.7 section,
still before the frozen 3.5 history. Its schema and migration checks remain.

CI additionally runs the existing offline mbweb tests and inventory check
explicitly. No new dependency or network-backed application test is added.
Eight isolated native assertions exercise the real selectors, Git history and
qualification script. Existing release assertions are retained and adapted
only where the new final phase changes their expected identity.

## Qualification scope

The delivery report records results from the exact source, archive repetition,
the real public annotated 3.5 tag, migration lineage, native Perl/Node checks,
lockfile audit and a disposable simulation of the final metadata state. A
synthetic local commit/archive is a test fixture, not the approved release.
No local MariaDB server, live IRC, production service or remote push is used.

The draft 3.7 notes and acceptance sheet keep all unexecuted operator checks
visible. VERSION, README/header, SECURITY and application/schema/configuration
files remain unchanged. The native operator commit stays on 3.6dev; final
publication and its tag remain a later explicit decision.
