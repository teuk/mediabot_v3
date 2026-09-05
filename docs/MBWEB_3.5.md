# mbweb 3.5 promotion contract

mbweb returned to the Mediabot 3.5 release path as a supported candidate and
has now passed the four evidence gates defined here. It is included in the
supported surface exercised by the remaining cross-cutting release gates.

The IRC bot remains the primary service. A stopped, unhealthy or rolled-back
mbweb must not interrupt Mediabot, alter IRC reconnect behavior or prevent an
instance from starting.

## Current baseline

The canonical application lives in `contrib/mbweb`. MB723-A supplies a
first-class Node lane and testable runtime boundaries in addition to the npm
manifest and lockfile. MB723-B adds persistent production sessions, central
request forgery protection, bounded login throttling and safe error logging.
MB723-C adds read-only capability status and completes the bounded development
pilot. Those changes close the first three gates, not the packaging gate.

All four promotion gates are now complete. mbweb is accepted into the
supported 3.5 surface, subject to the same MB724 cross-cutting gate, MB722
convergence and observation, and final release checks as the IRC service.

## MB723-A — deterministic application evidence

**Status: complete on the development source.** `npm test` runs 23 focused
tests with the built-in Node runner. It needs no `.env`, Node dependency tree,
network endpoint or database server. Pure configuration, authentication,
session and SQL decisions are shared with the runtime adapters; repository and
upstream behavior is driven by bounded fakes; HTTP and lifecycle tests open no
listener. `node app.js` retains the normal runtime entry point.

The accepted lane must continue to run without live credentials, external
networking or a real production database.

The minimum focused matrix covers:

- configuration validation, base-path normalization and secret rejection;
- password verification, session-user normalization and role boundaries;
- request parameter bounds and SQL allowlists;
- repository success, empty, malformed and database-error outcomes;
- route authorization, not-found handling and safe error rendering;
- bounded radio, metrics and Partyline upstream behavior;
- graceful startup failure and shutdown without a hanging worker.

The Perl fast lane remains mandatory, but it does not replace the Node
application lane. Dependency hygiene and audit contracts remain in place.
Any change to these boundaries must rerun the Node lane before the Perl focused
and fast lanes. MB723-D subsequently accepted this baseline for deployment.

## MB723-B — session and request security

**Status: complete on the development source.** MB723-B replaces implicit
production MemoryStore use with a dedicated MariaDB session store and a
fail-closed production configuration. It adds an idempotent table migration but
does not apply it or grant any account during the source round. Live migration,
dedicated-account grants and reverse-proxy evidence remain bounded operator
steps for MB723-C and MB723-D.

Production must refuse the default in-memory session store. The accepted store
must have explicit expiry, batched cleanup, reconnect and failure behavior and
must not require broader MariaDB rights than its documented objects.

Every state-changing route uses a session-bound CSRF token and an intentional
HTTP method. Request bodies are bounded. Logout becomes a protected POST. The
owner-only cache clear stays bounded, auditable and refreshes authorization
synchronously; a database failure blocks the mutation. Login throttling has a
fixed capacity or periodic pruning so arbitrary source addresses cannot grow
memory without bound.

Cookie and proxy behavior is tested for the deployed topology: `HttpOnly`,
`SameSite`, production `Secure`, explicit maximum age, session rotation after
authentication and loopback-only proxy trust. Logs and error pages never
contain passwords, session secrets, cookies, query contents or private
conversation text.

The deterministic lane now covers 45 tests. Its MB723-B matrix includes:

- production rejection of MemoryStore and non-loopback binding;
- explicit cookie age, table name and cleanup interval bounds;
- parameterized session create, read, touch, delete and batched expiry cleanup;
- one retry for allowlisted transient pool failures, then failure propagation
  without an in-memory fallback;
- resource cleanup when store readiness or HTTP listener startup fails;
- session rotation after login and destruction on protected POST logout;
- timing-safe CSRF validation across every unsafe method, including conflicting
  form and header tokens;
