# Mediabot qualification roadmap

Accepted by the maintainer on 2026-11-13. This is the active continuation after
bounded architecture and IRC-contract assessment. It does not reopen their
extraction or Eggdrop-parity scope. Baseline: MB1290, commit
`31b9ffc2444e2d62ac9667ef6afad4cb5642973f`.

## Five steps and exit gates

| Step | Deliverable | Exit evidence | Status |
| --- | --- | --- | --- |
| 1. Reproducible validation environment | Disposable checkout, complete native dependencies, recorded environment and one qualification command shared with CI practices | Fresh setup can run native validation; missing dependencies fail explicitly; source/dependency identity is recorded | Accepted on MB1296 (`d17bb81f`): fresh Debian full lane passed; source-bound reports and native/module inventory retained. Rebuilds remain observed, not dependency-locked. |
| 2. Local IRC integration | Simulated server and native command paths, no production configuration | Public command, private command and deferred reply interrupted by reconnect all pass; old output cannot reach the successor transport | Bounded MB1297 journeys accepted by complete offline CI on `431c45a6`; full receive-handler/login coverage remains outside scope |
| 3. Controlled failure scenarios | Storage, HTTP, worker and logging failures in the local harness | Bounded completion, explicit diagnosis, retained authority and recovery demonstrated for each selected fault | Selected MB1298/MB1299 matrix accepted by fresh CI on `e838b9fa`: SQL/diagnostic faults, HTTP 503, native worker timeout and recovery. Wider faults remain outside this bounded matrix. |
| 4. Saturation and endurance | Repeatable workload and resource measurements | Report queue depth/age, control response delay, dropped/expired output and post-drain resources; establish budgets before adjusting policy | Accepted on teuk for MB1302 (`d9452420`): 300 cycles, 1,200 deliveries, 1,203.047s, stable descriptors/notifiers, RSS growth 2,468 KiB. Production fairness and hours-long stability remain outside scope. |
| 5. Shared command contracts | Reusable matrix over selected representative commands | Private/channel routing, permission revocation, identity, Unicode and storage errors covered; preserve command-specific semantics | MB1303 implements twelve representative contracts over echo, spike and addbadword; host/full CI acceptance pending. |

Each step ends with an explicit pass/fail/unavailable verdict and a bounded list
of residual limits. Report source commit separately from installed/running code.
Fix only reproduced blocking defects as separate, reversible runtime changes.
No database migration, service restart, external IRC login or production data
belongs to this qualification campaign. Offline tests are not network containment:
step 2 must establish the local-only transport boundary and later isolation.

## MB1291 — Source isolation and honest preflight

`tools/qualification/run.py` clones the explicitly identified HEAD into a private
temporary directory without copying untracked deployment files or dirty changes.
The clone retains .github and Git metadata because existing tests read them;
git archive would exclude required files through export-ignore. No source worktree
is reset or modified. The supplied local dependency path is optional and explicit.
Ambient Perl module paths and PERL5OPT are removed; HOME/TMPDIR point to the
private workspace. PATH still chooses the host tools: this is not yet a hermetic
environment or a dependency lock.

The runtime dependency inventory remains owned by install/cpan_install.sh;
DBD::SQLite is separately checked as documented in DEVELOPING.md. No installation
or configure command runs implicitly. A failed dependency gate returns 3 and
records unavailable, without starting the suite. Test failure returns 2; success
returns 0. A per-stage timeout retires the test process group. Output stays visible.
An exclusive report directory contains commit, tool hash, lane, stage status,
exit code and duration. An existing report is never overwritten.

Run on an already prepared development host:

```bash
python3 tools/qualification/run.py --lane preflight --output /tmp/mb-qualification-preflight
python3 tools/qualification/run.py --lane fast --output /tmp/mb-qualification-fast
# Full acceptance, once when appropriate:
python3 tools/qualification/run.py --lane full --output /tmp/mb-qualification-full
```

Choose a new report path each time. For a project-local dependency installation,
add `--perl-lib "$PWD/local/lib/perl5"`. Prepare dependencies using the existing
[development guide](DEVELOPING.md), never the live bot configuration wizard.
The runner always tests committed HEAD: it is not a precommit validator for dirty
patches. Existing maintainer targeted/full precommit validation remains mandatory
for runtime changes. No claim of three whole-bot IRC integration journeys follows
from this foundation.

