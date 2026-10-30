'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { publish } = require('./github_release_37.cjs');
const COMMIT = 'a'.repeat(40);
const URL = 'https://github.com/teuk/mediabot_v3/releases/tag/3.7';
const digest = (data, algorithm = 'sha256') => crypto.createHash(algorithm).update(data).digest('hex');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mediabot-release-37-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const artifactDir = path.join(root, 'artifacts');
  fs.mkdirSync(artifactDir);
  const base = 'mediabot_v3-3.7';
  const archives = [base + '.tar.gz', base + '.tar.xz'];
  for (const name of archives) fs.writeFileSync(path.join(artifactDir, name), `native fixture ${name}\n`);
  fs.writeFileSync(path.join(artifactDir, base + '-FILES.txt'), 'mediabot_v3-3.7/VERSION\n');
  fs.writeFileSync(path.join(artifactDir, base + '-RELEASE.txt'), `Source VERSION: 3.7\nRehearsal: no\nGit ref: 3.7\nGit commit: ${COMMIT}\n`);
  for (const [algorithm, suffix] of [['sha256', '-SHA256SUMS'], ['sha512', '-SHA512SUMS']]) {
    fs.writeFileSync(path.join(artifactDir, base + suffix), archives.map(name => `${digest(fs.readFileSync(path.join(artifactDir, name)), algorithm)}  ${name}\n`).join(''));
  }
  const notesFile = path.join(root, 'notes.md');
  fs.writeFileSync(notesFile, '![Mediabot 3.7](https://raw.githubusercontent.com/teuk/mediabot_v3/3.7/docs/mediabot-3.7-github-social-preview.png)\n\nRelease notes.\n');
  const state = {
    release: null, assets: [], writes: [], uploads: 0, failUpload: 0, corruptDigest: false,
    runs: ['ci.yml', 'debian13.yml'].map((name, index) => ({ id: index + 1,
      path: '.github/workflows/' + name, head_sha: COMMIT, head_branch: 'master', event: 'push',
      status: 'completed', conclusion: 'success' })),
  };
  const answer = data => ({ data: structuredClone(data) });
  const github = { rest: {
    git: { getRef: async () => answer({ object: { type: 'tag', sha: 'b'.repeat(40) } }) },
    actions: { listWorkflowRunsForRepo: async () => answer({ workflow_runs: state.runs }) },
    repos: {
      getCommit: async () => answer({ sha: COMMIT }),
      listReleases: async () => answer(state.release ? [state.release] : []),
      createRelease: async args => {
        state.writes.push('draft');
        state.release = { ...args, id: 37, html_url: URL, published_at: null };
        return answer(state.release);
      },
      listReleaseAssets: async () => answer(state.corruptDigest && state.assets.length
        ? state.assets.map((a, index) => index ? a : { ...a, digest: 'sha256:' + '0'.repeat(64) }) : state.assets),
      uploadReleaseAsset: async args => {
        state.uploads++;
        if (state.uploads === state.failUpload) {
          const error = new Error('private upstream detail must not escape'); error.status = 503; throw error;
        }
        state.writes.push('upload:' + args.name);
        const asset = { id: 100 + state.assets.length, name: args.name, state: 'uploaded',
          size: args.data.length, digest: 'sha256:' + digest(args.data) };
        state.assets.push(asset);
        return answer(asset);
      },
      updateRelease: async args => {
        state.writes.push('publish');
        assert.equal(state.assets.length, 6);
        assert.equal(args.make_latest, 'true');
        state.release = { ...state.release, ...args, html_url: URL, published_at: '2026-10-30T12:00:00Z' };
        return answer(state.release);
      },
    },
  } };
  const core = { setOutput: (key, value) => { assert.equal(key, 'release_url'); assert.equal(value, URL); }, info() {} };
  const context = { repo: { owner: 'teuk', repo: 'mediabot_v3' }, ref: 'refs/tags/3.7', sha: COMMIT };
  return { state, github, context, artifactDir, notesFile, core, commit: COMMIT };
}

