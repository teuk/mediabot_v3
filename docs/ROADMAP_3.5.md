# Mediabot 3.5 readiness roadmap

Last updated: 2026-09-05

Mediabot 3.5 is a consolidation release. The current stable release remains
3.3 and development remains on the `3.4dev` line until an explicit release
decision. No 3.5 tag, stable version change or public release archive is made
implicitly by this roadmap.

The MB720 Hailo engineering gate is now implemented, exercised and accepted on
the development instance. That closes the feature-construction gate, not the
release: supported-instance convergence, live observation and the remaining
database, security, installation and release gates are still mandatory.

## Release principles

- Prefer measured compatibility and recovery evidence over unbounded feature
  scope. The explicitly required Hailo work remains inside the 3.5 boundary.
- Keep application database credentials least-privileged. Host database
  administration must use a separate local administrator identity.
- Treat a disposable-clone rehearsal as evidence, never as permission to alter
  production.
- Run focused and fast validation while iterating. Run a full suite only when
  the matching commit is imminent, and run one final full suite for the release
  candidate immediately before its release commit.
- Preserve a checkpoint and rollback boundary for every live change.

## Current position

- MB720 Hailo and MB721 Gemini are complete on the development line. Their
  runtime behavior, fallback boundaries and private-state handling have focused,
  fast, full and bounded live evidence.
- FULL01 `+Fullop` is committed and its real-network pilot is active on the
  intended nbot channel. The pilot confirmed the main guard and also exposed a
  service-causality gap: an official network bot mirrored an authorized ban
  and was mistaken for an independent actor. The bounded delegation correction
  must be deployed and observed before acceptance can close; no simulated IRC
  client substitutes for that evidence.
- The critical release path now closes the FULL01 live acceptance and MB719,
  qualifies mbweb under MB723, exercises the cross-cutting MB724 gate, and only
  then starts supported-instance convergence and observation under MB722.
- MB723 is complete and mbweb is accepted into the supported 3.5 surface. The
  real HTTPS route matrix, persistent sessions, least-privileged database
  identity, read-only capability status, deterministic dependency install,
  sandboxed service, health checks, update and rollback all passed without
  restarting an IRC service.
- MB724 is complete on development. The source security contract now covers 37
  fail-closed invariants over 16 cross-cutting 3.5 axes, and its operational
  boundaries passed read-only on the supported deployment without changing a
  service, database grant or private configuration.
- Fresh Debian 13 installation and representative 3.3-to-3.5 upgrade rehearsal
  remain deliberately last among the technical gates. They validate the final
  accepted surface rather than an intermediate one.
- Completing a feature on development never authorizes production activation,
  a stable version change or a release.

## Completed evidence

| Work item | Status | Evidence established |
| --- | --- | --- |
| MB713 | Complete | Debian 13 live baseline; development READY; the older deployment classified UNSAFE because of schema drift |
| MB714 | Complete | ScriptRunner timing test measures the execution boundary and passes focused stability plus fast validation; production code is unchanged |
| MB715 | Complete | Two canonical services identified; the duplicate inventory entry removed; 40 schema differences classified |
| MB716 | Complete | 64 aggregate read-only probes; 52 orphan command owners identified; four optional seed names planned; timestamp semantics marked for review |
| MB717 | Complete | Private disposable MariaDB rehearsal normalized 52 owners, reduced 40 schema differences to zero, preserved the ordered timestamp evidence, then restored the original 40-difference state and removed the clone |
| MB718 | Complete, variance recorded | Debian 13 root access restored through `unix_socket`; application identities remained unchanged; the post-repair privilege-mask representation change is carried into MB719 for an explicit `SHOW GRANTS` check |
| MB720 | Complete on development pilot | Hailo has isolated per-channel brains, reply-before-learn ordering, MegaHAL-compatible policy boundaries and an asynchronous language-aware provider-neutral post-editor with deterministic fallback and late-revocation evidence |
| MB721 | Complete on development pilot | Google Gemini is a strict native provider and `!gemini` is independently opt-in through `+Gemini`; a bounded live provider smoke and opt-in IRC pilot passed while key/configuration and wider channel activation remain operator-controlled |
| FULL01 | Live pilot in progress; service correction required | Opt-in `+Fullop` opens operator status to all while reversing unauthorized join/speech restrictions; the real pilot exposed one official-service causality gap, now bounded to a one-shot same-target delegation after an authorized ban |
| MB723-A | Complete on development source | First-class `npm test` lane: 23 deterministic tests cover configuration, authentication, authorization, parameter and SQL bounds, repository outcomes, safe HTTP errors, bounded upstreams, startup failure and graceful shutdown without credentials, external network or a live database |
| MB723-B | Complete on development source | The 45-test Node lane now covers persistent MariaDB sessions, explicit expiry and cleanup, one bounded reconnect retry, central session-bound CSRF, POST logout, fixed-capacity login throttling and redacted logs; migration and grants are delivered but not applied by this source gate |
| MB723-C | Complete on development pilot | Real HTTPS login, protected logout and the supported route matrix passed through the reverse-proxy base path; the dedicated database identity is read-only outside `MBWEB_SESSION`, and channel details expose Hailo, Gemini, Spark and Fullop status without a control API |
| MB723-D | Complete on development deployment | Canonical source synchronization, `npm ci --omit=dev`, dependency audit, sandboxed systemd service, reverse-proxy/base-path checks, loopback health, private backup, update and rollback passed while IRC services remained unchanged |
| MB723 | Complete — supported | All four gates passed; mbweb joins the supported surface that MB724 must exercise before MB722 convergence and observation begin |
| MB724 | Complete on development | `security_audit.pl` checks 37 invariants over 16 axes; exact source, service identities/state, loopback metrics, Doctor read-only database evidence, mbweb local/HTTPS health, grants, private files and MB723-D restore evidence passed without runtime mutation |

