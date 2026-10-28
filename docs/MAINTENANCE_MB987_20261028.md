# MB987 — Correct round() at representable numeric boundaries

Base: `snap_mediabot_v3_teuk_20261028_092712.zip`, VERSION
`3.6dev-20261028_081504`. The MB986 test reductions in this snapshot are retained.

## Reproduced defect

The old implementation added a signed half before truncating. That addition
can itself round the intermediate floating-point value across a boundary:

| Expression | Before | Expected and corrected |
| --- | --- | --- |
| `round(0.49999999999999994)` | 1 | 0 |
| `round(-0.49999999999999994)` | -1 | 0 |
| `round(4503599627370497)-4503599627370497` | 1 | 0 |
| `round(-4503599627370497)+4503599627370497` | -1 | 0 |

The large-integer residual exposes an error that six-significant-digit output
can otherwise hide. It also reached the actual calc response and history.

## Change

Truncate once, compare the magnitude of the fractional part with a half, and
adjust the truncated value by one only when required. Exact halves continue
to round away from zero. Already integral values are returned directly.

Only `Mediabot/SafeCalc.pm` changes at runtime. This is still bounded native
Perl arithmetic, with its existing representational limits; this change does
not introduce arbitrary-precision arithmetic. The parser, allowlist, numeric
limits, formatting and routing remain unchanged. No configuration, SQL schema,
service unit or dependency change is required.

## Verification

- 22 focused regression assertions, including actual public/private calc
  delivery and stored history. Eight fail against the original runtime; all
  22 pass with the correction.
- Calculator selection: 322/322 assertions in nine files.
- Security audit: GO, all 37 invariants.
- Startup integrity and generated command inventory checks pass.
- Full-suite outcome is recorded in the package README. The two process
  environment checks 1151 and 828 also fail on the unchanged snapshot here.

No test is excluded from the installation procedure. It stops on any failure
before restarting the dev service or invoking the native commit/push script.
