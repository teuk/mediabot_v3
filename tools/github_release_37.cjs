'use strict';

// Fixed 3.7 publication boundary. Runtime code and private credentials are not read.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const OWNER = 'teuk';
const REPO = 'mediabot_v3';
const TAG = '3.7';
const BASE = 'mediabot_v3-3.7';
const NAMES = ['.tar.gz', '.tar.xz', '-FILES.txt', '-RELEASE.txt', '-SHA256SUMS', '-SHA512SUMS'].map(x => BASE + x);
const WORKFLOWS = ['.github/workflows/ci.yml', '.github/workflows/debian13.yml'];
const URL = 'https://github.com/teuk/mediabot_v3/releases/tag/3.7';
const hash = (bytes, algorithm = 'sha256') => crypto.createHash(algorithm).update(bytes).digest('hex');
const need = (condition, message) => { if (!condition) throw new Error(message); };

async function api(stage, call) {
  try { return (await call()).data; }
  catch (error) {
    // Do not forward request headers, remote exception messages or response bodies.
    throw new Error(`GitHub ${stage} failed${Number.isInteger(error.status) ? ` HTTP ${error.status}` : ''}`);
  }
}

function localArtifacts(directory, commit) {
  need(typeof directory === 'string' && directory.length > 0, 'Artifact directory missing');
  const entries = fs.readdirSync(directory).sort();
  need(JSON.stringify(entries) === JSON.stringify([...NAMES].sort()), 'Expected exactly six native release artifacts');
  const files = new Map();
  for (const name of NAMES) {
    const file = path.join(directory, name);
    const stat = fs.lstatSync(file);
    need(stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= 100 * 1024 * 1024,
      'Invalid artifact type or size');
    const bytes = fs.readFileSync(file);
    files.set(name, { bytes, size: bytes.length, digest: `sha256:${hash(bytes)}` });
  }
  for (const [algorithm, suffix, length] of [['sha256', '-SHA256SUMS', 64], ['sha512', '-SHA512SUMS', 128]]) {
    const rows = files.get(BASE + suffix).bytes.toString('utf8').trimEnd().split('\n');
    need(rows.length === 2, 'Invalid native checksum manifest');
    const seen = new Set();
    for (const row of rows) {
      const match = row.match(new RegExp(`^([a-f0-9]{${length}})  (mediabot_v3-3\\.7\\.tar\\.(?:gz|xz))$`));
      need(match && !seen.has(match[2]), 'Invalid or duplicate checksum entry');
      seen.add(match[2]);
      need(hash(files.get(match[2]).bytes, algorithm) === match[1], 'Artifact checksum mismatch');
    }
  }
  const info = files.get(BASE + '-RELEASE.txt').bytes.toString('utf8');
  for (const line of [`Source VERSION: 3.7\n`, `Rehearsal: no\n`, `Git ref: 3.7\n`, `Git commit: ${commit}\n`]) {
    need(info.includes(line), 'Native artifact identity mismatch');
  }
  return files;
}

function checkCI(runs, commit) {
  need(Array.isArray(runs), 'Invalid workflow listing');
  for (const workflow of WORKFLOWS) {
    const matches = runs.filter(run => run.path === workflow && run.head_sha === commit
      && run.event === 'push' && run.head_branch === 'master');
    matches.sort((a, b) => Number(b.id) - Number(a.id));
    need(matches.length > 0 && matches[0].status === 'completed' && matches[0].conclusion === 'success',
      `Required exact-commit push CI is not green: ${workflow}`);
  }
}

function checkAssets(assets, files, complete) {
  need(Array.isArray(assets), 'Invalid release asset listing');
  const seen = new Set();
  for (const asset of assets) {
    need(files.has(asset.name) && !seen.has(asset.name), 'Unknown or duplicate release asset');
    const expected = files.get(asset.name);
    need(asset.state === 'uploaded' && asset.size === expected.size && asset.digest === expected.digest,
      `Remote artifact mismatch: ${asset.name}`);
    seen.add(asset.name);
  }
  need(!complete || seen.size === files.size, 'Release assets incomplete');
  return seen;
}