Acceptance: eight tooling tests cover source isolation, symlink refusal, lane
selection, dependency/test failure distinction, report preservation, environment
cleanup and native subprocess outcomes. Native local preflight is expected to
report unavailable where Perl dependencies are absent. Target-host preflight
and subsequent environment provisioning acceptance are separate evidence.

Next bounded increment: provision and record the full native dependency environment,
validate it on a fresh installation, then implement the three local IRC journeys.

## MB1292 — Disposable provisioning and observed dependencies

`--provision` explicitly downloads/builds CPAN dependencies into a fresh temporary
module tree. It uses the committed `cpanfile`, adds the SQLite test driver, and
installs the existing Hailo 0.75 fallback distribution. It never invokes sudo or
configure. CPAN dependency tests are skipped as in the existing developer setup;
the selected Mediabot lane runs only after all dependency gates pass. The entire
tree is removed on completion, including failed builds. Console output should be
retained by the caller for failure diagnosis. Provisioning is never implicit and
cannot be combined with `--perl-lib`.

Use an ordinary account on a disposable Debian 13 development machine prepared
with the native build tools from DEVELOPING.md (plus git, python3 and CA roots):

```bash
python3 tools/qualification/run.py --provision --lane full \
  --timeout 3600 --output /tmp/mb-fresh-qualification-UNIQUE
```

The maximum time applies to each stage, not to the whole command. CPAN downloads
need network access. No IRC connection or application configuration is needed.
A fresh module tree on an existing host is not proof of a fresh operating-system
setup; record the machine/image used for that acceptance separately.

`report.json` records the source commit, provisioning choice and SHA-256 of the
two dependency inputs. After successful runtime/SQLite checks, `environment.json`
records Perl identity, required module versions and hashes/paths of loaded Perl
files including transitive loads. Missing modules fail; unknown installer-list
syntax fails closed. This is an observed inventory, not a lockfile: CPAN resolution,
XS binaries and system packages are not pinned. Default host PATH/core libraries
remain trusted. CPAN/Perl installation overrides and shell startup hooks are
removed from the child environment; this is not a security sandbox.

Local acceptance: 12 tooling tests pass, including actual Perl inventory output,
missing-module detection and file hashing, malformed inventory rejection, contained
provisioning command order, early failure, environment cleanup and report-symlink
refusal. Provisioning orchestration uses test doubles; no successful fresh CPAN
installation or full native suite is claimed. Target-host and disposable-machine
acceptance remain required before closing step 1 or starting step 2.


## MB1293 — Native Moose inventory repair

MB1292 was committed/pushed as `ae960d4759c5cdd7081cb4f3ed21f1d959f4e3d0`.
The maintainer's 12 tooling tests passed, as did runtime and SQLite dependency
checks on Perl 5.40.1 / DBD::SQLite 1.78. Inventory failed on a generated
Class::MOP immutable package; host preflight was unavailable, not accepted.

Class::MOP::Package::create puts `(set by Moose)` into %INC for packages created
in memory. MB1293 recognizes that exact marker and records those entries in
`generated_modules` (inventory schema 2); actual files remain in `loaded_files`
with SHA-256. Unknown missing/unreadable file paths still fail. Required module
loading remains mandatory. This does not claim hashes for generated code.

The failure was reproduced before correction using the exact marker in a native
Perl subprocess. All 13 Python tooling tests pass after correction, including
retained failure on an unavailable real path. Existing native case 610 also runs
the inventory with installed dependencies and checks Moose's generated and real
entries. Local execution of this case is not accepted: 27/30 assertions pass,
three fail because native dependencies including Moose are absent here. Native
host acceptance is pending. The maintainer workflow is one block: apply, tooling
checks, targeted Perl --progress, full suite --progress, commit.sh --skip-preflight
and push only after success, then committed preflight. The fresh-machine gate for
step 1 remains open independently of this repair.


### MB1293 R2 — Resume after the restrictive-umask fixture failure

Host R1 acceptance: all 13 tooling tests and all 30 case-610 assertions passed.
The full suite reached 42,918 assertions in 1,139 files; 42,917 passed and the
case-1171 lock-mode assertion failed under umask 077. Commit/push did not run.
The FIFO was created as 0600 by mkfifo despite the requested 0640; the runtime
correctly left it unchanged. R2 explicitly chmods only that temporary test FIFO
to 0640 before testing rejection, preserving the assertion against runtime mode
changes. No RSS runtime policy or permissions are changed. Local case 1171
reproduces the old failure under 077 and passes all 40 assertions under both
022 and 077 after correction. Resume from the exact applied R1 worktree, rerun
targeted cases with --progress then one full --progress before commit/push.


