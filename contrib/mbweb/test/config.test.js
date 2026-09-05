'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  ConfigError,
  buildConfig,
  normalizeBaseUrl,
  safeBasePath,
  validateSessionSecret
} = require('../lib/configCore');

const STRONG_SECRET = '0123456789abcdef0123456789abcdef';

test('base paths are normalized as local mount paths', () => {
  assert.equal(normalizeBaseUrl(''), '');
  assert.equal(normalizeBaseUrl('/'), '');
  assert.equal(normalizeBaseUrl(' mediabotv3dev/// '), '/mediabotv3dev');
  assert.equal(normalizeBaseUrl('/a//b/'), '/a/b');
  assert.equal(safeBasePath('/mediabotv3dev/', 'health'), '/mediabotv3dev/health');
});

test('base paths reject authority, control, query and dot-segment input', () => {
  for (const value of ['//example.org/x', '/a?token=x', '/a#x', '/a\nheader', '/../x']) {
    assert.throws(() => normalizeBaseUrl(value), ConfigError, value);
  }
});

test('configuration builds deterministic typed values from an explicit environment', () => {
  const config = buildConfig({
    MBWEB_SESSION_SECRET: STRONG_SECRET,
    MBWEB_PORT: '4102',
    MBWEB_DB_PORT: '3307',
    MBWEB_PARTYLINE_PORT: '24567',
    MBWEB_BASE_URL: 'console/',
    MBWEB_AUTH_LOGIN_COLUMNS: 'nickname, username ,',
    MBWEB_ALLOW_PLAINTEXT_PASSWORDS: '1'
  });

  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 4102);
  assert.equal(config.db.port, 3307);
  assert.equal(config.partyline.port, 24567);
  assert.equal(config.baseUrl, '/console');
  assert.deepEqual(config.auth.loginColumns, ['nickname', 'username']);
  assert.equal(config.auth.allowPlaintext, true);
  assert.equal(config.sessionSecret, STRONG_SECRET);
  assert.equal(config.session.store, 'memory');
  assert.equal(config.session.maxAgeMs, 8 * 60 * 60 * 1000);
});

test('invalid numeric configuration fails closed', () => {
  assert.throws(
    () => buildConfig({ MBWEB_SESSION_SECRET: STRONG_SECRET, MBWEB_PORT: '4O02' }),
    /MBWEB_PORT must be an integer/
  );
  assert.throws(
    () => buildConfig({ MBWEB_SESSION_SECRET: STRONG_SECRET, MBWEB_DB_PORT: '70000' }),
    /MBWEB_DB_PORT must be between 1 and 65535/
  );
});

test('weak, missing and default session secrets are rejected', () => {
  for (const secret of ['', 'CHANGE_ME', 'too-short']) {
    assert.throws(() => validateSessionSecret(secret), ConfigError, secret || '<empty>');
  }
  assert.equal(validateSessionSecret(STRONG_SECRET), STRONG_SECRET);
});

test('production requires persistent sessions and explicit loopback binding', () => {
  assert.throws(
    () => buildConfig({ NODE_ENV: 'production', MBWEB_SESSION_SECRET: STRONG_SECRET }),
    /MBWEB_SESSION_STORE=mysql/
  );
  assert.throws(
    () => buildConfig({
      NODE_ENV: 'production',
      MBWEB_SESSION_SECRET: STRONG_SECRET,
      MBWEB_SESSION_STORE: 'mysql',
      MBWEB_HOST: '0.0.0.0'
    }),
    /loopback/
  );
  const config = buildConfig({
    NODE_ENV: 'production',
    MBWEB_SESSION_SECRET: STRONG_SECRET,
    MBWEB_SESSION_STORE: 'mysql',
    MBWEB_HOST: '127.0.0.1'
  });
  assert.equal(config.session.store, 'mysql');
});

test('session expiry, cleanup and table settings are bounded', () => {
  assert.throws(
    () => buildConfig({
      MBWEB_SESSION_SECRET: STRONG_SECRET,
      MBWEB_SESSION_MAX_AGE_MS: '1000'
    }),
    /MBWEB_SESSION_MAX_AGE_MS/
  );
  assert.throws(
    () => buildConfig({
      MBWEB_SESSION_SECRET: STRONG_SECRET,
      MBWEB_SESSION_TABLE: 'MBWEB_SESSION;DROP'
    }),
    /ASCII letters/
  );
});
