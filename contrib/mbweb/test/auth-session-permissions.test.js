'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { timingSafeStringEqual, verifyPassword } = require('../lib/authCore');
const {
  normalizeSessionUser,
  publicSessionUser,
  roleNameFromLevel
} = require('../lib/sessionUserCore');
const { can, globalLevel } = require('../lib/permissions');

test('password comparison is exact and never trims plaintext input', async () => {
  assert.equal(timingSafeStringEqual('secret', 'secret'), true);
  assert.equal(timingSafeStringEqual('secret', 'secret '), false);

  assert.deepEqual(
    await verifyPassword('secret', 'secret', { allowPlaintext: true }),
    { ok: true, method: 'plaintext-exact' }
  );
  assert.deepEqual(
    await verifyPassword('secret ', 'secret', { allowPlaintext: true }),
    { ok: false, method: 'plaintext-exact' }
  );
  assert.deepEqual(await verifyPassword('x', null), { ok: false, method: 'missing' });
});

test('bcrypt and MySQL password formats use only their bounded verifier', async () => {
  let bcryptCalls = 0;
  const bcryptHash = '$2b$10$012345678901234567890u012345678901234567890123456789012';
  const bcrypt = await verifyPassword('hunter2', bcryptHash, {
    allowPlaintext: true,
    bcryptCompare: async (input, stored) => {
      bcryptCalls += 1;
      assert.equal(input, 'hunter2');
      assert.equal(stored, bcryptHash);
      return true;
    }
  });
  assert.deepEqual(bcrypt, { ok: true, method: 'bcrypt' });
  assert.equal(bcryptCalls, 1);

  const mysqlHash = '*' + 'A'.repeat(40);
  const mysql = await verifyPassword('secret', mysqlHash, {
    mysqlPassword: async input => {
      assert.equal(input, 'secret');
      return mysqlHash.toLowerCase();
    }
  });
  assert.deepEqual(mysql, { ok: true, method: 'mysql-password' });
});

test('session users are normalized from database roles without retaining password data', () => {
  const user = normalizeSessionUser(
    { id_user: 7, nickname: 'raw', password: 'never-export', id_user_level: 4 },
    { nickname: 'Alice', username: 'alice', global_level: 2, global_role: 'Administrator' },
    [{ id_channel: 1 }, { id_channel: 2 }],
    'id_user_level'
  );

  assert.equal(user.nickname, 'Alice');
  assert.equal(user.global_level, 2);
  assert.equal(user.channels_count, 2);
  assert.equal(user.flags.administrator, true);
  assert.equal(user.flags.master, false);
  assert.equal('password' in user, false);
  assert.deepEqual(publicSessionUser(user), {
    nickname: 'Alice',
    username: 'alice',
    global_level: 2,
    global_role: 'Administrator',
    channels_count: 2
  });
  assert.equal(roleNameFromLevel(3), 'User');
  assert.equal(roleNameFromLevel(999), 'Unknown');
});

test('route-facing role boundaries preserve Owner, Master, Administrator and User scopes', () => {
  const owner = { global_level: 0 };
  const master = { global_level: 1 };
  const admin = { global_level: 2 };
  const user = { id_user_level: 4 };

  assert.equal(globalLevel(user), 3);
  assert.equal(can(owner, 'view:system'), true);
  assert.equal(can(master, 'view:system'), false);
  assert.equal(can(master, 'view:all_channels'), true);
  assert.equal(can(admin, 'view:all_channels'), false);
  assert.equal(can(user, 'view:dashboard'), true);
  assert.equal(can(user, 'view:channel', { channel: { userHasAccess: false } }), false);
  assert.equal(can(user, 'view:channel', { channel: { userHasAccess: true } }), true);
  assert.equal(can(null, 'view:dashboard'), false);
});
