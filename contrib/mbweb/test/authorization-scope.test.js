'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { globalLevel, can } = require('../lib/permissions');
const { normalizeSessionUser, roleNameFromLevel } = require('../lib/sessionUserCore');
const { escapeHtml } = require('../lib/html');

// Adapter fakes load the actual middleware, repository and route handlers.
// No application dependency, credential file, listener or upstream is loaded.
function load(relative, overrides) {
  const file = path.resolve(__dirname, relative);
  const loaded = new Module(file, module);
  loaded.filename = file;
  loaded.paths = Module._nodeModulePaths(path.dirname(file));
  const realRequire = Module.createRequire(file);
  loaded.require = name => Object.hasOwn(overrides, name) ? overrides[name] : realRequire(name);
  loaded._compile(fs.readFileSync(file, 'utf8'), file);
  return loaded.exports;
}

function response() {
  return {
    code: 200, payload: null, headers: {},
    set(k, v) { this.headers[k] = v; return this; },
    status(n) { this.code = n; return this; },
    json(v) { this.payload = v; return this; },
    send(v) { this.payload = v; return this; },
    redirect(v) { this.code = 302; this.payload = v; return this; }
  };
}
function request(level = 0, requestPath = '/api/quotes') {
  const req = { path: requestPath, query: {}, session: {
    user: { id_user: 7, nickname: 'Alice', global_level: level, id_user_level: level + 1 },
    _userRefreshedAt: Date.now(), saved: 0, destroyed: 0,
    save(done) { this.saved++; done(); },
    destroy(done) { this.destroyed++; done(); }
  } };
  return req;
}
function sessionModule(getProfile, getChannels = async () => []) {
  return load('../lib/sessionUser.js', {
    './mediabotRepository': { getUserWithGlobalRole: getProfile, getUserChannels: getChannels },
    './config': { safeBase: p => '/console' + p },
    './securityLog': { logError() {} }
  });
}
function routerFake() {
  const routes = new Map();
  return { routes, adapter: { Router: () => ({
    get(route, ...handlers) { routes.set(route, handlers); }
  }) } };
}
async function invoke(handlers, req, res) {
  for (const handler of handlers) {
    let next = false;
    await handler(req, res, () => { next = true; });
    if (!next) break;
  }
}

const profile = level => ({ id_user: 7, nickname: 'Alice', global_level: level,
  id_user_level: level + 1, global_role: roleNameFromLevel(level) });

test('missing and malformed roles never gain any channel or global access', () => {
  for (const value of [null, undefined, '', ' ', false, true, -1, 4, 999, NaN, Infinity, '0.0', [], {}]) {
    const fresh = { global_level: value };
    assert.equal(globalLevel(fresh), 999, String(value));
    assert.equal(can(fresh, 'view:channel', { channel: { userHasAccess: true } }), false);
    assert.equal(roleNameFromLevel(value), 'Unknown');
    const normalized = normalizeSessionUser({ id_user: 7, id_user_level: 1 }, fresh, [], null);
    assert.equal(normalized.global_level, 999);
    assert.equal(normalized.flags.owner, false);
  }
  const deleted = normalizeSessionUser({ id_user: 7, id_user_level: 1 }, null, [], null);
  assert.equal(deleted.global_level, 999, 'cached Owner role cannot replace a missing profile');
  for (const value of [null, undefined, 0, -1, 5, false, [], '1.0']) {
    assert.equal(globalLevel({ id_user_level: value }), 999);
  }
});

test('all four fresh database roles and their numeric strings retain expected scopes', () => {
  for (let level = 0; level <= 3; level++) {
    for (const fresh of [{ global_level: level }, { global_level: String(level) },
      { id_user_level: level + 1 }, { id_user_level: String(level + 1) }]) {
      const user = normalizeSessionUser({ id_user: 7, id_user_level: 1 }, fresh, [], null);
      assert.equal(user.global_level, level);
      assert.equal(can(user, 'view:all_users'), level <= 1);
      assert.equal(can(user, 'view:partyline'), level <= 1);
      assert.equal(can(user, 'use:partyline'), level === 0);
      assert.equal(can(user, 'view:system'), level === 0);
    }
  }
});