async function publish({ github, context, core, artifactDir, commit, notesFile }) {
  need(context.repo.owner === OWNER && context.repo.repo === REPO && context.ref === 'refs/tags/3.7',
    'Publication is scoped to teuk/mediabot_v3 and its 3.7 tag');
  need(typeof commit === 'string' && /^[a-f0-9]{40}$/.test(commit), 'Invalid release commit');
  const fixed = { owner: OWNER, repo: REPO };
  const ref = await api('tag lookup', () => github.rest.git.getRef({ ...fixed, ref: 'tags/3.7' }));
  need(ref.object?.type === 'tag' && /^[a-f0-9]{40}$/.test(ref.object.sha)
    && typeof context.sha === 'string' && /^[a-f0-9]{40}$/.test(context.sha), 'The 3.7 tag must be annotated');
  const tagged = await api('tag commit lookup', () => github.rest.repos.getCommit({ ...fixed, ref: TAG }));
  need(tagged.sha === commit && [commit, ref.object.sha].includes(context.sha), 'Tag or event commit mismatch');
  const workflowRuns = await api('CI lookup', () => github.rest.actions.listWorkflowRunsForRepo({
    ...fixed, head_sha: commit, per_page: 100,
  }));
  checkCI(workflowRuns.workflow_runs, commit);
  const files = localArtifacts(artifactDir, commit);
  const notes = fs.readFileSync(notesFile, 'utf8');
  need(Buffer.byteLength(notes) > 0 && Buffer.byteLength(notes) < 60000, 'Release notes missing or oversized');
  const marker = `<!-- mediabot-release:3.7:${commit} -->`;
  const body = `${notes.trim()}\n\n${marker}\n`;
  const releases = await api('release lookup', () => github.rest.repos.listReleases({ ...fixed, per_page: 100 }));
  need(Array.isArray(releases), 'Invalid releases listing');
  const matching = releases.filter(release => release.tag_name === TAG);
  need(matching.length <= 1, 'Ambiguous 3.7 release');
  let release = matching[0];
  if (!release) {
    release = await api('draft creation', () => github.rest.repos.createRelease({
      ...fixed, tag_name: TAG, target_commitish: commit, name: 'Mediabot 3.7 — Expecto Patronum 🦌🪄',
      body, draft: true, prerelease: false, make_latest: 'false',
    }));
  }
  need(Number.isSafeInteger(release.id) && release.id > 0 && release.tag_name === TAG
    && release.target_commitish === commit && release.prerelease === false && release.body === body
    && typeof release.draft === 'boolean', 'Existing release is not the exact managed 3.7 publication');
  const release_id = release.id;
  let assets = await api('asset lookup', () => github.rest.repos.listReleaseAssets({ ...fixed, release_id, per_page: 100 }));
  const present = checkAssets(assets, files, !release.draft);
  if (release.draft) {
    for (const [name, file] of files) {
      if (present.has(name)) continue;
      await api('asset upload', () => github.rest.repos.uploadReleaseAsset({
        ...fixed, release_id, name, data: file.bytes,
        headers: { 'content-type': 'application/octet-stream', 'content-length': file.size },
      }));
    }
    assets = await api('uploaded asset verification', () => github.rest.repos.listReleaseAssets({ ...fixed, release_id, per_page: 100 }));
    checkAssets(assets, files, true);
    release = await api('publication', () => github.rest.repos.updateRelease({
      ...fixed, release_id, draft: false, prerelease: false, make_latest: 'true',
    }));
  }
  need(release.draft === false && release.prerelease === false && release.tag_name === TAG
    && release.html_url === URL && Boolean(release.published_at), 'Public release confirmation missing');
  core.setOutput('release_url', URL);
  core.info(`Mediabot 3.7 published: ${URL}; six verified assets; commit ${commit}`);
  return { url: URL, commit, assets: files.size };
}

module.exports = { publish, checkCI, localArtifacts, checkAssets };
