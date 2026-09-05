'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { cleanSearch, parsePositiveInt, parseRouteId } = require('../lib/requestParams');
const { qIdent } = require('../lib/sql');

const repositoryPath = require.resolve('../lib/mediabotRepository');
const dbPath = require.resolve('../lib/db');

function loadRepository(execute) {
  delete require.cache[repositoryPath];
  require.cache[dbPath] = {
    id: dbPath,
    filename: dbPath,
    loaded: true,
    exports: {
      pool: { execute, query: execute },
      tableColumns: async () => [],
      clearColumnCache: () => {}
    }
  };
  return require(repositoryPath);
}

test.after(() => {
  delete require.cache[repositoryPath];
  delete require.cache[dbPath];
});

test('request parameters are bounded and normalized', () => {
  assert.equal(parsePositiveInt('25', 10, { min: 1, max: 50 }), 25);
  assert.equal(parsePositiveInt('500', 10, { min: 1, max: 50 }), 50);
  assert.equal(parsePositiveInt('-1', 10, { min: 1, max: 50 }), 1);
  assert.equal(parsePositiveInt('nope', 10), 10);
  assert.equal(parseRouteId('0001'), null);
  assert.equal(parseRouteId('42'), 42);
  assert.equal(parseRouteId('1 OR 1=1'), null);
  assert.equal(cleanSearch(['  alpha   beta  '], { maxLength: 8 }), 'alpha be');
});

test('dynamic SQL identifiers use a strict allowlist', () => {
  assert.equal(qIdent('USER_LEVEL'), '`USER_LEVEL`');
  for (const value of ['USER name', 'USER`', 'x.y', '', 'x;DROP']) {
    assert.throws(() => qIdent(value), /Unsafe SQL identifier/, value || '<empty>');
  }
});

test('repository returns one successful row with parameterized lookup', async () => {
  const calls = [];
  const repository = loadRepository(async (sql, params) => {
    calls.push({ sql, params });
    return [[{ id_user: 42, nickname: 'Alice', username: 'alice' }], []];
  });

  const user = await repository.getUserById(42);
  assert.equal(user.nickname, 'Alice');
  assert.equal(calls.length, 1);
  assert.match(calls[0].sql, /WHERE id_user = \?/);
  assert.deepEqual(calls[0].params, [42]);
});

test('repository maps an empty result to null', async () => {
  const repository = loadRepository(async () => [[], []]);
  assert.equal(await repository.getUserById(8), null);
});

test('repository rejects malformed driver results', async () => {
  const repository = loadRepository(async () => ({ rows: [] }));
  await assert.rejects(
    repository.getUserById(8),
    /Malformed database result for user lookup/
  );
});

test('repository propagates database errors without forging an empty success', async () => {
  const expected = new Error('database unavailable');
  const repository = loadRepository(async () => { throw expected; });
  await assert.rejects(repository.getUserById(8), err => err === expected);
});