MB717 proves that the data and schema plan can be replayed and reversed in an
isolated server. It does not qualify a production migration. The production
database, services and repositories remained unchanged during that rehearsal.

MB718 is closed. The local administrator path is operational again and must not
be reopened through another repair-wrapper iteration. Its one recorded
variance is a concrete MB719 preflight item, not authority for more host work.

## Remaining release path

| Work item | Priority | Exit condition |
| --- | --- | --- |
| MB719 | P0 | Root grants are captured and accepted, production schema reconciliation is backed up, explicitly confirmed, applied through the reviewed plan, verified drift-free and proven restorable |
| FULL01 live pilot | Operational acceptance | nbot runs the corrected source, `+Fullop` remains limited to its intended pilot channel, real server capabilities drive the guard, joiners receive operator status, unauthorized restrictions are reversed and the exact ten-minute sanction expires cleanly; an authorized ban mirrored by the official service is accepted once for the same target without general service privilege; privileged restrictions and ordinary kicks retain their documented behavior |
| MB722 | P0 | Supported instances converge one at a time with all accepted components and complete a seven-day observation window without unexplained restart, reconnect loop, persistent worker failure, web-session failure or schema drift |
| MB726 | P1 | Installation, update, database, systemd and release documentation agree; release archives are reproduced and inspected in a dry run |
| MB725 | Final technical gate | A fresh Debian 13 installation and a representative 3.3-to-3.5 upgrade both succeed in disposable environments against the accepted release candidate, with rollback evidence |
| MB727 | Final | No open blocker; release candidate soak complete; one final full suite passes; the operator gives an explicit release decision |

The FULL01 live pilot may proceed before MB719 because it changes no release
status and activates no feature outside its explicit channel. It cannot close
MB722 by itself. MB722 must not start while MB723 or MB724 is open: the
seven-day observation window begins only after every supported component has
an accepted source, configuration, schema and operational baseline.

## Active 3.5 workstreams

- **Real IRC acceptance:** finish the FULL01 service-delegation pilot with
  server-origin evidence, expiry evidence and an immediate disable path.
- **Production data:** close MB719 with effective-grant capture, private backup,
  reviewed reconciliation, drift-free verification and restore proof.
- **mbweb promotion:** MB723 accepted the contributed console into the
  supported surface; MB724 exercised it with the other accepted components.
- **Cross-cutting safety:** MB724 updated the source contract and exercised
  authentication, privacy, metrics, workers, systemd boundaries and restore
  read-only across the accepted surface.
- **Convergence and soak:** update accepted instances one at a time, then give
  the complete candidate a genuine seven-day MB722 observation window.
