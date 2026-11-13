# Mediabot qualification roadmap

Accepted by the maintainer on 2026-11-13. This is the active continuation after
bounded architecture and IRC-contract assessment. It does not reopen their
extraction or Eggdrop-parity scope. Baseline: MB1290, commit
`31b9ffc2444e2d62ac9667ef6afad4cb5642973f`.

## Five steps and exit gates

| Step | Deliverable | Exit evidence | Status |
| --- | --- | --- | --- |
| 1. Reproducible validation environment | Disposable checkout, complete native dependencies, recorded environment and one qualification command shared with CI practices | Fresh setup can run native validation; missing dependencies fail explicitly; source/dependency identity is recorded | In progress: MB1291 supplies the isolated source runner and dependency gate. Dependency provisioning/version capture and fresh-environment acceptance remain open. |
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
