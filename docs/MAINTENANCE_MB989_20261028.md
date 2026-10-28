# MB989 — Preserve same-unit temperature conversions

Base: `snap_mediabot_v3_teuk_20261028_125116.zip`, VERSION
`3.6dev-20261028_102327`. Earlier fixes and the MB986 test reductions are retained.

## Defect and correction

The temperature branch always converted through Celsius, even when the
source and destination were the same canonical unit. Subtracting an offset
then adding it back can cancel a small input or reduce its precision:

| Conversion | Before | Corrected |
| --- | --- | --- |
| `1e-30 k kelvin` | `1e-30 K = 0 K` | `1e-30 K = 1e-30 K` |
| `-1e-30 fahrenheit °F` | `-1e-30 °F = 0 °F` | `-1e-30 °F = -1e-30 °F` |
| `1e-10 kelvin K` | `1e-10 K = 9.999e-11 K` | `1e-10 K = 1e-10 K` |

Keep the input as the output when the canonical units match. The existing
numeric and unit validation still runs before this branch. For distinct units,
the same Celsius-pivot formulas run as before. Both sides of the result still
use the existing formatter, with its existing precision rules.

Only `Mediabot/Convert.pm` changes at runtime. No parser, alias, configuration,
SQL schema, dependency, activation or service-unit changes are required.

## Verification

- Eleven new assertions: six focused numeric/alias boundaries, real public
  and private command replies with one audit event each, and no warnings.
  Five fail against the original runtime; all eleven pass after correction.
- The complete conversion selection passes 290/290 assertions in four files,
  including cross-unit conversions, numeric limits and invalid-input guards.
- Security audit: GO, 37 invariants. Startup integrity and generated command
  inventory pass. Full-suite results are recorded in the package README.
- Local process checks 1151 and 828 also fail on the unchanged snapshot here.

The procedure excludes no tests and stops at any failure before restarting
the dev service or invoking the native commit/push script.