- a 2048-entry login-throttle ceiling, pruning and non-blocking housekeeping;
- redacted audit/error output that cannot echo raw error, URL or query text.

Database access remains least-privileged. Queries are parameterized; dynamic
identifiers come only from explicit allowlists. No schema-administration grant
is added for mbweb.

## MB723-C — read-only development pilot

**Status: complete on the development pilot.** The pilot uses the canonical
development identity and real HTTPS reverse-proxy base path. It verifies
login, logout, navigation and bounded failure behavior for:

- profile and dashboard;
- network, channels, channel details and users;
- commands and quotes;
- radio, metrics, diagnostics and Partyline summaries;
- visible status for accepted Hailo, Gemini, Spark and Fullop capabilities.

Channel detail now reads those capability states directly from `CHANSET_LIST`
and `CHANNEL_SET` through one fixed allowlist and parameterized channel lookup.
Both HTML and JSON expose enabled, disabled or unavailable state; no route can
change a chanset. Hailo learn/respond/chatter and Spark action sub-capabilities
remain visible without widening the four supported capability groups.

The pilot does not add a general bot-control API. Except for explicitly bounded
local maintenance such as owner-only cache clearing, mbweb observes state and
does not mutate IRC, channel policy or application data. A failed upstream is
shown as unavailable without blocking unrelated pages or the IRC service.

No screenshot or process status replaces route evidence. The accepted pilot
checkpoint records the exact source, Node version, dependency lock digest,
service identity, base path, tested views and rollback point without copying
credentials or private payloads. The session table was applied through the
local administrator path; the dedicated pilot account has SELECT only on the
explicit console read surface and session-row DML only on `MBWEB_SESSION`.
No Mediabot IRC service was restarted.

## MB723-D — operational promotion

**Status: supported after operational promotion.** The canonical
`install/mbweb_deploy.sh` path stages cleaned content from `contrib/mbweb`, runs
`npm ci --omit=dev --ignore-scripts` against the committed lockfile, records a
machine-readable dependency audit and refuses high-severity findings. It never
copies `.env`, logs, caches, `node_modules`, sessions or local archives from
the repository source.

Production dependencies are staged with a private operator umask, then the
candidate modes are explicitly normalized for a root-owned read-only runtime.
Before any service stop, every declared dependency is resolved and loaded from
the staged application under the `mediabot` Unix identity. The same proof runs
against the installed tree and during read-only verification; `.env` remains
owned by `mediabot` at mode `0600`.

Canonical source and installed runtime are compared by checksum after excluding
private and generated paths. That comparison deliberately ignores owner, group
and permission metadata because the repository and hardened runtime have
different ownership contracts. Rollback and baseline backup comparisons retain
full metadata checks.

Activation is serialized with a lock and starts only after an exact private
backup of the installed application and service unit. A failed activation
automatically restores that backup. The same backup path supports an explicit
rollback command, and a separate verify action compares canonical source,
installed unit, dependency tree and loopback health without mutation.

The accepted systemd unit runs as the least-privileged `mediabot` Unix identity
with `NoNewPrivileges`, a private temporary directory, kernel and filesystem
protections, a read-only application tree and explicit restart rate limits.
It has no persistent writable filesystem path; application persistence is
limited to the separately granted MariaDB session rows. The live development
rehearsal verified the loopback health endpoint, HTTPS proxy headers and base
path, backup, update, rollback and a final redeployment without restarting any
Mediabot IRC instance.

The recorded outcome is **supported**. mbweb therefore joins the complete
surface exercised by MB724 and later converged under MB722. This acceptance is
not a release, version change, tag or authorization to skip those later gates.

## Validation and commit policy

Each MB723 engineering round runs the narrow Node and Perl tests that cover its
change, followed by the project fast lane. Previously passed lanes are reused
when the exact source and checkpoint are unchanged. The full suite is reserved
for the imminent commit, consistent with the 3.5 roadmap.

Every live change has an operator confirmation, a private backup, a bounded
rollback and a post-change read-only verifier. No release version, tag or
archive is implied by completing MB723.
