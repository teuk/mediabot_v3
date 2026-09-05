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
