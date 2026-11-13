# IRC reload and recovery — bounded final checkpoint

MB1278, reviewed against `7be8921498b9c7aaa3206770fcc1b5a1d71721d4`
(committed MB1277). Every tracked file matches the supplied 2026-11-13 09:36:13
snapshot. No runtime behavior changes in this checkpoint.

## Expected contract and verdict

Reload failure must be visible, confirmed configuration must survive a failed
replacement, and old callbacks must not regain authority after their owner is
retired. Reconnect, configuration reload and process exit are distinct boundaries.
Verdict: **partly covered**. The selected keepalive recovery defect was corrected
by MB1277; the remaining limits below are not promises of global transactionality
or Eggdrop feature parity.

## Entry points and actual scope

| Operation | Source owner | Guarantee and boundary |
| --- | --- | --- |
| `.reloadconf`, `.reload` | [Commands](../Mediabot/Partyline/Commands.pm), `_reload_configuration_file`, `_cmd_reloadconf`, `_cmd_reload`; [Conf](../Mediabot/Conf.pm), `reload` | Updates the existing Conf object after parsing and checking file revision. Failure retains old values; success removes absent keys and unsaved overrides. Commands report bounded failures. This does not rebuild all consumers. |
| SIGHUP | [main](../mediabot.pl), `catch_hup`; [core](../Mediabot/Mediabot.pm), `readConfigFile` | Constructs and publishes a new Conf owner, with console success/failure reporting. Existing consumers retaining the old object are not globally rebound. It does not invoke full rehash. |
| `.rehash` | Commands `_cmd_rehash`; core `rehash_runtime_state`, `reload_logger_from_config`, `rebuild_channel_cache` | Sequential config, logging and channel/nicklist refresh. Failure is reported but earlier successful phases are not rolled back. This is not an atomic runtime transaction. |
| Reconnect/restart | main `reconnect`; core `restart_irc`, `setIrc`; [Recovery](../Mediabot/IRC/Recovery.pm), `ping_timeout` | Existing loop/Partyline survive; old output ownership retires on transport replacement. Keepalive expiry requests the existing delayed recovery path. Unsent old output is failed, not replayed. |
| Plugin jobs / timers / exit | [resource inventory](RUNTIME_RESOURCE_OWNERSHIP.md) | Each family owns registration identity and retirement. Final worker collection is bounded; unconfirmed children remain diagnosed/owned. No universal stop-all contract is claimed. |

Conf's prepare-then-publish boundary validates parser success and unchanged file
revision, not the semantics of every subsystem setting. A syntactically valid
configuration can still fail later initialization. At the reviewed MB1278 base, logging reload closed the old raw LOG handle before
opening the replacement; MB1279 fixes that local publication boundary (see below).
MB1280 subsequently stages channel reads before publication (see below). Failed rehash must not be described
as leaving all runtime state unchanged. These source-level limitations are
recorded for a separate transactional-rehash improvement, not silently repaired
by this documentation increment.

## Reproducible evidence

Run from the repository with normal development dependencies:

```bash
perl -I. tools/dev/irc-reload-probe.pl
perl t/test_commands.pl --filter '^(587_|1213_|608_|575_|1072_|403_|1311_|1520_)' --progress
```

- The new 12-assertion probe uses real Conf and Config::Simple with disposable INI
  files: publication, removal of old keys/unsaved overrides, object identity and
  preservation after a missing replacement. It starts no application or service.
- Case 587 tests reload-command failure/success and config publication with a
  synthetic parser; it is not native parser coverage. Case 1213 covers atomic
  saving and revision conflicts; saving a file is not activating every consumer.
- Cases 575/1072 characterize scheduler/plugin lifecycle ownership. Cases
  403/1311/1520 cover timer publication, native retirement and inline callbacks.
- Case 608 includes MB1277 native socket-pair keepalive recovery. It does not
  prove an actual TCP reconnect/login to a live IRC server.

Local validation: the eight cases pass **1,001 assertions**, and the native
probe passes **12 assertions**. Initial attempts were blocked by missing local
String::IRC and URL::Encode dependencies; after installation in an isolated
development directory, the full targeted lane and native core loading succeed.
No complete runtime suite is claimed for this documentation/tool increment.

No new performance, live-network or whole-process rollback guarantee follows
from these checks. See [authority](IRC_AUTHORITY_CHECKPOINT.md) and the
[roadmap](IRC_CONTRACT_ROADMAP.md) for the other bounded verdicts.

## Chapter handoff

All five comparison rows now have a verdict. The assessment and selected-fix
implementation sequence is complete; optional parity features do not extend it.
The current snapshot contains committed MB1277. Commit presence and the
maintainer's continuation are recorded, but missing detailed host test reports
and activation evidence are not reconstructed. Formal acceptance remains subject
to the roadmap's host-validation gate; this documentation package does not replace
MB1277's required full runtime suite or activate the new code.

