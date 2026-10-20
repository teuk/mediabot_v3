# Maintenance — 2026-10-20

## MB855 — Coherent Icecast status observations

### Reproduced defect

`get_primary_mount_status` fetched the Icecast status three times: global
server data, listener counts and selected mount information. `get_summary`
made a fourth request for the detailed mount list. A station transition
between requests could therefore combine the old server with new listener
counts, another title and a different detailed list. A second-request outage
could also discard the already received valid observation.

The intact MB854 implementation fails the new consistency and real loopback
HTTP regressions. These are controlled reproductions, not a claim that an
inconsistent production response was observed.

### Corrected behavior

Each public aggregate now fetches `status-json.xsl` once and derives its
global status, listener totals, selected mount and detailed mounts from that
one decoded response. Shared private normalization helpers retain the existing
public result shapes, raw status/selected-mount fields, numeric normalization,
Unicode strings, stable mount sorting and configured-primary/first-mount fallback.

There is no new cache: a later method call always makes a fresh request. The
scope is one Icecast response, not a transaction with the station or Liquidsoap.
Standalone status, mounts, listeners and now-playing calls remain independent
fresh observations. HTTP/empty/JSON/structure/no-mount failures remain explicit;
the next valid response can recover without a stale or partially cached result.

### Validation and rollout

Regressions exercise changing injected HTTP responses, a valid observation
followed by an outage, single-source HASH and multi-source ARRAY documents,
explicit zero listeners, Unicode metadata and failure/recovery. A real forked
loopback HTTP server changes the complete station document on every request,
covering the public aggregate and standalone methods through HTTP::Tiny and
the actual JSON decoder. Only test-owned sockets/children are created.

Only `Mediabot/Radio/Icecast.pm` changes in production runtime. Endpoint, HTTP
factory/TLS policy, timeout, command permissions, IRC presentation, metrics cache,
playback/queue control and private radio configuration remain unchanged. There
is no SQL/schema, persistent-format or service deployment change. MB849 DTC,
MB850/MB851 Unicode, MB852 workers, MB853 scheduling and MB854 logging remain.

The package requires focused, security, command-inventory, fast and full host
validation before retaining source writes. It stages and commits nothing and
restarts no service. After successful host checks, restart only the development
bot and check ordinary IRC continuity. If radio is configured there, inspect an
ordinary radio status/song response; otherwise qualify the deployed radio
instance during its normal update. No forced stream transition, outage,
filesystem failure, Icecast/Liquidsoap restart or web deployment is needed.

## MB856 — Inch syntax and finite conversion results

### Reproduced defects

The conversion handler removed every token equal to `in`, treating the inch
symbol as an optional English separator. Requests such as `!convert 12 in cm`
or `!convert 1 m in` therefore lost an actual unit and returned syntax help.

The numeric module also accepted overflowing scientific input as a successful
`Inf` result. Converting through a base-unit intermediate could overflow or
underflow even when the final result was representable: `1e300 TB` to `TB`
became infinity, and a subnormal milligram identity became zero. Temperature
formulas could likewise overflow before division despite a finite result.

### Corrected behavior

Only a fourth-argument form can contain a separator, and it is removed only
from the position between the source and destination units:

```text
!convert 12 in cm
!convert 12 in to cm
!convert 1 m in
!convert 1 m to in
!convert 1 m in in
```

The module accepts the existing signed decimal/scientific syntax using ASCII
numeric characters. References, trailing line breaks and Unicode digits that
Perl's numeric conversion cannot parse are refused without arithmetic warnings.
Converted input and final results must be finite. Overflow becomes a bounded
error rather than a public success. Unit scaling forms the fixed unit ratio
first, and temperature formulas multiply the ratio rather than multiplying
before division. Representable large/small conversions therefore remain usable.

This is still ordinary floating-point conversion, not arbitrary precision or
physical validation of temperatures. Existing underflow/rounding limits and
display precision remain. Aliases, unit families, negative values, optional
separators, different-family errors and unknown-unit errors are retained.

### Validation and rollout

The new arithmetic case covers large finite conversions, a subnormal identity,
input/output overflow, malformed/non-scalar/Unicode numeric input, ordinary
conversions in all six families and descriptive refusals. The handler case uses
the actual conversion function and Context with captured bot delivery; it covers
inch source/destination positions, separators, mixed case and aliases, channel
and private replies, finite large results, private error delivery, input limits
and exactly one success audit event only after a successful conversion.

Only Convert.pm and the conversion argument handling in DBCommands.pm change
in production. No SQL/schema, private setting, persistent format, provider,
rate-limit, command permission or web deployment change is involved. After
full host validation, restart the development bot and check ordinary `!convert`
requests on an enabled test channel. Commit through commit.sh before normal
production updates; no real stream, outage or external API probe is needed.
