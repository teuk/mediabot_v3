# MB960 — Preserve the Git origin during native updates

## Defect

`install/deploy_update.sh` previously resolved `git remote get-url origin`
before cloning. With `url.*.insteadOf`, that command returns the rewritten
transport URL. Passing it to `git clone` stores the temporary mirror as the
new checkout's origin. Removing that mirror then breaks the next update.

## Change

Read the raw configured URLs with `git config --null --get-all
remote.origin.url` and select the first, matching Git's fetch behavior.
Pass this configured URL to the existing clone command. Git applies any URL
rewrite when it opens the transport, without making that transport address
the new origin. NUL-delimited parsing preserves spaces in local paths.
An absent or empty first URL fails the existing preflight guard.

This change prevents future origin drift. It does not repair a checkout whose
origin was already changed by a previous update. Such a repair requires the
operator's known repository URL.

## Validation

Case `1336_mb960_update_origin_rewrite.t` executes the real shell updater and
real local Git repositories. Only the configuration reader and entry point
are minimal fixtures. The test forbids non-file Git transports so a broken
rewrite cannot contact an external server.

Coverage includes the actual mirror revision being installed, the configured
origin being retained for file, HTTPS without `.git` and SSH forms, selecting
the first of multiple URLs, a second rotation after mirror deletion, previous
source archives, private configuration, saved points and durable success.
Missing and empty origins leave the source in place. All 38 assertions pass
with MB960; the original updater fails 10 of them.

The related 17-file slice passes 532 assertions; the security audit passes all
37 invariants, and Bash syntax validation succeeds. The existing MB786 process
stop rehearsal (`1151`) fails on both the original and patched snapshot in the
local execution environment: `/proc` exposes outer-namespace PIDs that `kill`
cannot address. It is excluded from the 532 passing assertions and remains in
the normal operator-side test command below. The full project suite was not run.

Run the related existing update tests and the new case with:

```bash
bash -n install/deploy_update.sh
perl t/test_commands.pl --filter 'mb960|mb688|mb635|mb786|mb772|mb645|mb680|mb681|mb673|mb632|mb634|mb648|mb726|mb447|mb646' --progress
```

The test creates disposable repositories and rotates only those fixtures.
Installing this script change requires no bot restart; the next native update
uses it. No live server acceptance is claimed here.