## MB1294 — Fresh Debian qualification gate

Host acceptance of MB1293 R2 is complete: 13 tooling tests, 70 targeted assertions,
and all 42,918 full-suite assertions in 1,139 files passed (362 seconds). Commit
`6571028abd692c28a37d18dfe671b53f0025397f` was pushed; its committed dependency
preflight and inventory passed on Perl 5.40.1 / DBD::SQLite 1.78. This evidence
qualifies the existing host, not a newly provisioned environment.

The separate `Fresh qualification` workflow uses a new `debian:13-slim` container,
installs native build prerequisites, creates an ordinary `qualifier` user, then
runs `tools/qualification/fresh.sh`. No dependency cache is restored. CPAN uses
an explicit HTTPS mirror, the committed cpanfile, SQLite and the existing pinned
Hailo fallback; the runner invokes the full suite with visible progress. There
is no Mediabot configure, production connection, database service or migration.

The job starts on master pushes affecting qualification tools, its workflow or
dependency inputs; workflow_dispatch permits a deliberate rerun for any other
source change. Existing CI gates remain independent. It has a 120-minute job
limit; the runner retains its 3600-second per-stage limit. Failure stays failure,
including an installation/network failure. Artifact upload is attempted even on
failure and retains available evidence for 14 days:

- platform.txt: UTC time, source commit, user, OS, Perl build, cpanm and package versions;
- qualification.log: visible dependency build/check and full-suite output;
- result/report.json and result/environment.json when those stages produced them.

The container image and CPAN dependency resolution are not locked. This establishes
fresh setup evidence and an observed inventory, not bit-identical rebuilds. The
qualification clone and dependency tree remain disposable. The workflow is not a
network sandbox; local-only IRC transport enforcement belongs to step 2.

Local validation covers 14 tooling tests, shell pipelines preserving failure
status, exclusive evidence directories, root refusal, explicit CPAN mirror and
workflow/shell syntax. The fresh container cannot run in the local delivery
environment (no Docker/Podman); its first CI result remains pending. Close step 1
only after a successful complete fresh run and retention of its source-bound
reports, then start the three local IRC journeys.

Maintainer delivery order: apply, tooling and targeted --progress, full --progress,
then the existing commit.sh --skip-preflight -m as the final action. The delivery
wrapper verifies the known helper hash, exact expected files and remote base,
stages only the reviewed patch, and supplies one final confirmation automatically.
No post-commit local preflight or extra command follows; CI runs independently
from the push. No global yes pipe or permanent helper modification is needed.


## MB1295 — Repair the fresh HTTPS bootstrap

MB1294 is committed as `e1fba50a928e0d2f29b51e1fa0713ed727ce3a7b`; all tracked
files match the maintainer's 2026-11-14 11:17:13 snapshot. Existing CI and Debian
13 fresh-install jobs passed. The new Fresh qualification run
https://github.com/teuk/mediabot_v3/actions/runs/43583807210 failed during its first
CPAN provisioning stage, after all 14 tooling tests passed. The evidence artifact
was retained. No native full-suite acceptance occurred in that fresh job.

The minimal image installed CA roots but no curl/wget and no Perl TLS modules.
CPAN's HTTPS index fetch failed before IO::Socket::SSL itself could be installed,
then reported misleading missing-distribution errors. Reproduced locally using
cpanm 1.7048 without curl/wget/Perl TLS; adding curl resolves the same index.

MB1295 installs curl as a native prerequisite, adds a visible curl version gate
before all CPAN stages, and selects --curl --no-lwp --no-wget explicitly. It keeps
the HTTPS mirror, CA verification, disposable module tree and no-cache policy.
Without curl the runner reports unavailable at provision_transport_dependencies
and never attempts CPAN or the test suite. Ordinary preflight without --provision
still uses installed modules and does not require curl.

All 15 tooling tests pass, including a real missing-executable gate and installer
failure after a successful transport gate. Full fresh-container acceptance stays
pending the next actual CI run; the existing two successful CI jobs do not waive
it. Maintainer delivery still ends with the guarded noninteractive commit/push.


## MB1296 — Complete the native suite prerequisites

