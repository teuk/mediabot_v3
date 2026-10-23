'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const configPath = require.resolve('../lib/config');
require.cache[configPath] = {
  id: configPath,
  filename: configPath,
  loaded: true,
  exports: {
    config: {
      urls: {
        metrics: 'http://127.0.0.1:9108/metrics',
        radioStatus: 'http://127.0.0.1:8000/status-json.xsl',
        radioPublicBase: 'https://radio.example.test',
        radioPrimaryMount: '/radio.mp3'
      }
    }
  }
};

const { fetchJson, getRadioStatus } = require('../lib/radio');
const { fetchMetrics, metricSum, parseMetrics } = require('../lib/metrics');
const { readPartylineRuntime } = require('../lib/partylineRuntime');
const nativeFs = require('node:fs');
const os = require('node:os');
const nativePath = require('node:path');
const { FLAGS, readChannelDiagnostics, projectReport, renderChannelDiagnostics } = require('../lib/channelDiagnostics');

function channelReport() {
  return {
    version: 3, channel_id: 7, channel: '#café', observed_at: 2000, database: 'fresh', channel_joined: 'yes',
    flags: Object.fromEntries(FLAGS.map(key => [key, key === 'Reddit' ? 'on' : 'unknown'])),
    activity: {
      rss: { runtime: 'present', state: 'fresh', source: 'channel', gap: 5, daily: 2, used: 1, wait: 300 },
      randomquote: { runtime: 'present', state: 'absent', source: 'default', interval: 3600, custom: 0, scheduled: 0 },
      tasks: { PRIVATE_INSTANCE_MARKER: 'hidden' }
    },
    rss_failures: { state: 'observed', retained_feeds: 1, latest_db_time: '2026-10-24 03:04:05' },
    plugins: { state: 'observed', omitted: 0, loaded_v3: 2, legacy_loaded: 4, packages: [
      { name: 'quotes-v3', state: 'observed', configured: 1, lifecycle: 'enabled', policy: 'observe', decision: 'shadow',
        missing_capabilities: 0, quarantined_resources: 1, retained_failures: 1, last_failure_at: 1950, private: 'PRIVATE_KEY_MARKER' },
      { name: 'private-plugin', state: 'observed', configured: 0, lifecycle: 'enabled', policy: 'off', decision: 'blocked',
        missing_capabilities: 0, quarantined_resources: 0, retained_failures: 0, last_failure_at: null, secret: 'PRIVATE_OTHER_MARKER' }
    ] }, notes: ['PRIVATE_ERROR_MARKER']
  };
}

test('channel publication crosses the web boundary through an explicit detached per-channel projection', () => {
  const raw = channelReport(), report = projectReport(raw, 7, '#café');
  assert.equal(report.flags.Reddit, 'on');
  assert.equal(report.plugins.packages.length, 1);
  assert.equal(report.plugins.packages[0].policy, 'observe');
  assert.equal(report.randomquote.scheduled, 0);
  assert.doesNotMatch(JSON.stringify(report), /PRIVATE_|private-plugin|loaded_v3|legacy_loaded|tasks|notes/);
  report.flags.Reddit = 'off'; assert.equal(raw.flags.Reddit, 'on');
  for (const mutate of [r => r.channel_id = 8, r => r.channel = '#other', r => r.version = 2,
    r => r.flags.Reddit = 'PRIVATE_', r => r.activity.rss.wait = '12', r => r.plugins.packages[0].name = '<script>']) {
    const bad = channelReport(); mutate(bad); assert.throws(() => projectReport(bad, 7, '#café'));
  }
});

