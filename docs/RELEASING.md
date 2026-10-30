# Releasing Mediabot

This page documents the stable release path. It is intentionally stricter than
creating a private development snapshot.

## Release identity

Mediabot uses odd minor versions for stable releases and even minor versions for
development lines.

The selected stable identity for the final metadata commit is:

```text
stable version: 3.7
Git tag:        3.7
archive root:   mediabot_v3-3.7/
```

Every release command must name both the intended stable version and its exact
Git ref. The artifact builder deliberately has no implicit version or ref. This
prevents an old default from silently packaging a newer release under the wrong
identity.

The examples below use shell variables. Set them once, review them, and keep
them unchanged for the complete release procedure:

```bash
release_version='3.7'
release_ref="$release_version"
release_dest='/home/wws/downloads/mediabot'

printf 'VERSION=%s REF=%s DEST=%s\n' \
  "$release_version" "$release_ref" "$release_dest"
```

Mediabot 3.5 became stable through the explicit MB727 release decision.
The operator explicitly approved the stable 3.7 release on 30 October 2026.
The tag and public artifacts follow green CI on the final metadata commit. For a
later candidate, substituting another version in preparation commands does not declare it stable:
the final release gate must still set the exact stable
`VERSION`, create the matching tag and publish the verified artifacts.

## 0. Rehearse the artifacts from the committed candidate

From a clean committed candidate on the preceding even development line, run:

```bash
cd /home/mediabot/mediabot_v3 || exit 1

tools/rehearse_release_artifacts.sh \
  --version "$release_version" \
  --ref HEAD
```

The rehearsal builds the candidate artifacts twice and compares all six files
byte for byte. Their names contain `rehearsal` and the source commit, their
metadata says `not publishable`, and their embedded `VERSION` remains the
committed development version. The command must finish with
`RELEASE_REHEARSAL=OK`. It neither changes the repository nor produces a stable
release artifact.

## MB725 Debian 13 candidate acceptance

The dedicated `debian13.yml` workflow is the final technical installation and
upgrade gate. On `3.4dev` it builds the exact non-publishable rehearsal archive;
on the final `VERSION=3.5` commit it builds the identically scoped stable
archive. It extracts that archive without Git metadata and uses only the
resulting tree for the fresh configuration, MariaDB, systemd and dependency
paths.

The same disposable job exports the real stable `3.3` schema from Git history,
applies the current candidate's ordered migrations, restores a deterministic
pre-upgrade dump byte for byte, and reapplies the upgrade to the same final
state. Both the normal CI workflow and this Debian 13 workflow must be green on
the accepted commit. This evidence does not change `VERSION`, create a tag or
publish an artifact; those remain explicit release actions below.

## MB787 3.7 candidate qualification

Before the 3.7 publication, the published stable remains **3.5**. On the
`3.6dev` line, the Debian 13 workflow packages the tested development commit as
a non-publishable 3.7
rehearsal. MB1022 also accepts the explicit final `VERSION=3.7` commit and its
matching stable-shaped archive; it requires a dated committed 3.7 release
heading. It installs only the selected unpacked archive. The historical stable 3.3 upgrade and its
rollback/reapplication proof remain in the same workflow.

MB787 adds an independent path from the actual annotated `3.5` tag. The gate
exports its schema and migration files from Git, checks that released migrations
are byte-identical, and requires the candidate's public migration order to
cover every SQL migration exactly once. In a disposable MariaDB instance it
applies only migrations added after 3.5, checks strict drift, restores a logical
dump byte for byte and reapplies the upgrade to the same final dump. Success
reports `MB787_LINEAGE=OK`, `MB787_ROLLBACK=OK` and `MB787_REAPPLY=OK`.

To inspect migration lineage without starting a database, unpack the verified
rehearsal or final archive and run `tools/qualify_37_upgrade.sh --repo <checkout>
--candidate <unpacked archive> --lineage-only`. The database trial runs only
inside disposable GitHub Actions CI. Its output does not declare 3.7 stable or
authorize publication, tagging, database changes on an installed instance, or
an update of production. A later release decision must be explicit.

The 3.7 release was approved on 30 October 2026; artifact publication is
recorded separately after final qualification. The completed
development work and the separate acceptance steps for `#i/o` are in the
[`3.6dev roadmap`](ROADMAP_3.6DEV.md). Qualification evidence can continue to
run in CI without opening a release or changing production.

## MB1022 / MB1023 — Prepare, decide, then publish

The preparation candidate is `1d2e97a4c7fa9e64476fe229429188f4c78a6921`,
VERSION `3.6dev-20261030_084326`. Its two CI workflows and reproducible
archives are verified; the operator confirmed the dev smoke recipe.
The operator confirmed the release decision with other unreported field checks
retained as documented follow-up. This evidence
does not automatically qualify the next metadata commit.

The variables and file names below describe the approved 3.7 publication.
They are a procedure, not evidence that publication happened. Run tag and
public-directory commands only after the final commit's two green workflows.
For development preparation before the final identity transition, use:

```bash
perl t/test_commands.pl --progress
(cd contrib/mbweb && npm test)
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
# After the reviewed preparation commit, with a clean tracked worktree:
bash tools/rehearse_release_artifacts.sh --version 3.7 --ref HEAD
```