MB1295 is committed as `19ba7055f6ebb473ed1e6d35bc7936c3bf079d98` and matches
the 2026-11-14 11:31:01 snapshot. Fresh qualification run
https://github.com/teuk/mediabot_v3/actions/runs/43585558086 now installs all Perl
dependencies, passes the inventory and reaches the entire suite. It fails with
19 failures out of 42,832 assertions across 12 files (187 seconds); the reduced
assertion count includes cases interrupted by missing native executables.
Evidence was retained as artifact 14109867818. This is not fresh acceptance.

Node is required by dashboard/diagnostic projections, including the isolated
MixCloud case. Tcl is required by real sidecar examples. The updater rehearsal
uses pgrep to find its disposable process; without procps it misses that process
and cannot observe its shutdown marker. Locally disabling pgrep reproduces the
same three updater assertions; restoring it passes that case. No production
updater, service, configuration or schema is changed by this patch.

The fresh image now installs nodejs, tcl and procps. Fast/full qualification
checks all three executable names, then their versions, before the suite. A
missing prerequisite stops with unavailable/exit 3 and never runs tests. The
Perl dependency preflight keeps its prior scope. Package versions are already
recorded by fresh.sh; tool versions appear in qualification.log.

Local validation: 16 tooling tests passed, including each missing executable
and the real shell gate's unavailable result before tests. Seven available
native cases pass 143 assertions. A broader ten-case attempt also encountered
three local missing-Perl-dependency errors (JSON and URI::Escape); these are not
counted as acceptance. Full target-host validation and the next fresh CI result
remain mandatory. Step 1 stays open; step 2 has not started.

Maintainer order remains apply, tooling checks, targeted --progress, one full
--progress, then guarded noninteractive commit.sh --skip-preflight and push as
the final local action. No post-commit command follows.


## MB1297 — Local native IRC journeys

Step 1 acceptance is established on commit
`d17bb81f934a6d9c0b813e5cea27eed9c5877e92`. The maintainer passed 16 tooling tests,
432 targeted assertions and 42,918 full-suite assertions (1,139 files, 363 seconds)
before its noninteractive commit/push. All three CI workflows passed. Fresh run
https://github.com/teuk/mediabot_v3/actions/runs/43588184322 passed provisioning,
module inventory, native-tool checks and 42,882 executed assertions (168 seconds).
These totals are recorded separately; neither proves identical optional branch
coverage on the two environments.

The source-bound report, platform inventory, module inventory and qualification
log are preserved in artifact 14111496787. Its archive SHA-256 is
`fc28c5f59ee0d8968acb27072f74963451acaf2664b0d75c40ca0b6a37d749b5`.
A verified copy is included in the MB1297 delivery for retention beyond the CI
artifact's 14-day lifetime. Dependency resolution and container tags remain
unlocked; the acceptance is a fresh setup with recorded identity.

Step 2 uses anonymous AF_UNIX socket pairs. The simulated peer sends real IRC
frames into Net::Async::IRC through Mediabot::IRC::Transport and collects the
serialized response bytes. The harness has no server address argument, DNS or
configuration loading. IRC/loop connect and loop resolver entry points are
locally rejected. This is a local transport boundary, not an OS network sandbox.

Three journeys use native mbCommandPublic/mbCommandPrivate and the actual built-in
registry, handlers, Context and Sender:

- Public !spike returns its expected channel reply through the wire.
- Private !echo preserves accented/emoji UTF-8 bytes and replies only to the nick.
- A public reply is held by the real deferred output queue. Native setIrc replaces
  the connection, retires old output and detaches the countdown. Calling the old
  expiry callback cannot inject a response into the successor; a new private
  command still succeeds and PING receives PONG.

Only storage/history, command admission and output-policy data use controlled
fixtures. Countdown construction is observed but native timers execute. The
harness's small callback maps its two fixed targets into the real dispatch API;
it does not run mediabot.pl's complete receive handler, login/registration,
ignore rules, channel membership or real database permissions. It tests deferred
output retirement, not every asynchronous HTTP/worker completion.

The existing native case 1313 runs these journeys after its pacing/transport
checks. `--lane irc` selects that case in the disposable committed-source runner;
full qualification includes it too. Each wait has a two-second bound and the
journey has a 15-second alarm. Missing dependencies remain unavailable at the
runner gates; assertions fail the test stage. Step 2 target-host acceptance is
pending. Controlled-fault and endurance steps are not claimed by this increment.

