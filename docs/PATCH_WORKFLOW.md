# Reproducible patches from GitHub

Use GitHub as the normal source of committed code. A full server snapshot is
needed only for relevant uncommitted/local files or when GitHub is inaccessible.
Record the full `git rev-parse HEAD` value for each delivery. Do not send a
production configuration or database dump to reproduce an offline bug.

## Prepare a separate checkout

```bash
git clone https://github.com/teuk/mediabot_v3.git mediabot-review
cd mediabot-review
git switch -c fix/focused-change
git rev-parse HEAD
```

For dependencies and offline Perl tests, follow [DEVELOPING.md](DEVELOPING.md).
Do not run the application configuration wizard just to execute tests. The
repository's cpanfile and installer verification remain the dependency sources.

## Produce a patch

Reproduce the failure, make the smallest useful correction and extend its
existing tests. Stage only explicitly reviewed paths, including new files:

```bash
git add -- Mediabot/path/to/module.pm t/cases/existing_case.t CHANGELOG.md
git diff --cached --check
git diff --cached --stat
git rev-parse HEAD > ../change.base
git diff --cached --binary --full-index > ../change.patch
sha256sum ../change.patch
```

Those file paths are examples, not commands to paste unchanged. The patch
contains the staged changes relative to HEAD. Check for unintended staged files
before export; unstaged changes are not exported. Do not include VERSION in the
patch for the maintainer flow: commit.sh manages it later.

Deliver the patch, full base SHA, checksum, reproduction, targeted commands,
validation results and commit message together. Pin references to commits, not
moving branch names. Inspect the patch before executing tests or code it adds.
A checksum identifies the supplied bytes; it does not make unreviewed code safe.

## Check and apply on the target checkout

Store the patch outside the repository. Substitute the supplied full SHAs:

```bash
python3 tools/dev/check-patch.py /home/mediabot/change.patch \
  --base FULL_BASE_COMMIT --sha256 PATCH_SHA256

python3 tools/dev/check-patch.py /home/mediabot/change.patch \
  --base FULL_BASE_COMMIT --sha256 PATCH_SHA256 --apply
```

The default is check-only. The tool rejects a different HEAD, staged or unstaged
changes, untracked non-ignored files, an interrupted Git operation, a damaged
patch, whitespace errors or an application conflict. Ignored runtime files are
left alone; an existing destination, even ignored, cannot be overwritten by a
new-file patch. Run with exclusive access to this checkout: the tool does not
lock out another editor or Git process between checking and applying.

Application leaves the index untouched. It does not fetch, merge, stage, run
code, change services, commit or push. Git performs its normal path checks;
there is no `--unsafe-paths`, `--reject` or `--3way` fallback. A new base requires
a newly reviewed patch rather than bypassing the guard.

## Validate and commit

Run the patch's targeted lane first. For runtime changes, then run one full
suite with progress visible before the final commit. On the maintainer checkout:

```bash
perl t/test_commands.pl --filter 'REVIEWED_CASE_FILTER' --progress
perl t/test_commands.pl --progress --profile-top 20
./commit.sh --skip-preflight -m 'MBxxxx: Reparo — describe the actual correction 🪄'
```

`commit.sh` is a local maintainer tool ignored by Git, so a fresh clone does not
contain it. Do not recreate it, copy credentials, or replace this flow with a
GitHub API commit. Let it handle VERSION, staging review and push. An automated
package may answer its prompts only after checking its exact local version and
the exact expected changed/new/deleted files. Stop if validation fails.

If tests fail after application, keep the changes for diagnosis. Do not reapply
the patch or hide failures. After fixing and rerunning the necessary checks,
resume the validation/commit step. To undo only this patch before commit, first
ensure that none of its files has received additional work, then inspect and use:

```bash
git apply --reverse --check /home/mediabot/change.patch
git apply --reverse /home/mediabot/change.patch
```

Do not use `git reset --hard` or `git clean` as a recovery shortcut. After a commit,
use the project's reviewed revert workflow instead of blindly reversing files.

## Tool tests

The helper uses only Python 3's standard library and Git. Its integration tests
create temporary repositories and never contact a remote:

```bash
python3 -B tools/dev/test_check_patch.py -v
```

They cover check-only behavior, add/modify/delete, unchanged staging, double
application, wrong base, tampered data, local work, interrupted Git operations,
conflicts without partial writes and ignored-file collisions.
