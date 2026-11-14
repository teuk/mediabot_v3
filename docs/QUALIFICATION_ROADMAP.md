# Mediabot qualification roadmap

Accepted by the maintainer on 2026-11-13. This is the active continuation after
bounded architecture and IRC-contract assessment. It does not reopen their
extraction or Eggdrop-parity scope. Baseline: MB1290, commit
`31b9ffc2444e2d62ac9667ef6afad4cb5642973f`.

## Five steps and exit gates

| Step | Deliverable | Exit evidence | Status |
| --- | --- | --- | --- |
| 1. Reproducible validation environment | Disposable checkout, complete native dependencies, recorded environment and one qualification command shared with CI practices | Fresh setup can run native validation; missing dependencies fail explicitly; source/dependency identity is recorded | In progress: MB1291 provides source isolation; MB1292 adds explicit disposable dependency provisioning and observed module identity. Fresh-environment native acceptance remains open. |
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