- **Release proof:** reproduce documentation and archives under MB726, run the
  final Debian 13 install and upgrade rehearsals under MB725, then stop for the
  explicit MB727 decision.

## Immediate operational sequence

1. Update nbot through its normal updater and verify the expected version,
   clean service restart, migration registry and unchanged private instance
   configuration.
2. Confirm `Fullop` exists but is disabled everywhere, then enable it only on
   `#i/o` after Mediabot's durable operator rights and service masks are known.
3. Capture real-network evidence for automatic operator status, restoration of
   an unauthorized restriction, the fixed warning, the single ten-minute
   kickban and its expiry, a privileged restriction, an ordinary kick, and one
   authorized service-mirrored ban without a false Cronos sanction.
4. Disable `+Fullop` immediately on any unexplained mode loop, residual ban,
   privilege-resolution error or service interaction; retain the application
   log and database evidence for diagnosis.
5. Close MB719 through the separately reviewed production database procedure;
   do not reuse disposable-clone success as live authority.
6. Reuse the accepted MB723-A/MB723-B/MB723-C evidence and the completed
   MB723-D operational promotion. Keep mbweb read-only except for explicitly
   bounded local maintenance actions.
7. Reuse the completed MB724 read-only evidence, then converge supported
   instances one at a time.
8. Begin MB722's seven-day observation window only after that convergence. Do
   not backdate it with development or partial-surface evidence.
9. Reproduce release documentation and archives under MB726.
10. Run MB725 last: a fresh Debian 13 installation and a representative
    3.3-to-3.5 upgrade in disposable environments, both with rollback proof.
11. Stop at MB727 for the final full suite and explicit operator decision.

## MB718 administrator result

The Debian 13 migration left no usable local administrator client path. MB718
restored `root@localhost` to `unix_socket` authentication while leaving every
Mediabot database identity unchanged. The normal root client, a client with
defaults disabled and the Debian maintenance client path all authenticated
after the repair; MariaDB also returned to its normal service state.

The configured Mediabot database identities may still read and write only the
objects required by the application. They did not receive `CREATE`, `ALTER`,
`DROP`, `GRANT OPTION` or access to MariaDB privilege tables.

The final exact comparison observed a change in MariaDB's internal `access`
field after `ALTER USER`, despite successful root authentication and plugin
checks. This variance is not silently accepted: MB719 must capture
`SHOW GRANTS FOR root@localhost`, compare the effective privileges with the
DDL and restore operations it requires, and stop before any production change
if the result is insufficient or broader than intended. It is not a reason for
further MB718 host intervention.

## Execution rule after MB718

Read-only inventory is no longer a standalone work item unless a new observed
blocker requires it. Each following round must either change the repository or
close one named release gate. Reuse existing evidence, do not repeat a lane that
already passed, and keep iteration to targeted checks plus fast validation when
code changes. The full suite remains reserved for an imminent commit and the
final release candidate.

## MB719 production database gate

MB719 may begin with the working root socket boundary established by MB718. It
must first qualify effective root grants, then reuse the reviewed MB717
normalization and migration plan, take and validate a private backup, verify the
exact target instance, stop only the affected bot when required, and fail
closed on any unexpected row count, schema state or restoration result.
Optional seed names must be inserted disabled; they must not enable a channel
or feature.

The exit state is strict schema and migration evidence without unexplained
differences. A rollback rehearsal is part of the gate, not a post-release task.

## MB720 Hailo engineering gate — complete on development

MB720 replaces the single writable Hailo store with one private channel brain
per RFC1459-casemapped `(network, channel)` identity. Existing training is kept
as an immutable seed for a channel's first brain. Every generated line follows
reply-before-learn ordering so the triggering sentence cannot train its own
answer.

The message policy must retain the useful behavioral boundaries of the former
MegaHAL interface: independent learn, direct-reply and chatter controls;
excluded nicks and command traffic; bounded word counts; paste and log-prefix
rejection; per-user cooldowns; a global flood lock; and a bounded reply queue.
Those semantics are reimplemented against current IRC and configuration
contracts rather than copying legacy Tcl or its presentation hacks.

The exclusion boundary includes a reloadable comma-separated
`HAILO_IGNORE_NICKS` list, shared known-bot identities and the bot's own live
nickname. Outgoing RSS/news announcements must remain outside context,
activity accounting and learning even when IRC `echo-message` reflects them
back through the public ingress handler.