Local validation: 16 tooling tests passed. Native case 1313 passes 92 assertions,
including the ten new journey assertions, with real IO::Async/Net::Async::IRC.
A negative control replacing setIrc with a bare assignment fails the stale-wire
assertion as expected. The timer check follows the specific deferred notifier,
not unrelated transport timers. Full host validation still precedes commit/push.


## MB1298 — Confirmed-rule SQL fault and diagnostic recovery

MB1297 is committed as `431c45a64c504736327dabb948b44baaa7796667` and matches
all tracked files in the maintainer's 2026-11-14 12:28:23 snapshot. No numerical
host test transcript was supplied with that snapshot; local MB1297 validation
remains recorded separately above. Complete offline CI run
https://github.com/teuk/mediabot_v3/actions/runs/43590170522 passed 42,893
assertions in 167 seconds, including native case 1313; the Debian 13 fresh-install
workflow also passed. Fresh qualification run
https://github.com/teuk/mediabot_v3/actions/runs/43590170487 passed all stages and
42,892 assertions in 236 seconds. This accepts the bounded three step-2 journeys.
The verified evidence archive (artifact 14112286541) is retained in this delivery;
its SHA-256 is `126cde9e8405e0376dfe1a1fe485d1258875c525e1521e2b343f22a05a7cfd51`.
Totals remain separate across environments. Step 1 retains its MB1296 evidence.

This first step-3 increment extends the same local IRC harness. DBI/DBD::SQLite
creates a private in-memory database containing the two tables required by the
native badword reader. A real public command loads a confirmed blocking rule.
The cache timestamp is expired explicitly, then only the fixture table is dropped
to produce a native SQL exception. The runtime reader, Sender, registry dispatch
and wire transport remain unchanged. No deployment database is opened or migrated.

The wire must show no forbidden public reply and no driver diagnostic. The
confirmed cache object, rules and age survive, one bounded error diagnostic is
recorded and the native error counter increments exactly once. A second attempt
makes just that diagnostic sink throw: confirmed policy still holds, the loop
continues, and the read failure is still counted. Recreating the empty fixture
table permits the next command once, refreshes the cache and leaves no active SQL
statement. Each dispatch is followed by an ordinary NOTICE marker through the
same transport, avoiding PONG priority as an unreliable ordinary-output barrier.

Scope is a failed refresh with previously confirmed rules, plus failure of its
specific error diagnostic. First-load fallback policy is unchanged; this is not
a universal fail-closed storage guarantee. SQLite missing-table exceptions do
not qualify MariaDB connection loss, lock waits, writes, transactions or timeouts.
HTTP/worker faults and other logging call sites remain for later increments.

Local validation: all 16 tooling tests and 109 native case-1313 assertions pass,
including 17 new assertions. A negative control that falsely converts the SQL
error into an empty successful read fails the wire assertion. Existing two-second
waits and the 15-second journey alarm remain in force. Fresh CI now also watches
case 1313 and its three supporting fixtures, so a harness-only change cannot
silently omit the fresh qualification run. Target-host targeted/full validation
remains required before the final noninteractive commit/push.


## MB1299 — HTTP failure, native worker timeout and recovery

MB1298 is committed as `3e8c98c16bde35c7238741f82d0a551c65519064`; all tracked
files match the 2026-11-14 12:52:17 snapshot. All three workflows passed. Fresh run
https://github.com/teuk/mediabot_v3/actions/runs/43592049519 passed 42,909 assertions
in 158 seconds with provisioning and inventory. No numerical host transcript was
supplied with the snapshot. Artifact 14112798301 is verified and retained in the
MB1299 delivery; its archive SHA-256 is
`5e1b82bf5925b81bf71fd4ef0bae82dffcbdf31df35d6ab19d26d3abcdfc6374`.

The existing socket harness now sends real public !version commands through
native dispatch, Version::Command, Version::Remote and AsyncWorker. Its controlled
HTTP client returns 503, blocks inside the child until the native watchdog stops
it, then returns a valid newer version on the recovery attempt. Configuration
and audit storage use fixtures; version reading, HTTP-response validation,
comparison, fork, pipe protocol, result translation, timers and reaping remain
native. A child-written PID marker proves the HTTP boundary ran in that worker,
not in the IRC event loop. No network request is made by the HTTP fixture.