test('deleted account is rejected, cleared and destroyed before a protected API can run', async () => {
  let channelReads = 0, next = 0;
  const auth = sessionModule(async () => null, async () => { channelReads++; return []; });
  const req = request(), res = response();
  await auth.requireFreshLogin(req, res, () => next++);
  assert.equal(res.code, 401);
  assert.deepEqual(res.payload, { ok: false, error: 'Login required.' });
  assert.equal(req.session.user, null);
  assert.equal(req.session.destroyed, 1);
  assert.equal(channelReads, 0);
  assert.equal(next, 0);
});

test('invalid current role revokes HTML access even with an old Owner session', async () => {
  const auth = sessionModule(async () => ({ id_user: 7, id_user_level: null }));
  const req = request(0, '/'), res = response();
  await auth.requireFreshLogin(req, res, () => assert.fail('revoked user reached dashboard'));
  assert.equal(res.code, 302);
  assert.match(res.payload, /^\/console\/login\?error=/);
  assert.equal(req.session.user, null);
  assert.equal(req.session.destroyed, 1);
});

test('failed session destruction never restores a revoked local identity', async () => {
  const auth = sessionModule(async () => null);
  const req = request(), res = response();
  req.session.destroy = done => done(new Error('store unavailable'));
  await auth.requireFreshLogin(req, res, () => assert.fail('revoked identity reused'));
  assert.equal(res.code, 401);
  assert.equal(req.session.user, null);
});

test('database outage blocks access with 503 while preserving a recoverable session', async () => {
  const auth = sessionModule(async () => { throw new Error('private adapter failure'); });
  const req = request(), res = response();
  await auth.requireFreshLogin(req, res, () => assert.fail('stale Owner reached handler'));
  assert.equal(res.code, 503);
  assert.equal(req.session.destroyed, 0);
  assert.equal(req.session.user.global_level, 0);
  assert.doesNotMatch(JSON.stringify(res.payload), /private adapter/);
});

test('downgrade refreshes before next even inside the historical refresh interval', async () => {
  const auth = sessionModule(async () => profile(3));
  const req = request(), res = response();
  let next = 0;
  await auth.requireFreshLogin(req, res, () => {
    next++; assert.equal(req.session.user.global_level, 3);
    assert.equal(can(req.session.user, 'view:system'), false);
  });
  assert.equal(next, 1);
  assert.equal(req.session.saved, 1);
  assert.equal(res.headers['Cache-Control'], 'no-store');
});

test('session persistence failure cannot execute a protected handler', async () => {
  const auth = sessionModule(async () => profile(3));
  const req = request(), res = response();
  req.session.save = done => done(new Error('store unavailable'));
  await auth.requireFreshLogin(req, res, () => assert.fail('handler ran after failed save'));
  assert.equal(res.code, 503);
});

test('public landing page remains accessible without any authorization read', async () => {
  const auth = sessionModule(async () => assert.fail('public page queried account'));
  let next = 0;
  await auth.refreshOptionalLogin({ session: {} }, response(), () => next++);
  assert.equal(next, 1);
  const res = response();
  await auth.requireFreshLogin({ session: {}, path: '/api/quotes' }, res, () => assert.fail());
  assert.equal(res.code, 401);
});

function quoteRepository({ missing = [], columns = {}, fail = null } = {}) {
  const calls = [];
  const schema = { QUOTES: ['id_quotes', 'quotetext', 'id_user', 'id_channel', 'ts'],
    CHANNEL: ['id_channel', 'name'], USER: ['id_user', 'nickname'], USER_CHANNEL: ['id_user', 'id_channel'], ...columns };
  const execute = async (sql, params = []) => {
    if (/information_schema\.tables/.test(sql)) return [[{ n: missing.includes(params[0]) ? 0 : 1 }], []];
    calls.push({ sql, params });
    if (fail) throw fail;
    if (/SELECT COUNT\(\*\) AS n FROM QUOTES/.test(sql)) return [[{ n: /EXISTS/.test(sql) ? 1 : 2 }], []];
    if (/SELECT c\.name, COUNT/.test(sql)) return [[{ name: '#allowed', n: 1 }], []];
    return [[{ id_quotes: 17, quotetext: 'anonymous fixture', id_user: null, author_nick: null,
      channel_name: '#allowed' }], []];
  };
  return { calls, repo: load('../lib/mediabotRepository.js', {
    './db': { pool: { execute, query: execute }, tableColumns: async t => schema[t] || [], clearColumnCache() {} }
  }) };
}
const member = { id_user: 7, global_level: 3 };

