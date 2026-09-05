'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  createCsrfProtection,
  csrfDecision,
  csrfField,
  ensureCsrfToken,
  tokensEqual
} = require('../lib/csrf');
const { BoundedLoginThrottle } = require('../lib/loginThrottle');
const {
  destroyAuthenticatedSession,
  establishAuthenticatedSession
} = require('../lib/sessionLifecycle');
const { cookieOptions, sessionOptions } = require('../lib/sessionPolicy');
const { logError } = require('../lib/securityLog');

const TOKEN = 'ab'.repeat(32);
const OTHER_TOKEN = 'cd'.repeat(32);

test('CSRF tokens are session-bound, fixed-size and compared exactly', () => {
  const session = {};
  const token = ensureCsrfToken(session, size => Buffer.alloc(size, 0xab));
  assert.equal(token, TOKEN);
  assert.equal(ensureCsrfToken(session, () => Buffer.alloc(32, 0xcd)), TOKEN);
  assert.equal(tokensEqual(TOKEN, TOKEN), true);
  assert.equal(tokensEqual(TOKEN, OTHER_TOKEN), false);
  assert.equal(tokensEqual('short', TOKEN), false);
  assert.match(csrfField({ session }), /name="_csrf" value="[a-f0-9]{64}"/);
});

test('safe methods pass and every unsafe method requires one matching token', () => {
  for (const method of ['GET', 'HEAD', 'OPTIONS']) {
    assert.equal(csrfDecision({ method, session: {} }).allowed, true);
  }
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    assert.equal(csrfDecision({ method, session: { _csrf: TOKEN }, body: {} }).allowed, false);
    assert.equal(csrfDecision({
      method,
      session: { _csrf: TOKEN },
      body: { _csrf: TOKEN },
      headers: {}
    }).allowed, true);
  }
});

test('conflicting body and header tokens fail closed', () => {
  const decision = csrfDecision({
    method: 'POST',
    session: { _csrf: TOKEN },
    body: { _csrf: TOKEN },
    headers: { 'x-csrf-token': OTHER_TOKEN }
  });
  assert.equal(decision.allowed, false);
});

test('central CSRF middleware rejects an unsafe API request without echoing tokens', () => {
  const warnings = [];
  const middleware = createCsrfProtection({
    randomBytes: size => Buffer.alloc(size, 0xab),
    logger: { warn: (...args) => warnings.push(args.join(' ')) }
  });
  const req = { method: 'POST', path: '/console/api/cache/clear', session: {}, body: {} };
  const res = {
    locals: {},
    statusCode: 200,
    set() {},
    status(code) { this.statusCode = code; return this; },
    json(value) { this.value = value; return this; }
  };
  middleware(req, res, () => assert.fail('unsafe request reached next'));
  assert.equal(res.statusCode, 403);
  assert.deepEqual(res.value, { ok: false, error: 'Invalid or expired form token' });
  assert.equal(warnings.join('\n').includes(TOKEN), false);
});

test('safe requests without forms do not create session state', () => {
  const middleware = createCsrfProtection({ logger: { warn() {} } });
  const req = { method: 'GET', path: '/console/health', session: {} };
  const res = { locals: {} };
  let nextCalls = 0;
  middleware(req, res, () => { nextCalls += 1; });
  assert.equal(nextCalls, 1);
  assert.equal(req.session._csrf, undefined);
});

test('login throttle has a hard capacity, expiry and explicit reset', () => {
  let now = 1000;
  const throttle = new BoundedLoginThrottle({
    maxAttempts: 2,
    windowMs: 100,
    maxEntries: 2,
    now: () => now
  });
  assert.equal(throttle.consume('one').allowed, true);
  assert.equal(throttle.consume('one').allowed, true);
  assert.equal(throttle.consume('one').allowed, false);
  assert.equal(throttle.consume('two').allowed, true);
  assert.deepEqual(throttle.consume('three'), {
    allowed: false,
    saturated: true,
    retryAfterSec: 60
  });
  assert.equal(throttle.size(), 2);
  assert.equal(throttle.reset('one'), true);
  assert.equal(throttle.consume('three').allowed, true);
  now += 101;
  assert.equal(throttle.prune(), 2);
  assert.equal(throttle.size(), 0);
});

test('login pruning timer is unrefed', () => {
  let unrefCalls = 0;
  const throttle = new BoundedLoginThrottle();
  throttle.startPruning({
    setIntervalImpl(fn, delay) {
      assert.equal(typeof fn, 'function');
      assert.equal(delay, 15 * 60 * 1000);
      return { unref() { unrefCalls += 1; } };
    }
  });
  assert.equal(unrefCalls, 1);
});

test('production cookie policy is explicit and persistent store is wired', () => {
  const config = {
    nodeEnv: 'production',
    baseUrl: '/console',
    sessionSecret: 'x'.repeat(32),
    session: { maxAgeMs: 28_800_000 }
  };
  assert.deepEqual(cookieOptions(config), {
    httpOnly: true,
    sameSite: 'lax',
    secure: true,
    maxAge: 28_800_000,
    path: '/console'
  });
  const store = {};
  const options = sessionOptions(config, store);
  assert.equal(options.store, store);
  assert.equal(options.saveUninitialized, false);
  assert.equal(options.unset, 'destroy');
});

test('authentication rotates the session before storing user and a new CSRF token', async () => {
  const order = [];
  const req = {
    session: {
      regenerate(done) {
        order.push('regenerate');
        req.session = {
          save(saveDone) { order.push('save'); saveDone(); }
        };
        done();
      }
    }
  };
  await establishAuthenticatedSession(req, { id_user: 7 }, {
    now: () => 1234,
    randomBytes: size => Buffer.alloc(size, 0xab)
  });
  assert.deepEqual(order, ['regenerate', 'save']);
  assert.deepEqual(req.session.user, { id_user: 7 });
  assert.equal(req.session._userRefreshedAt, 1234);
  assert.equal(req.session._csrf, TOKEN);
});

test('logout destroys the server-side session', async () => {
  let calls = 0;
  await destroyAuthenticatedSession({
    session: { destroy(done) { calls += 1; done(); } }
  });
  assert.equal(calls, 1);
});

test('security logs retain only bounded codes and never error text', () => {
  const lines = [];
  const err = Object.assign(
    new Error('password=hunter2 cookie=mbweb.sid query=?private conversation'),
    { code: 'ECONNRESET' }
  );
  logError({ error: (...parts) => lines.push(parts.join(' ')) }, 'http', err, {
    method: 'POST', status: 500, password: 'hunter2'
  });
  const output = lines.join('\n');
  assert.match(output, /ECONNRESET/);
  assert.match(output, /POST/);
  assert.doesNotMatch(output, /hunter2|cookie|query|conversation|mbweb\.sid/);
});