Each attempt must retain the local identity and deliver one callback. HTTP 503
and timeout reasons must survive at the adapter callback boundary. Failure must
not produce a false remote version, false update announcement or raw diagnostic
on IRC: the local identity reply remains available. Recovery must clear the reason
and emit exactly one update after the local reply. After completion, both logical
worker ownership and the physical child record are absent; waitpid confirms that
the native worker already reaped the child. A fixture cleanup guard handles only
children owned by this probe if a setup/wait fails.

The fixture selects a 0.3-second supported adapter timeout without changing any
production timeout. Existing two-second waits and the whole-journey 15-second
alarm remain. Native command output is checked after an ordinary NOTICE marker,
so all earlier ordinary frames have crossed the socket before comparison.

Local validation: 16 tooling tests and 142 native case-1313 assertions pass,
including 33 new worker/HTTP assertions. A negative control that turns HTTP 503
into a successful remote version fails the exact wire assertion. Target-host
full validation and the next CI acceptance remain pending before this matrix is
closed. Commit/push stays the guarded noninteractive final local action.

Limits: the injected HTTP boundary is not a real HTTP server, TCP/TLS failure,
DNS failure or network-isolation proof. This covers normal watchdog termination,
not every KILL escalation or uninterruptible child. Diagnostic assertions concern
the adapter callback; the public version command keeps its existing presentation.
Async completion after connection replacement is separate from the deferred-output
reconnect journey and is not qualified here. No general fault tolerance claim,
endurance budget or deployment database change follows from these selected cases.


## MB1300 — Bounded saturation measurements

MB1299 is committed as `e838b9fa40f14f7d9b6d45602a22b2cfaea47f5a`; all tracked
files match the 2026-11-14 13:14:25 snapshot. Fresh run
https://github.com/teuk/mediabot_v3/actions/runs/43593629107 passed 42,942 assertions
in 236 seconds, with provisioning and inventory. The ordinary offline workflow
also passed. This accepts the selected step-3 matrix, not universal fault tolerance.
No numerical host transcript was supplied with the snapshot. Fresh artifact
14113707122 is retained in the delivery, archive SHA-256
`8c216425be3e1cc9311a40d7c84f038d362083a3cc8984de7882aa48af3d5a17`.

The first step-4 increment uses native Sender, DeferredOutput and Transport over
an AF_UNIX socketpair. Three blocked bursts of forty single-line responses must
admit thirty and reject ten each, retain FIFO order without duplicates, answer
PING while blocked, then release every queued payload and timer. An ordinary
NOTICE barrier confirms all earlier ordinary frames have crossed the socket.
A separate thirty-response batch exercises native expiry with an injected
monotonic advance of 121 seconds. Cleanup returns notifier ownership to baseline
and removes the channel queue registry. Production policy is unchanged.

`saturation.json` records actual admission, delivery, rejection and expiry counts,
peak queue depth, oldest observed queue age, PONG latency, notifier count and,
where /proc permits, file descriptors and RSS. Input file SHA-256 values bind the
working sources; they do not claim that a dirty candidate is its current HEAD.
The qualification runner additionally binds its committed snapshot in report.json.
`--lane load` runs dependency gates and this measurement; `--lane full` records
it before the full suite. Fresh CI consequently retains it in its normal artifact.
The native IRC case also executes the shared assertions without writing a report.

Budgets distinguish existing policy (30 lines, 120-second TTL) from the harness
liveness bound (two seconds per wire wait, fifteen seconds for the whole probe).
Manual draining is accelerated, not a throughput measurement. Injected expiry is
not a real 120-second wait. RSS/fd samples are observations, not a leak threshold;
no production latency SLO follows from local timings. Single-channel bursts do
not establish multichannel fairness, long endurance, memory stability over time
or operating-system/network failure behavior. Step 4 remains in progress.

Local validation: 17 tooling tests, 163 native case-1313 assertions and the
standalone 21-assertion measurement pass. The expected 150 attempts reconcile as
90 deliveries, 30 rejections and 30 expirations. A negative control changing the
native cap to 31 fails and emits a failed JSON verdict. Full local qualification
is unavailable without DBD::MariaDB; host targeted/full acceptance remains required.
The delivery records working-tree measurements before the full suite and ends
with the guarded noninteractive commit.sh commit/push, with no postcommit action.


## MB1301 — Repeated recovery through native timers