After acceptance, prioritize separately: transactional rehash and precise phase
diagnostics, then bounded output backpressure if real queue measurements justify
it. Keep readiness/identity and IRCv3 account semantics explicit design decisions.
No new mandatory feature series is opened by this handoff.


## MB1279 — First bounded rehash correction: preserve active logging

Base `ec56b361a5d0562c5274daae0c76a597deed0c2e` is committed MB1278, fetched
from GitHub. No newer snapshot is claimed. Native regression reproduction in
case 1220 loses raw writes after a failed open and replaces the raw destination
before a logger-constructor exception; a false constructor can also erase the
logger owner. Thirteen assertions fail on the unchanged base.

Core `reload_logger_from_config` now opens the raw candidate, constructs the
object logger and transfers console hooks before publishing the pair. On failed
construction it closes the raw candidate and reports failure, retaining both
old owners. On success it closes the old raw handle after publication. Existing
object references, encoding, append mode and console delivery remain compatible.
The existing case uses native core/handles/Log; only constructor error returns
are injected. It tests actual continued file writes and hook delivery.

This is atomic preparation of the logging pair, not a whole-rehash rollback.
Configuration may already have been published; channel staging and accurate
partial-phase reporting remain the next bounded work. Disk-write failures after
publication and externally held logger references are outside this correction.
No database, configuration edit, restart or running-process activation is made.
Local validation passes 218 targeted assertions and 6,128 fast-lane assertions.
Package application/reversal, rejection guards and the native commit.sh path were
exercised with a local-only remote. Targeted and one full installed-host suite
remain required before the real commit; no complete local suite is claimed.


## MB1280 — Preserve the live channel snapshot on read failure

Base `d65eb0d1c7b7e9a6b68ec45d33705c854f0f2f09` is committed MB1279;
every tracked file matches the supplied 2026-11-13 13:47:09 snapshot.
Rebuild previously cleared channels before SELECT, ignored population failure
and could report success after losing the old map. A partial fetch could also
publish an incomplete replacement.

`populateChannels` accepts an optional destination and explicitly reports success.
Ordinary no-argument callers retain their existing map and canonical lower-case
keys. Rehash supplies a separate map and publishes it only after iteration and
statement completion succeed. DBI fetch errors with RaiseError off are checked
before finish can clear them. A genuinely empty successful read publishes an
empty map; a failed read does not. Nicklist timer setup is not reached on read
failure. Existing exception propagation is retained.

The extended case 625 replays the exact extracted owner methods with controlled
statement, channel-constructor and timer collaborators: prepare/execute refusal,
partial fetch exception/error, finish exception/refusal, successful and empty
reads. It checks live-map identity during iteration, retained timers on failure
and publication before one timer rebuild on success. These 48 assertions include
21 failures on the baseline. Cases 622/625 pass 82 assertions locally. This is
not native DBI/core integration coverage; local DBI is unavailable. Host case 65
provides the existing native SQLite/channel integration, followed by one full
suite before commit. No local full-suite pass is claimed.

Limits: this does not roll back earlier config/log phases, atomically rebuild
timers, or make logging callbacks transactional. A timer-setup failure after a
successful cache publication remains a separate lifecycle concern. No schema,
service, live DB or configuration action is performed by the package.


## MB1281 — Refuse false success after timer-setup refusal

Base `00b886345a2f1a513b95a7e450b4991e7af7449e` is committed MB1280;
every tracked file matches the supplied 2026-11-13 14:17:57 snapshot.
The channel rebuild ignored setup_channel_nicklist_timers' return value. With
no event loop, the real NicklistTimers owner refuses setup, but channel rebuild
and rehash still reported completion. Eight probe assertions fail on the base.

Rebuild now returns failure on a false/undefined setup result and diagnoses the
partial state: the confirmed channel snapshot has already been published, but
nicklist setup is incomplete. The existing rehash caller propagates failure;
Partyline's existing error path consequently remains authoritative. Successful
setup keeps the same completion messages; exceptions still propagate unchanged.
No timers are retried or rolled back by this change, and no old snapshot is
restored over a newly published one.

The existing extracted-method probe additionally executes rehash_runtime_state.
The missing-loop case uses native NicklistTimers::setup; explicit false, throw
and success outcomes use controlled collaborators. Earlier config/logger phases
are controlled, not a native full-bot integration. All 80 probe assertions and
114 assertions across cases 622/625 pass locally. Native full-core validation is
not claimed with local DBI absent. Host compilation, the relevant regression lane
and one full --progress suite remain mandatory before commit.

This is outcome propagation, not all-or-nothing rehash. Config/logger changes and
a confirmed channel map can remain applied on failure. Physical cleanup failures
that the timer owner handles internally are outside this return-value correction.
No service restart, schema or configuration change is performed.
