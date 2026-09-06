# Releasing Mediabot

This page documents the stable release path. It is intentionally stricter than
creating a private development snapshot.

## Release identity

Mediabot uses odd minor versions for stable releases and even minor versions for
development lines.

The currently published release remains:

```text
stable version: 3.5
Git tag:        3.5
archive root:   mediabot_v3-3.5/
```

Every release command must name both the intended stable version and its exact
Git ref. The artifact builder deliberately has no implicit version or ref. This
prevents an old default from silently packaging a newer release under the wrong
identity.

The examples below use shell variables. Set them once, review them, and keep
them unchanged for the complete release procedure:

```bash
release_version='3.5'
release_ref="$release_version"
release_dest='/home/wws/downloads/mediabot'

printf 'VERSION=%s REF=%s DEST=%s\n' \
  "$release_version" "$release_ref" "$release_dest"
```

Mediabot 3.5 became stable through the explicit MB727 release decision. For a
later candidate, substituting another version in preparation commands does not declare it stable:
the final release gate must still set the exact stable
`VERSION`, create the matching tag and publish the verified artifacts.

## 0. Rehearse the artifacts from the committed candidate

From a clean committed `3.4dev` candidate, run:

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

For `release_version=3.5`, the generated files are:

```text
mediabot_v3-3.5.tar.gz
mediabot_v3-3.5.tar.xz
mediabot_v3-3.5-FILES.txt
mediabot_v3-3.5-RELEASE.txt
mediabot_v3-3.5-SHA256SUMS
mediabot_v3-3.5-SHA512SUMS
```

Both archives contain the same `mediabot_v3-3.5/` tree. The release includes the
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