test('quote rows and total use the same parameterized membership and target-channel scope', async () => {
  const { repo, calls } = quoteRepository();
  const result = await repo.getQuotes({ user: member, channel: '#allowed', search: 'duck', page: 2, perPage: 20 });
  assert.equal(result.total, 1);
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.match(call.sql, /EXISTS \(SELECT 1 FROM USER_CHANNEL uc\s+WHERE uc.id_user = \? AND uc.id_channel = q.id_channel\)/);
    assert.match(call.sql, /c.name = \?/);
    assert.deepEqual(call.params.slice(0, 3), [7, '#allowed', '%duck%']);
    assert.doesNotMatch(call.sql, /#allowed|duck/);
  }
  assert.deepEqual(calls[1].params.slice(-2), [20, 20]);
});

test('Owner and Master preserve global quote browsing with a current identity', async () => {
  for (const global_level of [0, 1]) {
    const { repo, calls } = quoteRepository();
    const result = await repo.getQuotes({ user: { id_user: 7, global_level } });
    assert.equal(result.total, 2);
    for (const call of calls) assert.doesNotMatch(call.sql, /USER_CHANNEL/);
  }
});

test('quote channel selector and its counts have the same membership restriction', async () => {
  const { repo, calls } = quoteRepository();
  const channels = await repo.getQuoteChannels({ user: member });
  assert.deepEqual(channels, [{ name: '#allowed', n: 1 }]);
  assert.match(calls[0].sql, /uc.id_channel = q.id_channel/);
  assert.deepEqual(calls[0].params, [7]);
  assert.match(calls[0].sql, /GROUP BY c.id_channel, c.name/);
});

test('missing membership or channel schema cannot fall back to global quote data', async () => {
  for (const options of [{ missing: ['USER_CHANNEL'] }, { missing: ['CHANNEL'] },
    { columns: { QUOTES: ['id_quotes', 'quotetext', 'id_user'] } }]) {
    const { repo, calls } = quoteRepository(options);
    assert.deepEqual(await repo.getQuotes({ user: member }), { rows: [], total: 0 });
    assert.deepEqual(await repo.getQuoteChannels({ user: member }), []);
    assert.equal(calls.length, 0);
  }
});

test('quote searches escape percent, underscore and the chosen escape character literally', async () => {
  const { repo, calls } = quoteRepository();
  await repo.getQuotes({ user: member, search: '50%!_' });
  for (const call of calls) {
    assert.match(call.sql, /LIKE \? ESCAPE '!'/);
    assert.equal(call.params[1], '%50!%!!!_%');
  }
});

test('anonymous quotes remain visible in permitted channels without author mutation', async () => {
  const { repo, calls } = quoteRepository();
  const { rows } = await repo.getQuotes({ user: member });
  assert.equal(rows[0].id_user, null);
  assert.equal(rows[0].author_nick, null);
  assert.match(calls[1].sql, /LEFT JOIN USER u/);
  assert.doesNotMatch(calls[1].sql, /WHERE u\.|UPDATE|DELETE|INSERT/);
});

test('quote repository rejects absent, invalid or revoked identity before querying', async () => {
  for (const user of [undefined, null, {}, { id_user: 7 }, { id_user: 0, global_level: 0 },
    { id_user: [], global_level: 0 }, { id_user: 7, global_level: -1 }]) {
    const { repo, calls } = quoteRepository();
    await assert.rejects(repo.getQuotes({ user }), /current authenticated account/);
    await assert.rejects(repo.getQuoteChannels({ user }), /current authenticated account/);
    assert.equal(calls.length, 0);
  }
});