test('native channel publication reader distinguishes freshness from mtime and rejects invalid identities and UTF-8', async () => {
  const directory = nativeFs.mkdtempSync(nativePath.join(nativeFs.realpathSync(os.tmpdir()), 'mb940-'));
  const file = nativePath.join(directory, '7.json');
  const read = () => readChannelDiagnostics({ directory, id: 7, name: '#café', now: () => 2000000 });
  try {
    assert.equal((await read()).reason, 'not_published');
    nativeFs.writeFileSync(file, JSON.stringify(channelReport()), { mode: 0o640 });
    const before = nativeFs.statSync(file);
    assert.equal((await read()).state, 'fresh');
    const after = nativeFs.statSync(file);
    assert.equal(after.ino, before.ino); assert.equal(after.mode, before.mode); assert.equal(after.mtimeMs, before.mtimeMs);
    const stale = channelReport(); stale.observed_at = 1800;
    nativeFs.writeFileSync(file, JSON.stringify(stale));
    const old = await read(); assert.equal(old.state, 'stale'); assert.equal(old.report, undefined);
    const oversized = JSON.stringify(channelReport()) + ' '.repeat(65537 - Buffer.byteLength(JSON.stringify(channelReport())));
    for (const contents of [Buffer.from([0xff]), '{PRIVATE_KEY_MARKER', oversized,
      JSON.stringify({ ...channelReport(), observed_at: 2010 }), JSON.stringify({ ...channelReport(), channel_id: 8 })]) {
      nativeFs.writeFileSync(file, contents); const result = await read();
      assert.equal(result.state, 'unavailable'); assert.doesNotMatch(JSON.stringify(result), /PRIVATE_|mb940-|\.json/);
    }
  } finally { nativeFs.rmSync(directory, { recursive: true, force: true }); }
});

test('channel publication reader refuses symlink files and parents without creating or repairing anything', async () => {
  const directory = nativeFs.mkdtempSync(nativePath.join(nativeFs.realpathSync(os.tmpdir()), 'mb940-'));
  try {
    const real = nativePath.join(directory, 'real'); nativeFs.mkdirSync(real);
    const file = nativePath.join(real, '7.json'); nativeFs.writeFileSync(file, JSON.stringify(channelReport()));
    const link = nativePath.join(directory, 'link'); nativeFs.symlinkSync(real, link, 'dir');
    const options = { id: 7, name: '#café', now: () => 2000000 };
    assert.equal((await readChannelDiagnostics({ ...options, directory: link })).state, 'unavailable');
    nativeFs.symlinkSync(file, nativePath.join(directory, '7.json'));
    assert.equal((await readChannelDiagnostics({ ...options, directory })).state, 'unavailable');
    assert.ok(nativeFs.lstatSync(nativePath.join(directory, '7.json')).isSymbolicLink());
  } finally { nativeFs.rmSync(directory, { recursive: true, force: true }); }
});

test('channel diagnosis HTML explains reservation and retention limits and escapes every rendered value', () => {
  const report = projectReport(channelReport(), 7, '#café');
  const result = { state: 'fresh', age_seconds: 0, report };
  const html = renderChannelDiagnostics(result);
  assert.match(html, /reservations in 24 hours/); assert.match(html, /database timezone/);
  assert.match(html, /retention, unload or restart/); assert.match(html, /unknown means no reliable observation/);
  report.plugins.packages[0].name = '<script>PRIVATE</script>';
  const safe = renderChannelDiagnostics(result); assert.doesNotMatch(safe, /<script>/); assert.match(safe, /&lt;script&gt;/);
  assert.doesNotMatch(renderChannelDiagnostics({ state: 'stale', report }), /quotes-v3|Reddit: on/);
});

function response({ ok = true, status = 200, text = '' } = {}) {
  return { ok, status, text: async () => text };
}

