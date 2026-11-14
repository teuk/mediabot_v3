# Mediabot qualification roadmap

Accepted by the maintainer on 2026-11-13. This is the active continuation after
bounded architecture and IRC-contract assessment. It does not reopen their
extraction or Eggdrop-parity scope. Baseline: MB1290, commit
`31b9ffc2444e2d62ac9667ef6afad4cb5642973f`.

## Five steps and exit gates

| Step | Deliverable | Exit evidence | Status |
| --- | --- | --- | --- |
| 1. Reproducible validation environment | Disposable checkout, complete native dependencies, recorded environment and one qualification command shared with CI practices | Fresh setup can run native validation; missing dependencies fail explicitly; source/dependency identity is recorded | In progress: MB1291 provides source isolation; MB1292 adds explicit disposable dependency provisioning and observed module identity. MB1293 host acceptance passed; MB1294 supplies the fresh Debian CI gate. Its successful run remains required. |
| 2. Local IRC integration | Simulated server and native command paths, no production configuration | Public command, private command and deferred reply interrupted by reconnect all pass; old output cannot reach the successor transport | Planned |
| 3. Controlled failure scenarios | Storage, HTTP, worker and logging failures in the local harness | Bounded completion, explicit diagnosis, retained authority and recovery demonstrated for each selected fault | Planned |
| 4. Saturation and endurance | Repeatable workload and resource measurements | Report queue depth/age, control response delay, dropped/expired output and post-drain resources; establish budgets before adjusting policy | Planned |
| 5. Shared command contracts | Reusable matrix over selected representative commands | Private/channel routing, permission revocation, identity, Unicode and storage errors covered; preserve command-specific semantics | Planned |

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