Base `5c744fb95984aa38b3588c4427395feebd461966` matches every tracked byte of the
2026-11-14 17:06:43 snapshot. MB1300 is committed; no numerical host acceptance
transcript accompanied this snapshot. Its fresh CI run is
https://github.com/teuk/mediabot_v3/actions/runs/43613765147 ; acceptance remains
pending until the completed source-bound artifact is inspected.

The shared saturation probe adds a distinct timed-recovery phase. Each cycle
queues two lines on each of two channels while the fixture blocks ordinary
output. A real PING must still receive its native PONG. Unblocking admission then
lets native countdown expiry and rearming deliver all four lines, once and in
per-channel FIFO order. No drain method is called manually and no clock or timer
is replaced in this phase. An ordinary NOTICE barrier closes exact wire accounting.
Initial and rearm delays must each be at least 1.8 seconds (tolerance around the
existing two-second schedule); each drain has a ten-second liveness deadline.
These are harness bounds, not a new production timing policy or SLO.

After every cycle, payload/timer ownership must be released and native notifier
counts must equal the connected baseline. On Linux with readable /proc, file
descriptor counts must also equal that baseline. RSS is sampled without a hard
leak threshold. Fixture diagnostic/history arrays are cleared between cycles so
their intentionally retained records do not masquerade as native resource growth.
The report retains bounded per-cycle samples; it is not a constant-memory harness.
Final teardown retires both queues and restores the initial notifier count.

The normal native case and full/load JSON use two cycles (about eight seconds).
The delivery additionally runs thirty cycles (about two minutes, 120 messages)
before the full host suite. `--timed-cycles` accepts only 1..300, rejects malformed
or out-of-range input before creating a report, and keeps exclusive output creation.
Source hashes from the shared probe bind both measurement phases.

Scope remains controlled admission over local AF_UNIX sockets. The two-channel
exercise does not establish global budget fairness, production network behavior,
real TTL expiry or hours-long memory stability. Step 4 remains open for sustained
load and wider workloads. No runtime policy, database or service changes are made.

Local validation: 17 tooling tests and 191 native assertions pass. The standalone
thirty-cycle run passes 413 assertions in 120.22 seconds of timed recovery and
delivers 120 messages. Every connected sample records four notifiers and twelve
file descriptors; RSS is 119,672 KiB throughout this particular run, not a portable
budget. A negative control removing the native retry delay fails the timing
assertions and produces a failed JSON verdict. Existing-output and invalid cycle
argument checks also pass. Full local qualification remains unavailable without
DBD::MariaDB; the delivery requires targeted tests, the timed run and the full
host suite before its final noninteractive commit/push.


## MB1302 — Fixed closing workload for step 4

Base `141b4a49ea9e520a16a3097d8187cb87cbfad897` matches every tracked byte of the
2026-11-14 17:29:05 snapshot. All three MB1301 workflows passed. Fresh run
https://github.com/teuk/mediabot_v3/actions/runs/43615267865 passed 42,991 assertions
in 247 seconds; its source-bound report and two-cycle saturation JSON both pass.
Artifact 14121813406 is retained in this delivery, archive SHA-256
`666b1f4c1cbc42c64ab072e7c76dc89b71382d48743d72a23b67a7e517de527a`.
This supersedes the pending short-run acceptance notes above. No numerical host
transcript or 300-cycle result is inferred from that CI artifact.

To bound the remaining campaign, the closing step-4 workload is now fixed:
300 existing native timer cycles, two channels with two lines per cycle, normally
about twenty minutes and 1,200 deliveries. There is no additional runtime feature
or timer mock. Progress appears every fifteen cycles. A dedicated Python assessor
requires matching source hashes (including the executable Perl wrapper), complete
ordered samples, exact delivery/burst/expiry accounting, >=3.6 seconds per native
drain and >=1,080 seconds total observed cycle time, PONG <=2 seconds, stable
connected notifier/fd counts and final notifier cleanup. The lower time tolerance
matches the existing 1.8-second per-countdown assertions; this is not a throughput
benchmark. The native harness retains its own wire deadlines and bounded alarm.

Memory acceptance is declared before the target run: ten warmup cycles, then
peak RSS no more than 16 MiB above their median. This conservative diagnostic
envelope accommodates allocator/harness overhead and is not a zero-leak theorem.
The harness clears retained fixture logs/history but keeps bounded JSON samples.
Missing /proc measurements, malformed/nonfinite values, a short run or changed
source produce unavailable, never passed. A measured budget violation fails.
The assessor records the input and its own hash and creates its output exclusively.