test('publish only after both exact-commit push CIs and six verified native assets', async t => {
  const f = fixture(t);
  const result = await publish(f);
  assert.deepEqual(result, { url: URL, commit: COMMIT, assets: 6 });
  assert.equal(f.state.writes[0], 'draft');
  assert.equal(f.state.writes.at(-1), 'publish');
  assert.equal(f.state.writes.filter(x => x.startsWith('upload:')).length, 6);
  assert.match(f.state.release.body, /mediabot-3\.7-github-social-preview\.png/);
  assert.match(f.state.release.body, new RegExp(`<!-- mediabot-release:3.7:${COMMIT} -->`));
});

test('failed, missing, stale, non-master or non-push CI never creates a release', async t => {
  for (const alter of [
    f => { f.state.runs[0].conclusion = 'failure'; },
    f => { f.state.runs.pop(); },
    f => { f.state.runs[0].head_sha = 'c'.repeat(40); },
    f => { f.state.runs[0].head_branch = 'other'; },
    f => { f.state.runs[0].event = 'workflow_dispatch'; },
    f => { f.state.runs.push({ ...f.state.runs[0], id: 20, conclusion: 'failure' }); },
  ]) {
    const f = fixture(t); alter(f);
    await assert.rejects(publish(f), /exact-commit push CI is not green/);
    assert.deepEqual(f.state.writes, []);
  }
});

test('scope, event, tag and local integrity failures stop before a GitHub write', async t => {
  for (const alter of [
    f => { f.context.repo.owner = 'other'; },
    f => { f.context.ref = 'refs/heads/master'; },
    f => { f.context.sha = 'c'.repeat(40); },
    f => { f.github.rest.git.getRef = async () => ({ data: { object: { type: 'commit', sha: COMMIT } } }); },
    f => { fs.appendFileSync(path.join(f.artifactDir, 'mediabot_v3-3.7.tar.gz'), 'changed'); },
    f => { const p = path.join(f.artifactDir, 'mediabot_v3-3.7.tar.gz'); fs.unlinkSync(p); fs.symlinkSync(f.notesFile, p); },
  ]) {
    const f = fixture(t); alter(f);
    await assert.rejects(publish(f));
    assert.deepEqual(f.state.writes, []);
  }
});

test('an interrupted upload stays a draft, resumes missing assets, then repeats without writes', async t => {
  const f = fixture(t); f.state.failUpload = 3;
  await assert.rejects(publish(f), error => error.message === 'GitHub asset upload failed HTTP 503');
  assert.equal(f.state.release.draft, true);
  assert.equal(f.state.assets.length, 2);
  assert.equal(f.state.writes.includes('publish'), false);
  f.state.failUpload = 0;
  await publish(f);
  assert.equal(f.state.assets.length, 6);
  assert.equal(f.state.uploads, 7);
  const before = [...f.state.writes];
  await publish(f);
  assert.deepEqual(f.state.writes, before);
});

test('a wrong remote digest cannot publish even after all transfers completed', async t => {
  const f = fixture(t); f.state.corruptDigest = true;
  await assert.rejects(publish(f), /Remote artifact mismatch/);
  assert.equal(f.state.assets.length, 6);
  assert.equal(f.state.release.draft, true);
  assert.equal(f.state.writes.includes('publish'), false);
});

test('an existing unmanaged release is preserved without overwrites or asset deletion', async t => {
  const f = fixture(t);
  f.state.release = { id: 37, tag_name: '3.7', draft: false, prerelease: false,
    target_commitish: COMMIT, body: 'Operator-owned notes', html_url: URL, published_at: '2026-10-30' };
  await assert.rejects(publish(f), /not the exact managed 3.7 publication/);
  assert.equal(f.state.release.body, 'Operator-owned notes');
  assert.deepEqual(f.state.writes, []);
});