test('radio JSON fetch accepts valid data and rejects oversized, malformed and timed-out input', async () => {
  const valid = await fetchJson('http://local.test/radio', {
    fetchImpl: async () => response({ text: '{"ok":true}' }),
    timeoutMs: 50,
    maxBytes: 1024
  });
  assert.deepEqual(valid.data, { ok: true });

  const large = await fetchJson('http://local.test/radio', {
    fetchImpl: async () => response({ text: 'é'.repeat(20) }),
    timeoutMs: 50,
    maxBytes: 30
  });
  assert.equal(large.ok, false);
  assert.match(large.error, /Response too large: 40 bytes/);

  const malformed = await fetchJson('http://local.test/radio', {
    fetchImpl: async () => response({ text: '{broken' }),
    timeoutMs: 50,
    maxBytes: 1024
  });
  assert.equal(malformed.ok, false);
  assert.equal(malformed.error, 'Invalid JSON response');

  const timedOut = await fetchJson('http://local.test/radio', {
    fetchImpl: async (_url, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => {
        const err = new Error('aborted');
        err.name = 'AbortError';
        reject(err);
      }, { once: true });
    }),
    timeoutMs: 5,
    maxBytes: 1024
  });
  assert.deepEqual(timedOut, { ok: false, status: null, error: 'Timeout' });
});

test('radio status normalizes a bounded fake Icecast response', async () => {
  const status = await getRadioStatus({
    fetchImpl: async () => response({
      text: JSON.stringify({
        icestats: {
          server_id: 'Icecast',
          source: {
            listenurl: 'http://127.0.0.1:8000/radio.mp3',
            listeners: 4,
            title: 'Track'
          }
        }
      })
    }),
    timeoutMs: 50,
    maxBytes: 4096
  });
  assert.equal(status.ok, true);
  assert.equal(status.mounts.length, 1);
  assert.equal(status.primary.listeners, 4);
  assert.equal(status.primary.publicListenUrl, 'https://radio.example.test/radio.mp3');
});

test('metrics parser and fetch enforce sample and response bounds', async () => {
  const parsed = parseMetrics([
    '# HELP requests_total Requests',
    '# TYPE requests_total counter',
    'requests_total{route="/a"} 2',
    'requests_total{route="/b"} 3',
    'requests_total{route="/c"} 5'
  ].join('\n'), { maxSamplesPerMetric: 2 });
  assert.equal(parsed.get('requests_total').samples.length, 2);
  assert.equal(parsed.get('requests_total').truncated, true);
  assert.equal(metricSum(parsed, 'requests_total'), 5);

  const fetched = await fetchMetrics({
    url: 'http://local.test/metrics',
    fetchImpl: async () => response({ text: 'up 1\n' }),
    timeoutMs: 50,
    maxBytes: 1024,
    maxSamplesPerMetric: 5
  });
  assert.equal(fetched.get('up').samples[0].value, 1);

  const originalError = console.error;
  console.error = () => {};
  try {
    const tooLarge = await fetchMetrics({
      url: 'http://local.test/metrics',
      fetchImpl: async () => response({ text: 'é'.repeat(20) }),
      timeoutMs: 50,
      maxBytes: 30
    });
    assert.equal(tooLarge, null);
  } finally {
    console.error = originalError;
  }
});

test('Partyline status rejects oversized input and bounds normalized sessions', async () => {
  const now = 2_000_000;
  const sessions = Array.from({ length: 5 }, (_, i) => ({
    fd: i,
    login: `user-${i}\nunsafe`,
    connected_at: 1900
  }));
  const raw = JSON.stringify({ generated_at: 1900, sessions });
  const fsImpl = {
    stat: async () => ({ mtimeMs: now - 200, size: Buffer.byteLength(raw) }),
    readFile: async () => raw
  };
  const status = await readPartylineRuntime({
    path: '/bounded/fake.json',
    fsImpl,
    now: () => now,
    maxAgeMs: 500,
    maxBytes: 4096,
    maxSessions: 2
  });
  assert.equal(status.ok, true);
  assert.equal(status.stale, false);
  assert.equal(status.count, 2);
  assert.equal(status.sessions[0].login.includes('\n'), false);

  const oversized = await readPartylineRuntime({
    path: '/bounded/large.json',
    fsImpl: {
      stat: async () => ({ mtimeMs: now, size: 9000 }),
      readFile: async () => { throw new Error('must not read'); }
    },
    now: () => now,
    maxBytes: 1024
  });
  assert.equal(oversized.ok, false);
  assert.equal(oversized.error, 'runtime status exceeds configured byte limit');
});