The delivery runs the closing workload once before the full host suite. Only a
passed assessment and full suite permit the final noninteractive commit/push.
After reviewing that host result, accept step 4 for this specified local workload
and move to step 5 (representative command contracts), without another endurance
increment unless a failure supplies a concrete reason. Hours-long stability,
production network load, real TTL waiting and global budget fairness remain
explicit residual limits, not hidden claims of this acceptance gate.

Local validation: 19 tooling tests exercise positive synthetic acceptance and
negative resource, timing, accounting, source, completeness and output-protection
cases. These synthetic samples are tests of the assessor, not endurance evidence.
All 191 native targeted assertions pass; a real two-cycle measurement passes its
own assertions and is correctly refused as incomplete by the endurance assessor.
The twenty-minute target run is pending. Local full qualification lacks
DBD::MariaDB; the host script requires the full suite before committing.


## MB1303 — Representative command contracts and bounded campaign closure

Base `d9452420d481537ee0873cac4dc26732ec396b8f` matches every tracked byte of the
2026-11-14 18:13:00 snapshot. The maintainer's MB1302 transcript reports a passed
300-cycle assessment: 1,200 deliveries in 1,203.04672772205 seconds, four connected
notifiers and eleven file descriptors, warmup RSS median 127,352 KiB, peak growth
2,468 KiB (below 16,384). Evidence remains on teuk under
`/home/mediabot/mb1302-endurance.I64VvIYR/`. This is transcript evidence; those host
JSON bytes were not independently supplied. The host full suite passed 43,027
assertions in 373s before noninteractive commit/push. Step 4 is accepted for its
specified local envelope; no repeat long workload is required by this delivery.

All three MB1302 workflows also passed. Fresh run
https://github.com/teuk/mediabot_v3/actions/runs/43619013343 passed 42,991 assertions
in 171s. Its short default measurement is separate from host endurance. Artifact
14122932516 is retained in the delivery, archive SHA-256
`26498d363626fe38f571ab0b2d9e366b5f7a2adf122d487c0a3343d36a95c131`.

Step 5 uses one data-driven contract runner over twelve scenarios:

| Representative | Contract |
| --- | --- |
| echo | Public and private destination, mixed-case dispatch, exact UTF-8 bytes, empty-argument silence |
| spike | Exact public response; no private handler or unexpected reply |
| addbadword | Anonymous denial, granted write, immediately revoked role, different caller identity, no private registration, SQL prepare failure and one successful retry |

All frames cross the existing AF_UNIX pair, native parsing, registry dispatch,
Context, real built-ins and Sender. Each exchange ends at an ordinary NOTICE
barrier, then checks the entire wire slice for exact destination/content/order
and absence of extra replies. Administrative rows check that Context requests
the current frame's full prefix once. Denied/unregistered administrative commands
must issue no SQL; successful writes must preserve registered channel ID 7 and
the exact Unicode word. A disposable SQLite missing-table failure must produce
one native diagnostic, no success reply and no active statement; restoring the
table allows the next request to succeed once. No deployed database is touched.

Authorization lookup supplies fresh fixture user objects; native handler role
checks remain active. Audit and console sinks are fixtures. This qualifies
permission revocation between commands, not authentication, session storage or
revocation during an already-running asynchronous command. SQL scope is failed
prepare with DBI RaiseError off, not all exception/transaction behaviors. Private
absence for spike/addbadword preserves current catalogue semantics. These three
representatives do not establish contracts for every command or network topology.

The two `qw(#busy #other)` lists are replaced with explicit quoted channel names.
This removes the warning observed on teuk without changing channels, timers or
endurance criteria. Syntax checking of the standalone wrapper emits no qw warning.

Local validation: 19 tooling tests and 244 native targeted assertions pass,
including 53 contract assertions. A negative control bypassing the native Master
check fails the revocation contracts. Full local qualification still lacks
DBD::MariaDB; host targeted/full acceptance and subsequent source-bound CI remain
required. The delivery ends with noninteractive commit.sh commit/push.

### Final exit decision

After MB1303 host and fresh CI pass, close the five-step campaign for the bounded
scopes above and publish a concise result summary; no additional feature patch
is required merely to extend the matrix. Reopen only for a reproduced defect or
an explicitly selected new scope. Preserve the listed residual limits rather
than calling this universal resilience, production capacity or hours-long proof.
