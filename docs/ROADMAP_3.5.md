# Mediabot 3.5 readiness roadmap

Last updated: 2026-09-02

Mediabot 3.5 is a consolidation release. The current stable release remains
3.3 and development remains on the `3.4dev` line until an explicit release
decision. No 3.5 tag, stable version change or public release archive is made
implicitly by this roadmap.

Mediabot 3.5 cannot release until the Hailo modernization described by MB720
is implemented, exercised on the development instance and accepted. This is a
named release requirement, not optional feature scope.

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

## Completed evidence

| Work item | Status | Evidence established |
| --- | --- | --- |
| MB713 | Complete | Debian 13 live baseline; development READY; the older deployment classified UNSAFE because of schema drift |
| MB714 | Complete, uncommitted | ScriptRunner timing test measures the execution boundary and passes focused stability plus fast validation; production code is unchanged |
| MB715 | Complete | Two canonical services identified; the duplicate inventory entry removed; 40 schema differences classified |
| MB716 | Complete | 64 aggregate read-only probes; 52 orphan command owners identified; four optional seed names planned; timestamp semantics marked for review |
| MB717 | Complete | Private disposable MariaDB rehearsal normalized 52 owners, reduced 40 schema differences to zero, preserved the ordered timestamp evidence, then restored the original 40-difference state and removed the clone |
| MB718 | Complete, variance recorded | Debian 13 root access restored through `unix_socket`; application identities remained unchanged; the post-repair privilege-mask representation change is carried into MB719 for an explicit `SHOW GRANTS` check |

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
| MB720 | P0 | Hailo has an isolated per-channel brain, MegaHAL-compatible message policy, reply-before-learn ordering and a language-aware provider-neutral post-editor that preserves the learned draft or falls back to it safely |
| MB721 | Complete on development pilot | Google Gemini is a strict native provider and `!gemini` is independently opt-in through `+Gemini`; a bounded live provider smoke and opt-in IRC pilot passed while key/configuration and wider channel activation remain operator-controlled |
| MB722 | P0 | Supported instances converge one at a time and complete a seven-day observation window without unexplained restart, reconnect loop, persistent worker failure or schema drift |
| MB723 | P1 | The supported versus experimental boundary for `mbweb` is decided, tested and documented |
| MB724 | P1 | Security, privacy, observability and restore gates are updated for 3.5 and exercised on the supported deployment |
| MB725 | P1 | A fresh Debian 13 installation and a representative 3.3-to-3.5 upgrade both succeed in disposable environments with rollback evidence |
| MB726 | P1 | Installation, update, database, systemd and release documentation agree; release archives are reproduced and inspected in a dry run |
| MB727 | Final | No open blocker; release candidate soak complete; one final full suite passes; the operator gives an explicit release decision |

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

## MB720 Hailo release gate

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

The gate closes only after aggregate metrics, rollback, legacy-brain seeding,
channel isolation, code-switch behavior and provider fallback are covered by
tests and a development pilot. No nickname, channel text, prompt, draft or
provider answer may enter metrics.

## Cross-cutting 3.5 gates

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

## Release decision

The roadmap is complete only when MB727 records all gates as satisfied. Until
then, 3.3 is the stable release and `3.4dev` is the only development identity.
The final version change, tag, archive publication and deployment each require
the normal explicit release procedure.
