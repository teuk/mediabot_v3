# Releasing Mediabot

This page documents the stable release path. It is intentionally stricter than
creating a private development snapshot.

## Release identity

Mediabot uses odd minor versions for stable releases and even minor versions for
development lines.

For this release:

```text
stable version: 3.3
Git tag:        3.3
archive root:   mediabot_v3-3.3/
```

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
./commit.sh --release 3.3 --skip-preflight
```

Do not use normal auto mode for the stable release commit.

## 3. Create and push the release tag

After confirming that `VERSION` is exactly `3.3` in the pushed commit:

```bash
cd /home/mediabot/mediabot_v3 || exit 1

git tag -a 3.3 -m "Mediabot 3.3"
git push origin 3.3
```

The tag must point at the release commit.

## 4. Build the public artifacts

The builder uses `git archive`, honours `.gitattributes`, requires the tag to
point at HEAD and validates the extracted archive before publication.

On teuk.org, using the requested web-download directory:

```bash
cd /home/mediabot/mediabot_v3 || exit 1

tools/build_release_artifacts.sh \
  --version 3.3 \
  --ref 3.3 \
  --dest /home/wws/downloads/mediabot
```

The exact directory spelling above is intentional and follows the current
server path. Change `--dest` only if the web root uses a different path.

Generated files:

```text
mediabot_v3-3.3.tar.gz
mediabot_v3-3.3.tar.xz
mediabot_v3-3.3-FILES.txt
mediabot_v3-3.3-RELEASE.txt
mediabot_v3-3.3-SHA256SUMS
mediabot_v3-3.3-SHA512SUMS
```

Both archives contain the same `mediabot_v3-3.3/` tree. The release includes the
tracked `contrib/` and `plugins/` directories. It excludes local/runtime-only
material such as `commit.sh`, `mediabot.conf`, `mp3/` and `node_modules/`.

## 5. Verify the published directory

```bash
cd /home/wws/downloads/mediabot || exit 1

sha256sum -c mediabot_v3-3.3-SHA256SUMS
sha512sum -c mediabot_v3-3.3-SHA512SUMS
gzip -t mediabot_v3-3.3.tar.gz
xz -t mediabot_v3-3.3.tar.xz

tar -tzf mediabot_v3-3.3.tar.gz | grep '^mediabot_v3-3.3/contrib/' | head
tar -tJf mediabot_v3-3.3.tar.xz | grep '^mediabot_v3-3.3/plugins/' | head
```

## 6. GitHub release and homepage

Upload the two archives and checksum files only after the local verification is
clean. Publish the same filenames on GitHub and on the homepage so users can
verify identical artifacts from either location.

Do not start the next development line until the 3.3 release assets and public
release notes have been checked.
