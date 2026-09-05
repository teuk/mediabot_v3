'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  DEFAULT_CLEANUP_BATCH_SIZE,
  createMySqlSessionStore,
  expiryMs,
  parseSession,
  serializeSession,
  sessionId
} = require('../lib/mysqlSessionStore');

class Store {}

function callbackCall(invoke) {
  return new Promise((resolve, reject) => {
    invoke((err, value) => err ? reject(err) : resolve(value));
  });
}

function fakeTimer() {
  return {
    unrefCalls: 0,
    unref() { this.unrefCalls += 1; }
  };
}

function makeStore(responses = [], options = {}) {
  const calls = [];
  const timer = fakeTimer();
  let cleared = null;
  const pool = {
    async execute(sql, params) {
      calls.push({ sql, params });
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response === undefined ? [{ affectedRows: 0 }, []] : response;
    }
  };
  const store = createMySqlSessionStore({
    Store,
    pool,
    table: 'MBWEB_SESSION',
    ttlMs: 10_000,
    cleanupIntervalMs: 5000,
    now: options.now || (() => 1000),
    setIntervalImpl(fn, delay) {
      assert.equal(typeof fn, 'function');
      assert.equal(delay, 5000);
      return timer;
    },
    clearIntervalImpl(value) { cleared = value; },
    logger: { error() {} },
    maxDataBytes: options.maxDataBytes || 4096
  });
  return { calls, pool, store, timer, cleared: () => cleared };
}

test('session identifiers and serialized payloads are strictly bounded', () => {
  assert.equal(sessionId('a'.repeat(16)), 'a'.repeat(16));
  for (const sid of ['short', 'a'.repeat(129), 'invalid/session']) {
    assert.throws(() => sessionId(sid), /Invalid session identifier/);
  }
  assert.throws(() => serializeSession({ data: 'x'.repeat(100) }, 20), /exceeds/);
  assert.throws(() => parseSession('[]'), /not an object/);
  assert.equal(expiryMs({ cookie: { expires: new Date(50_000) } }, 1000, 10_000), 11_000);
});

test('set writes only parameterized session data with explicit expiry', async () => {
  const { calls, store } = makeStore([[{ affectedRows: 1 }, []]]);
  const sid = 's'.repeat(32);
  await callbackCall(cb => store.set(sid, {
    cookie: { expires: new Date(9000).toISOString() },
    user: { id_user: 7 }
  }, cb));
  assert.match(calls[0].sql, /VALUES \(\?, \?, \?\)/);
  assert.deepEqual(calls[0].params[0], sid);
  assert.equal(calls[0].params[1].getTime(), 9000);
  assert.match(calls[0].params[2], /"id_user":7/);
  assert.equal(calls[0].sql.includes(sid), false);
});

test('get returns a valid unexpired session and maps no row to null', async () => {
  const sid = 'g'.repeat(32);
  const { store } = makeStore([
    [[{ expires_at: new Date(9000), session_data: '{"user":{"id_user":7}}' }], []],
    [[], []]
  ]);
  assert.deepEqual(await callbackCall(cb => store.get(sid, cb)), { user: { id_user: 7 } });
  assert.equal(await callbackCall(cb => store.get(sid, cb)), null);
});

test('expired sessions are deleted before returning null', async () => {
  const sid = 'e'.repeat(32);
  const { calls, store } = makeStore([
    [[{ expires_at: new Date(999), session_data: '{}' }], []],
    [{ affectedRows: 1 }, []]
  ]);
  assert.equal(await callbackCall(cb => store.get(sid, cb)), null);
  assert.match(calls[1].sql, /^DELETE FROM/);
  assert.deepEqual(calls[1].params, [sid]);
});

test('touch updates only expiry for the selected session', async () => {
  const sid = 't'.repeat(32);
  const { calls, store } = makeStore([[{ affectedRows: 1 }, []]]);
  await callbackCall(cb => store.touch(sid, {
    cookie: { expires: new Date(7000).toISOString() }
  }, cb));
  assert.match(calls[0].sql, /^UPDATE .* SET expires_at = \? WHERE session_id = \?$/);
  assert.equal(calls[0].params[0].getTime(), 7000);
  assert.equal(calls[0].params[1], sid);
});

test('malformed database shapes and payloads fail closed', async () => {
  const sid = 'm'.repeat(32);
  const malformedShape = makeStore([[null, []]]).store;
  await assert.rejects(
    callbackCall(cb => malformedShape.get(sid, cb)),
    /Malformed session-store result/
  );
  const malformedJson = makeStore([
    [[{ expires_at: new Date(9000), session_data: '{private' }], []]
  ]).store;
  await assert.rejects(callbackCall(cb => malformedJson.get(sid, cb)), SyntaxError);
});

test('one transient connection failure is retried and then succeeds', async () => {
  const transient = Object.assign(new Error('private endpoint'), { code: 'ECONNRESET' });
  const { calls, store } = makeStore([transient, [{ affectedRows: 1 }, []]]);
  await callbackCall(cb => store.destroy('r'.repeat(32), cb));
  assert.equal(calls.length, 2);
});

test('non-transient and repeated transient failures have no memory fallback', async () => {
  const denied = Object.assign(new Error('secret grant detail'), { code: 'ER_ACCESS_DENIED_ERROR' });
  const first = makeStore([denied]).store;
  await assert.rejects(callbackCall(cb => first.destroy('d'.repeat(32), cb)), denied);

  const lost1 = Object.assign(new Error('one'), { code: 'ECONNRESET' });
  const lost2 = Object.assign(new Error('two'), { code: 'ECONNRESET' });
  const second = makeStore([lost1, lost2]).store;
  await assert.rejects(callbackCall(cb => second.destroy('x'.repeat(32), cb)), lost2);
});

test('cleanup, readiness and shutdown are bounded and idempotent', async () => {
  const harness = makeStore([
    [{ affectedRows: 3 }, []],
    [[], []]
  ]);
  assert.equal(harness.timer.unrefCalls, 1);
  assert.equal(await harness.store.cleanup(), 3);
  assert.match(harness.calls[0].sql, new RegExp(`LIMIT ${DEFAULT_CLEANUP_BATCH_SIZE}$`));
  assert.equal(await harness.store.assertReady(), true);
  await harness.store.end();
  await harness.store.end();
  assert.equal(harness.cleared(), harness.timer);
  assert.equal(await harness.store.cleanup(), 0);
});
