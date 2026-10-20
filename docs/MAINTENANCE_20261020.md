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