An accepted Hailo draft then passes through the common provider-neutral AI
client. The post-editor receives a small sanitized context plus the configured
channel language, triggering-phrase language and draft language. It may repair
spelling, grammar and immediate coherence, but the learned draft remains the
creative anchor. Timeout, provider failure, malformed output, an unsafe line
or excessive rewriting falls back to the original sanitized Hailo candidate.
Provider access is asynchronous and must never block the IRC event loop.

The development gate is closed: aggregate metrics, rollback, legacy-brain
seeding, channel isolation, code-switch behavior, late authorization and
provider fallback are covered by tests and the accepted development pilot. No
nickname, channel text, prompt, draft or provider answer enters metrics.

MB722 now owns the remaining Hailo release evidence: each supported instance
must adopt the accepted implementation one at a time and complete the shared
observation window without isolation loss, reconnect loops, persistent worker
failure or privacy regression. Reopening MB720 requires a newly observed defect,
not another rehearsal of evidence that already passed.

## MB723 mbweb promotion gate

mbweb returned to the 3.5 path as a **supported candidate** and is now an
accepted supported component. The detailed contract lives in
[`MBWEB_3.5.md`](MBWEB_3.5.md). Promotion is divided into four ordered gates:

1. **MB723-A — deterministic test baseline (complete on development).** The
   first-class Node lane now runs 23 focused tests for configuration,
   authentication, authorization, request parsing, repository outcomes, route
   error boundaries, bounded upstreams and lifecycle. Database, HTTP, metrics
   and Partyline inputs use bounded fakes; no listener or live secret is used.
2. **MB723-B — session and request security (complete on development source).** Replace the production
   `express-session` memory store, apply CSRF protection to every state-changing
   request, make logout a protected POST, bound and prune login throttling, set
   explicit session expiry, retain secure proxy/cookie handling and prove SQL
   parameterization plus least-privileged database access.
3. **MB723-C — read-only development pilot (complete).** The real sub-path,
   authenticated route matrix and protected logout passed on development.
   Channel detail exposes the accepted capability state through read-only DB
   queries, and no IRC service or channel policy was changed. The gate covers
   network and instance identity, channels, users, commands, radio, metrics,
   diagnostics and Partyline views against the development instance without a
   general web control plane.
4. **MB723-D — operational promotion (complete; supported).** Canonical source synchronization,
   `npm ci --omit=dev`, reproducible dependency audit, a sandboxed systemd unit,
   reverse-proxy headers and base path, health checks, backup, update and
   rollback passed on the development deployment. The explicit outcome is
   supported; MB724 subsequently exercised the complete supported surface.

MB723 was not closed by screenshots, a running process or dependency contracts
alone. It required application tests, a bounded live development pilot and an
operational rollback rehearsal. Promotion did not silently add database write
authority, publish secrets, expose raw conversation content or make mbweb a
prerequisite for the IRC bot to operate.

## Cross-cutting 3.5 gates

MB724 converts this list into 37 executable, fail-closed source invariants and
exercises the corresponding boundaries read-only on the supported deployment.
Both source and operational evidence are required before MB722 convergence.

- IRC lifecycle, reconnect, flood control and clean shutdown remain stable.
- Database charset, constraints, indexes, migrations and durable state agree
  with the supported reference.
- Script execution, child processes and asynchronous workers remain bounded.
- HTTP, TLS, redirects, size limits and private-address protections are tested.
- DCC, Partyline, privileged commands and updater authorization fail closed.
- AI and social-history features preserve opt-in, timeout, quota and privacy
  boundaries; no raw conversation content enters metrics.
- Hailo channel brains remain isolated; provider post-editing preserves the
  learned draft and has a deterministic local fallback.
- systemd identities and writable paths stay minimal.
- backups have a recent successful restore proof.
- public archives contain no credentials, runtime data, logs or private
  operator material.
- mbweb uses a durable production session store, protected state-changing
  requests, least-privileged database credentials and bounded upstream calls;
  its failure cannot interrupt an IRC instance.

## Release decision

The roadmap is complete only when MB727 records all gates as satisfied. Until
then, 3.3 is the stable release and `3.4dev` is the only development identity.
The final version change, tag, archive publication and deployment each require
the normal explicit release procedure.