test('database errors stay failures rather than fabricated empty quote results', async () => {
  const failure = new Error('adapter down');
  const { repo } = quoteRepository({ fail: failure });
  await assert.rejects(repo.getQuotes({ user: member }), e => e === failure);
  await assert.rejects(repo.getQuoteChannels({ user: member }), e => e === failure);
});

test('both quote HTML and JSON routes forward authenticated scope to both queries', async () => {
  const stub = routerFake();
  const seen = [];
  load('../routes/quotes.js', {
    express: stub.adapter,
    '../lib/config': { config: {}, safeBase: p => '/console' + p },
    '../lib/render': { escapeHtml, renderPage: (title, body) => body },
    '../lib/sessionUser': { requireFreshLogin: (req, res, next) => next() },
    '../lib/mediabotRepository': {
      getQuotes: async args => { seen.push(args.user); return { rows: [], total: 0 }; },
      getQuoteChannels: async args => { seen.push(args.user); return []; }
    },
    '../lib/securityLog': { logError() {} }
  });
  for (const route of ['/api/quotes', '/quotes']) {
    const req = request(3, route), res = response();
    await invoke(stub.routes.get(route), req, res);
    assert.equal(res.code, 200);
    assert.deepEqual(seen.splice(0), [req.session.user, req.session.user]);
  }
});

function dashboardModule() {
  let counts = 0;
  const adapter = load('../lib/dashboardData.js', {
    './config': { config: { db: { database: 'internal_db', user: 'internal_user', host: 'internal_host' } } },
    './sessionUser': { publicSessionUser: u => u },
    './securityLog': { logError() {} },
    './db': { ping: async () => ({ db: 'internal_db' }) },
    './mediabotRepository': {
      getUserChannels: async () => [{ id_channel: 1, name: '#allowed' }],
      getCounts: async () => { counts++; return { users: 123, channels: 456 }; }
    }
  });
  return { adapter, countReads: () => counts };
}

test('regular dashboard HTML/JSON data omits database identity and global counts', async () => {
  for (const level of [1, 2, 3]) {
    const { adapter, countReads } = dashboardModule();
    const data = await adapter.getDashboardData(request(level));
    assert.doesNotMatch(JSON.stringify(data), /internal_db|internal_user|internal_host|123|456/);
    assert.equal(data.myChannels.length, 1);
    assert.equal(countReads(), 0);
  }
  const { adapter, countReads } = dashboardModule();
  const data = await adapter.getDashboardData(request(0));
  assert.equal(data.db.name, 'internal_db');
  assert.equal(data.counts.users, 123);
  assert.equal(countReads(), 1);
});

test('actual home route refreshes before data/metrics and remains quiet for guests', async () => {
  let dataCalls = 0, metricCalls = 0;
  const stub = routerFake();
  const auth = sessionModule(async () => { throw new Error('database unavailable'); });
  load('../routes/home.js', {
    express: stub.adapter,
    '../lib/config': { config: {}, safeBase: p => '/console' + p },
    '../lib/render': { escapeHtml, renderPage: (title, body) => body },
    '../lib/sessionUser': auth,
    '../lib/metrics': { fetchMetrics: async () => { metricCalls++; }, metricVal: () => 0 },
    '../lib/dashboardData': { getDashboardData: async () => { dataCalls++; assert.fail('stale dashboard loaded'); } }
  });
  const res = response();
  await invoke(stub.routes.get('/'), request(0, '/'), res);
  assert.equal(res.code, 503);
  assert.equal(dataCalls, 0);
  assert.equal(metricCalls, 0);
  const publicRes = response();
  await invoke(stub.routes.get('/'), { session: {}, path: '/' }, publicRes);
  assert.equal(publicRes.code, 200);
  assert.match(publicRes.payload, /Log in/);
  assert.doesNotMatch(publicRes.payload, /internal_db|Entries in USER|Prometheus endpoint/);
});