CI now runs mbweb and inventory checks explicitly. Both normal CI and Debian
13 acceptance must pass on the selected commit; local process-fixture failures
are not an exemption from that gate. The migration qualification remains
read-only with `--lineage-only` and starts MariaDB only in disposable CI.

The [3.7 acceptance sheet](RELEASE_ACCEPTANCE_3.7.md) records remaining real
checks. [Approved 3.7 notes](RELEASE_NOTES_3.7.md) describe the selected release
without claiming that the tag or artifacts are already published. The earlier 3.6dev acceptance sheet remains
historical evidence, not a successful new 3.7 recipe.

The approved final metadata patch prepares one coherent set of changes:

- exact `VERSION=3.7`, committed through native `commit.sh --release 3.7`;
- one dated `[3.7]` changelog section replacing the completed 3.6dev unreleased
  section, retaining historical entries and the dated 3.5 section;
- README status/download sections, SECURITY support table and this guide's
  current identity/examples synchronized to 3.7;
- final 3.7 notes and the regenerated command inventory for source line 3.7.

The existing README header and its historical 3.5 artwork/evidence are retained.
Its body links and installation instructions identify 3.7.
Do not relabel old test counts or old operational evidence as 3.7 results.
Release tests validate these two defined phases; an unrelated version is still
refused. The release decision is recorded above. Apply and commit the approved
metadata with the native helper, then qualify both remote workflows before
tagging it. Creating an archive in a disposable test fixture does not approve
its publication.

## Supported release-path authorities

| Boundary | Authoritative path |
| --- | --- |
| Fresh configuration and installation | `./configure` and `docs/CONFIGURE.md` |
| Existing database upgrade | `install/db_migrate.sh` in the exact order from `install/migrations/README.md` |
| IRC source update and rollback | `install/deploy_update.sh` |
| IRC systemd installation | `install/systemd_install.sh` and `tools/systemd/mediabot@.service.example` |
| mbweb deployment and rollback | `install/mbweb_deploy.sh` and `install/systemd/mbweb.service` |
| Candidate rehearsal | `tools/rehearse_release_artifacts.sh` |
| Stable artifact creation | `tools/build_release_artifacts.sh` |

No remote process-killing helper or file-by-file source copier is part of the
supported release path. Private configuration and runtime state remain outside
Git and outside public archives.

The private `snap_mediabot` ZIP may contain local collaboration tools. Public
release artifacts must be produced from the committed Git tag instead.

## 1. Final validation before the release commit

Run the complete test suite, security audit and integrity checks. Review the
staged file list and keep local configuration, `commit.sh`, MP3 files, backups
and snapshots out of Git.

## 2. Create the stable release commit

The local commit helper owns the VERSION transition:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
./commit.sh --release "$release_version" --skip-preflight
```

Do not use normal auto mode for the stable release commit.

## 3. Create and push the release tag

After confirming that `VERSION` is exactly `$release_version` in the pushed
commit:

```bash
cd /home/mediabot/mediabot_v3 || exit 1

git tag -a "$release_ref" -m "Mediabot $release_version"
git push origin "$release_ref"
```

The tag must point at the release commit.

## 4. Build the public artifacts

The builder uses `git archive`, honours `.gitattributes`, requires the tag to
point at HEAD and validates the extracted archive before publication.

On teuk.org, using the requested web-download directory:

```bash
cd /home/mediabot/mediabot_v3 || exit 1

tools/build_release_artifacts.sh \
  --version "$release_version" \
  --ref "$release_ref" \
  --dest "$release_dest"
```

The exact directory spelling above is intentional and follows the current
server path. Change `--dest` only if the web root uses a different path.

For `release_version=3.7`, the generated files are:

```text
mediabot_v3-3.7.tar.gz
mediabot_v3-3.7.tar.xz
mediabot_v3-3.7-FILES.txt
mediabot_v3-3.7-RELEASE.txt
mediabot_v3-3.7-SHA256SUMS
mediabot_v3-3.7-SHA512SUMS
```

Both archives contain the same `mediabot_v3-3.7/` tree. The release includes the
tracked `contrib/` and `plugins/` directories. It excludes local/runtime-only
material such as `commit.sh`, `mediabot.conf`, `mp3/` and `node_modules/`.

## 5. Verify the published directory

```bash
cd "$release_dest" || exit 1

sha256sum -c "mediabot_v3-${release_version}-SHA256SUMS"
sha512sum -c "mediabot_v3-${release_version}-SHA512SUMS"
gzip -t "mediabot_v3-${release_version}.tar.gz"
xz -t "mediabot_v3-${release_version}.tar.xz"

tar -tzf "mediabot_v3-${release_version}.tar.gz" |
  grep -F "mediabot_v3-${release_version}/contrib/" | head
tar -tJf "mediabot_v3-${release_version}.tar.xz" |
  grep -F "mediabot_v3-${release_version}/plugins/" | head
```

## 6. GitHub release and homepage

Upload the two archives and checksum files only after the local verification is
clean. Publish the same filenames on GitHub and on the homepage so users can
verify identical artifacts from either location.

Do not start the next development line until the new release assets and public
release notes have been checked.
